const std = @import("std");
const h2 = @import("http2/connection.zig");
const h2_streams = @import("http2/streams.zig");
const builtin = @import("builtin");
const connection = @import("connection.zig");
const diagnostics = @import("diagnostics.zig");
const chunked = @import("http1/chunked.zig");
const http1 = @import("http1/parser.zig");
const poller_backend = @import("net/poller.zig");
const net = @import("net.zig");
const request_limits = @import("http1/request_limits.zig");
const error_response = @import("http1/error_response.zig");
const http1_types = @import("http1/types.zig");
const sync = @import("sync.zig");
const drain_signal = @import("drain_signal.zig");
const request_memory = @import("allocator/request_memory.zig");
const access_log = @import("access_log.zig");
const metrics = @import("metrics.zig");
const request_id = @import("request_id.zig");
const work_queue = @import("work_queue.zig");
const raw_bytes = @import("raw_bytes.zig");
const scheduler = @import("scheduler.zig");
const fiber = @import("fiber.zig");
const fiber_wait = @import("fiber_wait.zig");

/// Connections one process holds at once, `Server.Limits.maximum_connections`
///. Each costs one descriptor, a small slot, and a head buffer: at most
/// `initial_buffer_bytes` while the connection is idle, up to the head limit
/// while a head is arriving: an idle one about 4 KiB.
pub const default_maximum_connections: u32 = 4096;
pub const largest_maximum_connections: u32 = 65_536;

const initial_buffer_bytes: usize = 4 * 1024;
const maximum_loop_buffer_bytes: usize = request_limits.maximum_head_bytes;
const event_batch: usize = 256;

const listener_token: u64 = std.math.maxInt(u64);
const wake_token: u64 = std.math.maxInt(u64) - 1;
const tick_token: u64 = std.math.maxInt(u64) - 2;
/// The pipe a worker's SIGTERM handler writes to (`drain_signal`).
const drain_token: u64 = std.math.maxInt(u64) - 3;

/// Connection timeouts are checked on one periodic timer instead of a timer
/// per connection, so a request does not re-arm a kernel timer. A timeout is
/// reported up to this much after its deadline. The tick also ends the
/// grace before an overloaded worker answers 503.
const tick_milliseconds: u64 = 50;

/// How long an overloaded worker leaves new connections to the other
/// workers before it accepts them itself to answer 503: long enough
/// for another worker to take them, short enough to answer within 100 ms.
const overload_grace_milliseconds: u64 = 50;

/// A lingering close waits this long for the client to close, and discards
/// at most this many unread bytes, before closing anyway.
const linger_milliseconds: u64 = 2_000;
const linger_maximum_bytes: usize = 64 * 1024;

/// Buffer bytes all connections in one process may hold for bodies the loop
/// is still receiving. A request whose body would exceed it is answered 503
/// without running the handler, so the Roc thread never waits on a socket
/// for a body.
const maximum_prebuffer_bytes: usize = 64 * 1024 * 1024;

const buffer_allocator = std.heap.smp_allocator;

/// A parser from the allocator's raw functions: `create` in a safe build
/// would fill its header array, some kilobytes, for every head.
fn createParser() ?*http1.Parser {
    const memory = buffer_allocator.rawAlloc(
        @sizeOf(http1.Parser),
        std.mem.Alignment.of(http1.Parser),
        @returnAddress(),
    ) orelse return null;
    const parser: *http1.Parser = @ptrCast(@alignCast(memory));
    parser.reset();
    return parser;
}

pub fn destroyParser(parser: *http1.Parser) void {
    const memory: [*]u8 = @ptrCast(parser);
    buffer_allocator.rawFree(memory[0..@sizeOf(http1.Parser)], std.mem.Alignment.of(http1.Parser), @returnAddress());
}

/// Monotonic nanoseconds for access log durations, read by either thread. A
/// failed read, which the loop treats as fatal elsewhere, only zeroes one
/// duration here.
fn monotonicNow() u64 {
    return net.monotonicNanoseconds() catch 0;
}

fn monotonicReading() ?u64 {
    return net.monotonicNanoseconds() catch null;
}

pub const Connection = struct {
    pub const State = enum {
        free,
        /// Owned by the loop, waiting for a complete request head.
        reading,
        /// Owned by the loop, the head complete, waiting for the rest of a
        /// small body so a slow client does not hold the Roc thread.
        reading_body,
        /// Owned by the loop, finishing a response the Roc thread could not
        /// write without waiting.
        writing,
        /// Owned by the Roc thread until it posts a completion.
        dispatched,
        /// Owned by the loop after the last response: the write side is shut
        /// down and unread request bytes are discarded until the client
        /// closes, so closing does not reset the connection before the client
        /// has read the response.
        lingering,
    };

    /// Held by the thread acting on the connection: a Roc thread or
    /// the acceptor handling one of its events, or finishing a request on
    /// it. A Roc thread running the request (`dispatched`) does not hold it.
    lock: sync.Mutex = .{},
    /// Set while the slot holds a connection, so the acceptor's scans skip
    /// free slots without taking their locks.
    open: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accepted: net.AcceptedSocket = undefined,
    http2: ?*h2.Connection = null,
    generation: u32 = 0,
    state: State = State.free,
    buffer: []u8 = &.{},
    length: usize = 0,
    /// Bytes of the pending head already fed to a parser.
    parsed_length: usize = 0,
    /// Parser state for a head that did not arrive in one read; see
    /// `feedHead`.
    head_parser: ?*http1.Parser = null,
    /// The finished parse of a dispatched head, which the Roc thread's
    /// reader takes over rather than parsing the head again.
    parsed_head: ?*http1.Parser = null,
    completed_requests: usize = 0,
    /// Set by the owning fiber when a wait replaces this socket's watch.
    read_watch_replaced: bool = false,
    /// A short TCP head read exhausted the Linux socket. A later readable
    /// event, body handoff, or replaced watch invalidates this observation.
    read_exhausted: bool = false,
    /// What the loop did with the pending request, for the Roc thread.
    prefetch: connection.Prefetch = .{},
    /// While reading a Content-Length body: where it ends in `buffer`.
    body_end: usize = 0,
    /// While reading a chunked body: its decoder and the decoded bytes so far.
    chunked_body: ?ChunkedBody = null,
    /// While reading a body: buffer bytes counted against the loop's
    /// prebuffer budget.
    prebuffer_reserved: usize = 0,
    /// Valid while the loop owns the connection: when to close an idle
    /// connection or hand over an incomplete head for a 408, or when to give
    /// up on a pending response write.
    timeout: net.Deadline = undefined,
    /// Response bytes left for the loop to write: the first `output_length`
    /// bytes of `output`, an `std.heap.smp_allocator` allocation freed whole.
    output: []u8 = &.{},
    output_length: usize = 0,
    output_sent: usize = 0,
    close_after_output: bool = false,
    watching_writable: bool = false,
    /// While lingering: how many more bytes may be discarded.
    linger_remaining: usize = 0,
    /// The fiber of a request writing its response body, while it waits,
    /// and which wait: the loop wakes it when the client goes.
    stream_waiter: ?StreamWaiter = null,
    /// The client closed its side while a Roc thread had the connection.
    client_gone: bool = false,
    /// When the loop queued the request for the Roc thread, for the queue
    /// timeout.
    dispatched_at: u64 = 0,
    /// Never reset on connection reuse. Exhaustion closes instead of wrapping.
    dispatch_sequence: u64 = 0,
    dispatch_claimed: bool = false,

    /// The access log entry of a response the loop finishes writing,
    /// an `std.heap.smp_allocator` allocation. Only set while the access log
    /// is on and output is left to write: the loop records it once the
    /// output is written, or as `client_closed` when the connection closes
    /// first.
    access: ?*access_log.Entry = null,

    fn dispatchRequest(self: *Connection, slot: u32, now: u64) ?work_queue.Request {
        const sequence = std.math.add(u64, self.dispatch_sequence, 1) catch return null;
        self.dispatch_sequence = sequence;
        self.dispatch_claimed = false;
        self.dispatched_at = now;
        self.state = State.dispatched;
        return self.requestIdentity(slot);
    }

    fn requestIdentity(self: *const Connection, slot: u32) work_queue.Request {
        return .{ .slot = slot, .generation = self.generation, .sequence = self.dispatch_sequence, .queued_at = self.dispatched_at };
    }

    fn matchesRequest(self: *const Connection, request: work_queue.Request) bool {
        return self.state == State.dispatched and self.generation == request.generation and self.dispatch_sequence == request.sequence;
    }

    pub fn bytes(self: *const Connection) []const u8 {
        return self.buffer[0..self.length];
    }

    /// Replaces the pending bytes, growing the buffer when needed.
    /// A buffer grown for a body is replaced, so a connection that keeps
    /// pipelined bytes does not carry it into the next head.
    /// On failure the connection holds no bytes.
    pub fn store(self: *Connection, pending: []const u8) error{OutOfMemory}!void {
        if (pending.len > self.buffer.len or self.buffer.len > maximum_loop_buffer_bytes) {
            raw_bytes.free(self.buffer);
            self.buffer = &.{};
            self.length = 0;
            if (pending.len == 0) return;
            self.buffer = try raw_bytes.alloc(@max(pending.len, initial_buffer_bytes));
        }
        @memcpy(self.buffer[0..pending.len], pending);
        self.length = pending.len;
    }

    /// Feeds the bytes received since the last call, so each byte is parsed
    /// once however slowly the head arrives. A head that arrives in one read
    /// (the common case) is parsed by `shared` and allocates nothing; one
    /// still incomplete keeps a copy of the parser state with the connection.
    /// The parser holds offsets, not pointers, so the buffer may grow between
    /// calls.
    fn feedHead(self: *Connection, shared: *http1.Parser) HeadProgress {
        const pending = self.buffer[self.parsed_length..self.length];
        if (pending.len == 0) return HeadProgress.incomplete;
        const parser = self.head_parser orelse blk: {
            std.debug.assert(self.parsed_length == 0);
            shared.reset();
            break :blk shared;
        };
        const result = parser.feed(pending);
        self.parsed_length = self.length;
        switch (result) {
            http1.FeedResult.head_complete, http1.FeedResult.err => return HeadProgress.ready,
            http1.FeedResult.need_more => {},
        }
        if (self.head_parser == null) {
            const own = createParser() orelse return HeadProgress.out_of_memory;
            own.copyFrom(shared);
            self.head_parser = own;
        }
        return HeadProgress.incomplete;
    }

    /// Forgets the parse of the pending head; the next head starts fresh.
    fn resetHead(self: *Connection) void {
        if (self.head_parser) |parser| destroyParser(parser);
        self.head_parser = null;
        self.parsed_length = 0;
    }

    /// Keeps the parse of a head that just finished for the Roc thread. A
    /// head with a parse error, or no memory for the copy, is parsed again
    /// there.
    fn keepParsedHead(self: *Connection, shared: *const http1.Parser) void {
        std.debug.assert(self.parsed_head == null);
        if (self.head_parser) |own| {
            if (!own.isComplete()) return;
            self.parsed_head = own;
            self.head_parser = null;
            return;
        }
        if (!shared.isComplete()) return;
        const own = createParser() orelse return;
        own.copyFrom(shared);
        self.parsed_head = own;
    }

    /// The parse of the dispatched head, if the loop kept one; the caller
    /// frees it with `destroyParser`.
    pub fn takeParsedHead(self: *Connection) ?*http1.Parser {
        const parsed = self.parsed_head;
        self.parsed_head = null;
        return parsed;
    }

    fn dropParsedHead(self: *Connection) void {
        if (self.takeParsedHead()) |parser| destroyParser(parser);
    }

    /// Returns a head buffer grown past the initial size once the connection
    /// is idle, so idle keep-alive connections hold little memory. The next
    /// head allocates again.
    fn shrinkIdle(self: *Connection) void {
        std.debug.assert(self.length == 0);
        if (self.buffer.len <= initial_buffer_bytes) return;
        raw_bytes.free(self.buffer);
        self.buffer = &.{};
    }

    /// Records the access log line of a response that is done once its
    /// output is written: now when none is left, otherwise when the loop has
    /// written it. Called by whichever thread owns the connection.
    pub fn finishAccess(self: *Connection, entry: *const access_log.Entry) void {
        if (!access_log.enabled()) return;
        if (self.output_sent < self.output_length) {
            const kept = buffer_allocator.create(access_log.Entry) catch return access_log.record(entry, monotonicNow());
            kept.* = entry.*;
            self.dropAccess();
            self.access = kept;
            return;
        }
        access_log.record(entry, monotonicNow());
    }

    /// The access log entry for a response the host answers from the bytes
    /// the loop holds, which are a complete head or none at all.
    pub fn accessFromHead(self: *const Connection, outcome: access_log.Outcome, started_at: u64, source: request_id.Source) access_log.Entry {
        var entry = access_log.Entry{ .status = 503, .outcome = outcome, .started_at = started_at };
        var parser = http1.Parser{};
        const head_bytes = self.bytes();
        _ = parser.feed(head_bytes);
        const headers = if (parser.requestLine()) |line| blk: {
            entry.method.set(line.method.slice(head_bytes));
            const target = line.target.slice(head_bytes);
            entry.path.set(target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len]);
            break :blk parser.headers();
        } else &.{};
        entry.request_id = request_id.decide(source, headers, head_bytes);
        return entry;
    }

    /// Records the pending access log line as done or, when the output was
    /// not all written, as `client_closed`.
    fn recordAccess(self: *Connection, written: bool) void {
        const entry = self.access orelse return;
        if (!written) entry.outcome = access_log.Outcome.client_closed;
        access_log.record(entry, monotonicNow());
        self.dropAccess();
    }

    fn dropAccess(self: *Connection) void {
        const entry = self.access orelse return;
        buffer_allocator.destroy(entry);
        self.access = null;
    }

    fn release(self: *Connection) void {
        self.recordAccess(false);
        self.resetHead();
        self.dropParsedHead();
        // A body read cut short by a close must not carry over to the slot's
        // next connection.
        self.read_watch_replaced = false;
        self.read_exhausted = false;
        self.chunked_body = null;
        raw_bytes.free(self.buffer);
        self.buffer = &.{};
        self.length = 0;
        self.releaseOutput();
    }

    /// Replaces any output with an error response that closes the
    /// connection.
    fn setErrorResponse(self: *Connection, kind: error_response.Kind) error{OutOfMemory}!void {
        self.releaseOutput();
        var buffer: error_response.Buffer = undefined;
        const response = error_response.render(kind, http1_types.HttpVersion.http_1_1, &buffer);
        self.output = try raw_bytes.dupe(response);
        self.output_length = response.len;
        self.output_sent = 0;
    }

    fn releaseOutput(self: *Connection) void {
        raw_bytes.free(self.output);
        self.output = &.{};
        self.output_length = 0;
        self.output_sent = 0;
    }
};

const HeadProgress = enum {
    incomplete,
    /// A complete head or a parse error; the Roc thread answers either.
    ready,
    out_of_memory,
};

const StreamWaiter = struct {
    target: *fiber.Fiber,
    serial: u64,
    /// A drain ends the body.
    ends_on_drain: bool,
};

/// The client went while a Roc thread had its connection: a request
/// writing its body stops at its wait. Under the connection's lock.
fn clientGone(item: *Connection) void {
    item.client_gone = true;
    const waiter = item.stream_waiter orelse return;
    item.stream_waiter = null;
    fiber_wait.wakeStopped(waiter.target, waiter.serial, fiber.Stop.client_gone);
}

/// The worker drains while a Roc thread has the connection: a request
/// writing a body that may end then stops at its wait. Under the
/// connection's lock.
fn drainStream(item: *Connection) void {
    const waiter = item.stream_waiter orelse return;
    if (!waiter.ends_on_drain) return;
    item.stream_waiter = null;
    fiber_wait.wakeStopped(waiter.target, waiter.serial, fiber.Stop.drained);
}

/// The connection's side of a request's `fiber.StreamGuard`, for
/// the Roc thread that has the connection.
pub const ClientWatch = struct {
    handoff: *Handoff,
    slot: u32,

    pub fn arm(context: *anyopaque, target: *fiber.Fiber, serial: u64, ends_on_drain: bool) fiber.Stop {
        const self: *ClientWatch = @ptrCast(@alignCast(context));
        const item = &self.handoff.connections[self.slot];
        item.lock.lock();
        defer item.lock.unlock();
        if (item.client_gone) return fiber.Stop.client_gone;
        // The loop sets `draining` before it looks at the connections, each
        // under its lock: a wait named after that look sees it here.
        if (ends_on_drain and self.handoff.draining.load(std.builtin.AtomicOrder.acquire)) return fiber.Stop.drained;
        item.stream_waiter = .{ .target = target, .serial = serial, .ends_on_drain = ends_on_drain };
        return fiber.Stop.none;
    }

    pub fn disarm(context: *anyopaque) void {
        const self: *ClientWatch = @ptrCast(@alignCast(context));
        const item = &self.handoff.connections[self.slot];
        item.lock.lock();
        defer item.lock.unlock();
        item.stream_waiter = null;
    }

    /// After a wait on the client socket itself: puts back the
    /// connection's persistent read registration after a one-shot wait.
    pub fn restore(context: *anyopaque) void {
        const self: *ClientWatch = @ptrCast(@alignCast(context));
        const item = &self.handoff.connections[self.slot];
        const poller = self.handoff.poller orelse return;
        poller.restoreReadable(item.accepted.socket, Loop.token(self.slot, item.generation)) catch {};
    }
};

pub const Completion = struct {
    pub const Action = enum {
        /// Keep the connection after writing any stored output.
        reuse,
        /// Write any stored output, then linger and close. Only the loop
        /// closes connections it handed out.
        close,
    };

    request: work_queue.Request,
    action: Action,
};

/// What a process's threads share: its connections and their free
/// slots, its poller, its jobs, and its counts. A connection is acted on by
/// one thread at a time, under its lock; a request a Roc thread runs is
/// its own until it completes.
pub const Handoff = struct {
    connections: []Connection,
    http2: bool = false,
    limits: connection.Limits = .{},
    /// The process's poller: every connection's socket and every waiting
    /// fiber's. The Roc threads wait on it, and the acceptor looks at it when
    /// they are all busy.
    poller: ?*poller_backend.Poller = null,
    /// The process's jobs for its Roc threads: new requests, stream steps,
    /// and fibers whose wait ended. Set up before any connection is
    /// accepted.
    work: work_queue.Jobs = .{},
    /// The process's waiting fibers, whose sockets `poller` also watches.
    waits: ?*scheduler.Waits = null,
    free_lock: sync.Mutex = .{},
    free_slots: []u32 = &.{},
    free_count: usize = 0,
    /// Sum of `prebuffer_reserved` over all connections.
    prebuffer_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Set by the acceptor while it does not accept for want of a slot or
    /// because of overload; a freed slot then wakes it (`acceptor_poller`).
    accept_paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    acceptor_poller: ?*poller_backend.Poller = null,
    /// When a Roc thread last looked at the poller, so the acceptor knows
    /// when every one is busy.
    last_poll_at: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Requests the Roc threads have started and not finished, which the
    /// acceptor reads to tell whether the process is overloaded.
    in_progress: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Bodies handlers write as they go, for `maximum_streams` and
    /// the metrics.
    active_streams: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Set by the acceptor when the process drains. Every thread
    /// reads it: a response then says `Connection: close`.
    draining: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Room for `capacity` connections, all free.
    pub fn init(capacity: u32) error{OutOfMemory}!Handoff {
        const connections = try std.heap.page_allocator.alloc(Connection, capacity);
        for (connections) |*slot| slot.* = .{};
        const free_slots = try std.heap.page_allocator.alloc(u32, capacity);
        for (free_slots, 0..) |*slot, index| slot.* = @intCast(capacity - 1 - index);
        return .{
            .connections = connections,
            .free_slots = free_slots,
            .free_count = capacity,
        };
    }

    fn dispatch(self: *Handoff, slot: u32) void {
        const request = self.connections[slot].dispatchRequest(slot, self.connections[slot].dispatched_at) orelse unreachable;
        self.work.push(.{ .request = request }) catch diagnostics.fatal("out of memory queueing a request");
    }

    /// Takes back the requests that have waited for a Roc thread since
    /// before `dispatched_before`, from every queue, appending their identities
    /// to `into`.
    fn takeExpired(self: *Handoff, dispatched_before: u64, into: *std.ArrayList(work_queue.Request)) error{OutOfMemory}!void {
        const Expiry = struct {
            fn expired(before: u64, request: work_queue.Request) bool {
                return request.queued_at < before;
            }
        };
        try self.work.takeExpired(dispatched_before, Expiry.expired, into);
    }

    /// Claim under the connection lock before admission or touching request
    /// buffers. The current HTTP/1 lifetime pins this slot until completion.
    pub fn claimRequest(self: *Handoff, request: work_queue.Request) bool {
        if (request.slot >= self.connections.len) return false;
        const item = &self.connections[request.slot];
        item.lock.lock();
        defer item.lock.unlock();
        if (request.http2) |ticket| {
            if (item.generation != request.generation) return false;
            const protocol = item.http2 orelse return false;
            const execution = protocol.execution(ticket) orelse return false;
            if (execution.claimed) return false;
            execution.claimed = true;
            return true;
        }
        if (!item.matchesRequest(request) or item.dispatch_claimed) return false;
        item.dispatch_claimed = true;
        return true;
    }

    /// Requests queued for a Roc thread and not taken yet.
    pub fn queuedJobs(self: *Handoff) usize {
        return self.work.queuedRequests();
    }

    /// Connections open now.
    pub fn openConnections(self: *Handoff) usize {
        self.free_lock.lock();
        defer self.free_lock.unlock();
        return self.connections.len - self.free_count;
    }

    fn takeSlot(self: *Handoff) ?u32 {
        self.free_lock.lock();
        defer self.free_lock.unlock();
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        return self.free_slots[self.free_count];
    }

    fn giveSlot(self: *Handoff, slot: u32) void {
        {
            self.free_lock.lock();
            defer self.free_lock.unlock();
            self.free_slots[self.free_count] = slot;
            self.free_count += 1;
        }
        // A paused acceptor takes the slot for a waiting connection.
        if (self.accept_paused.load(std.builtin.AtomicOrder.acquire)) {
            if (self.acceptor_poller) |poller| poller.wake() catch {};
        }
    }

    fn hasFreeSlot(self: *Handoff) bool {
        self.free_lock.lock();
        defer self.free_lock.unlock();
        return self.free_count > 0;
    }
};

/// Runs the acceptor on the calling thread. It accepts, keeps
/// time (timeouts, the queue timeout's 503s, the gauges, the drain), and
/// acts on connections itself only while every Roc thread is busy, so the
/// 503s go out even then. It never runs Roc code. The Roc threads act on
/// the connections' events from the process's poller (`Loop.onEvent`).
pub fn run(
    listener: net.Socket,
    handoff: *Handoff,
) !noreturn {
    raiseDescriptorLimit(handoff.connections.len);

    var own = try poller_backend.Poller.init();
    defer own.deinit();
    try own.registerWake(wake_token);
    try drain_signal.init();
    try own.watchReadable(drain_signal.readEnd(), drain_token);
    try own.armRepeatingTimer(tick_milliseconds, tick_token);
    handoff.acceptor_poller = &own;
    try net.setListenerNonBlocking(listener);
    try own.watchReadable(listener, listener_token);

    var loop = Loop.init(handoff);
    loop.listener = listener;
    loop.acceptor_poller = &own;
    loop.readClock();
    loop.acceptPending();

    var raw: [event_batch]poller_backend.RawEvent = undefined;
    var events: [event_batch * poller_backend.events_per_raw]poller_backend.Event = undefined;
    while (true) {
        const batch = try own.wait(&raw, &events, null);
        loop.readClock();
        for (batch) |event| {
            switch (event.kind) {
                poller_backend.Event.Kind.readable => if (event.token == listener_token)
                    loop.acceptPending()
                else if (event.token == drain_token)
                    loop.onDrainSignal(),
                poller_backend.Event.Kind.writable => {},
                poller_backend.Event.Kind.timer => loop.tick(),
                // A Roc thread freed a slot while accept was paused.
                poller_backend.Event.Kind.wake => if (loop.accept_paused and !loop.overload_paused) {
                    loop.setAcceptPaused(false);
                    loop.acceptPending();
                },
            }
        }
        // The Roc threads caught up: accept again.
        if (loop.overload_paused and !loop.overloaded()) {
            loop.overload_paused = false;
            loop.overloaded_since = null;
            loop.setAcceptPaused(false);
            loop.acceptPending();
        }
        loop.finishDrainWhenEmpty();
    }
}

/// Raises the soft descriptor limit toward the hard limit. The default soft
/// limits (256 on macOS, 1024 on Linux) would stop a loop holding a few
/// hundred keep-alive connections; accept pauses on exhaustion either way, so
/// failure here is not fatal.
fn raiseDescriptorLimit(connections: usize) void {
    var current: std.c.rlimit = undefined;
    if (std.c.getrlimit(std.c.rlimit_resource.NOFILE, &current) != 0) return;
    // macOS rejects soft limits above the per-process maximum, so try the
    // largest useful value first and fall back to the common OPEN_MAX.
    // Outbound connections (PostgreSQL, HTTP) and files need descriptors
    // too, so ask for twice the inbound connections.
    for ([_]std.c.rlim_t{ @intCast(connections * 2), 10_240 }) |wanted| {
        const target = @min(wanted, current.max);
        if (target <= current.cur) return;
        const raised = std.c.rlimit{ .cur = target, .max = current.max };
        if (std.c.setrlimit(std.c.rlimit_resource.NOFILE, &raised) == 0) return;
    }
}

const PrebufferBody = union(enum) {
    /// Where a Content-Length body ends, counted from the start of the head.
    content_length_end: usize,
    /// Where a chunked body starts; the loop decodes it to find the end.
    chunked_start: usize,
};

const Prebuffer = struct {
    body: PrebufferBody,
};

const BodyPlan = union(enum) {
    /// Hand the request over now: it has no body, a Content-Length body
    /// larger than the loop receives (the handler's reads wait for it), `Expect: 100-continue`, or an error to answer.
    dispatch_now,
    prebuffer: Prebuffer,
};

/// Decides, from a parser that just finished, whether the loop waits for
/// the body: a Content-Length body it receives whole, or a chunked body, on
/// a head the host would accept. A rejected head is answered at once,
/// without 100 Continue, exactly as the Roc thread would answer it. A
/// request expecting 100 Continue goes to the Roc thread at once: its
/// pre-body layers decide before the client sends the body, and the first
/// body read sends 100 Continue.
fn bodyPlan(parser: *const http1.Parser, head_bytes: []const u8) BodyPlan {
    const request_line = parser.requestLine() orelse return BodyPlan.dispatch_now;
    const framing = parser.bodyFraming() orelse return BodyPlan.dispatch_now;
    const head_length: usize = parser.offset;
    if (!request_limits.headLengthIsAllowed(head_length)) return BodyPlan.dispatch_now;
    if (!request_limits.requestTargetLengthIsAllowed(request_line.target.len)) return BodyPlan.dispatch_now;
    const body: PrebufferBody = switch (framing) {
        http1.BodyFraming.none => return BodyPlan.dispatch_now,
        http1.BodyFraming.content_length => |length| blk: {
            const body_length = request_limits.prebufferedBodyLength(length) orelse return BodyPlan.dispatch_now;
            if (body_length == 0) return BodyPlan.dispatch_now;
            break :blk PrebufferBody{ .content_length_end = head_length + body_length };
        },
        http1.BodyFraming.chunked => PrebufferBody{ .chunked_start = head_length },
    };
    return switch (connection.screenHead(request_line, parser.headers(), head_bytes, framing)) {
        connection.Screen.reject => BodyPlan.dispatch_now,
        connection.Screen.proceed => |proceed| if (proceed.send_continue)
            BodyPlan.dispatch_now
        else
            BodyPlan{ .prebuffer = .{ .body = body } },
    };
}

const ChunkedProgress = enum {
    /// The body is not complete yet.
    more,
    /// The whole body, through its trailer section, is decoded.
    complete,
    /// The framing is invalid: the Roc thread answers 400.
    invalid,
    /// The framing is out of proportion to the data: the Roc thread answers
    /// 413.
    too_large,
};

/// A chunked body the loop decodes in place: the buffer holds the head, then
/// the decoded body bytes so far. Framing bytes are dropped as they are
/// decoded, so the buffer needs room for the head and the decoded body only,
/// however many wire bytes the framing takes.
const ChunkedBody = struct {
    decoder: chunked.Decoder = .{},
    /// Where the body starts in the buffer: the head's end.
    start: usize,
    /// Where the decoded bytes end in the buffer. They start right after the
    /// head.
    decoded_end: usize,
    /// Body bytes on the wire so far, framing included.
    wire: usize = 0,
};

/// Decodes `buffer[body.decoded_end..length.*]` and moves the decoded bytes
/// down to follow the bytes decoded before, setting `length.*` to their end.
/// On `complete`, the bytes after the body, such as a pipelined request,
/// follow the decoded body and `length.*` includes them.
fn decodeChunked(body: *ChunkedBody, buffer: []u8, length: *usize) ChunkedProgress {
    var parsed = body.decoded_end;
    while (parsed < length.*) {
        const result = body.decoder.feed(buffer[parsed..length.*]);
        const consumed = switch (result) {
            chunked.FeedResult.need_more => |progress| progress.consumed,
            chunked.FeedResult.data => |data| data.consumed,
            chunked.FeedResult.complete => |completion| completion.consumed,
            chunked.FeedResult.err => return ChunkedProgress.invalid,
        };
        body.wire += consumed;
        if (request_limits.framingIsExcessive(body.wire, body.decoder.decoded_length)) return ChunkedProgress.too_large;
        switch (result) {
            chunked.FeedResult.data => |data| {
                // The data lies at or after `decoded_end`, so a forward copy
                // never overwrites bytes it has yet to read.
                std.mem.copyForwards(u8, buffer[body.decoded_end..][0..data.bytes.len], data.bytes);
                body.decoded_end += data.bytes.len;
            },
            chunked.FeedResult.complete => {
                const rest = buffer[parsed + consumed .. length.*];
                std.mem.copyForwards(u8, buffer[body.decoded_end..][0..rest.len], rest);
                length.* = body.decoded_end + rest.len;
                return ChunkedProgress.complete;
            },
            chunked.FeedResult.need_more, chunked.FeedResult.err => {},
        }
        parsed += consumed;
    }
    length.* = body.decoded_end;
    return ChunkedProgress.more;
}

const LingerStep = enum {
    /// Wait for the next readable event.
    would_block,
    /// The client closed, the budget ran out, or the socket failed: close.
    finished,
};

/// Discards readable bytes until the socket would block, counting them
/// against `remaining`.
fn lingerStep(socket: net.Socket, scratch: []u8, remaining: *usize) LingerStep {
    while (remaining.* > 0) {
        const limit = @min(scratch.len, remaining.*);
        const received = net.receiveAvailable(socket, scratch[0..limit]) catch return LingerStep.finished;
        const count = received orelse return LingerStep.would_block;
        if (count == 0) return LingerStep.finished;
        remaining.* -= count;
    }
    return LingerStep.finished;
}

/// Every per-connection step returns `void`: a failure on one connection
/// closes that connection and never ends the loop, which holds every other
/// connection of the process.
/// A thread's view of the process's connections: the acceptor's,
/// and one for each Roc thread. Its own parts are the clock reading, the
/// head parser, and scratch space; the acceptor's also hold the listener,
/// accept, overload, and drain state. Every step on a connection runs with
/// the connection's lock held.
pub const Loop = struct {
    handoff: *Handoff,
    poller: *poller_backend.Poller,
    limits: connection.Limits,
    /// The Roc thread this view belongs to; null for the acceptor's.
    thread_index: ?usize = null,
    /// The acceptor's own: the listener, and the poller that watches it.
    listener: net.Socket = -1,
    acceptor_poller: ?*poller_backend.Poller = null,
    accept_paused: bool = false,
    /// Set after warning about an accept failure, until the next success,
    /// so a failing listener does not flood the log.
    accept_warned: bool = false,
    /// Monotonic time read once per batch of events. Every deadline the loop
    /// sets or checks uses it, so no per-connection step needs the clock.
    now: u64 = 0,
    parser: http1.Parser = .{},
    /// Where lingering connections' discarded bytes go.
    scratch: [16 * 1024]u8 = undefined,
    /// Requests the tick takes back from the queues for waiting too long.
    expired: std.ArrayList(work_queue.Request) = .empty,
    /// The acceptor's: the drain began. Accept has stopped, idle
    /// connections are closed, every response closes its connection, and
    /// the process exits once no connection is left or `drain_deadline`
    /// passes.
    draining: bool = false,
    drain_deadline: net.Deadline = undefined,
    /// Set while accept is paused because the process is overloaded,
    /// with when the overload began.
    overload_paused: bool = false,
    overloaded_since: ?u64 = null,

    pub fn init(handoff: *Handoff) Loop {
        return .{ .handoff = handoff, .poller = handoff.poller.?, .limits = handoff.limits };
    }

    /// A Roc thread's view: what it reads goes to its own queue.
    pub fn initRoc(handoff: *Handoff, thread_index: usize) Loop {
        var loop = Loop.init(handoff);
        loop.thread_index = thread_index;
        return loop;
    }

    fn token(slot: u32, generation: u32) u64 {
        return (@as(u64, generation) << 32) | slot;
    }

    /// The loop cannot run without a monotonic clock, and its failure is
    /// not caused by any one connection.
    pub fn readClock(self: *Loop) void {
        self.now = net.monotonicNanoseconds() catch diagnostics.fatal("monotonic clock read failed");
    }

    fn after(self: *const Loop, milliseconds: u64) net.Deadline {
        return net.Deadline.fromNow(self.now, milliseconds);
    }

    fn drainingNow(self: *const Loop) bool {
        return self.handoff.draining.load(std.builtin.AtomicOrder.acquire);
    }

    fn setAcceptPaused(self: *Loop, paused: bool) void {
        self.accept_paused = paused;
        self.handoff.accept_paused.store(paused, std.builtin.AtomicOrder.release);
    }

    /// Acts on a connection's event from the process's poller. An event for
    /// a connection closed since, or not in a state that waits for it, is
    /// not read immediately. Readable notifications while dispatched or
    /// writing invalidate a previous observation of an exhausted socket.
    pub fn onEvent(self: *Loop, event: poller_backend.Event) void {
        const slot: u32 = @truncate(event.token);
        const generation: u32 = @truncate(event.token >> 32);
        if (slot >= self.handoff.connections.len) return;
        const item = &self.handoff.connections[slot];
        item.lock.lock();
        defer item.lock.unlock();
        if (item.generation != generation) return;
        if (item.http2) |protocol| {
            _ = protocol.owner.ready(event);
            return self.advanceHttp2(slot);
        }
        switch (event.kind) {
            poller_backend.Event.Kind.readable => {
                item.read_exhausted = false;
                switch (item.state) {
                    Connection.State.reading => self.advance(slot),
                    Connection.State.reading_body => self.advanceBody(slot),
                    Connection.State.lingering => self.drainLinger(slot),
                    Connection.State.dispatched => if (event.hangup) clientGone(item),
                    else => {},
                }
                // A short read can precede EOF in this same notification.
                if (event.hangup) item.read_exhausted = false;
            },
            poller_backend.Event.Kind.writable => if (item.state == Connection.State.writing) self.flush(slot),
            else => {},
        }
    }

    /// Takes back a connection whose request (or stream step) a Roc thread
    /// finished, writing what it left and reading on, lingering, or queuing
    /// the stream's next step.
    pub fn complete(self: *Loop, completion: Completion) void {
        if (completion.request.slot >= self.handoff.connections.len) return;
        const item = &self.handoff.connections[completion.request.slot];
        item.lock.lock();
        defer item.lock.unlock();
        if (!item.matchesRequest(completion.request)) return;
        self.readClock();
        self.resumeConnection(completion);
    }

    /// Answers a request a Roc thread took 503 without running it, and
    /// closes after.
    pub fn rejectTaken(self: *Loop, request: work_queue.Request, write_deadline: net.Deadline, outcome: access_log.Outcome, source: request_id.Source) void {
        if (request.slot >= self.handoff.connections.len) return;
        const item = &self.handoff.connections[request.slot];
        item.lock.lock();
        defer item.lock.unlock();
        if (request.http2 != null) return self.finishHttp2Locked(request, outcome);
        if (!item.matchesRequest(request)) return;
        self.readClock();
        item.setErrorResponse(error_response.Kind.service_unavailable) catch return self.resumeConnection(.{ .request = request, .action = Completion.Action.close });
        item.timeout = write_deadline;
        if (access_log.enabled()) {
            const entry = item.accessFromHead(outcome, item.dispatched_at, source);
            item.finishAccess(&entry);
        }
        self.resumeConnection(.{ .request = request, .action = Completion.Action.close });
    }

    /// Answers 500 and closes, for a request whose Roc code crashed
    ///. What it had written is dropped; the connection may be
    /// mid-request, so it does not stay open. `entry` is the request's
    /// access log entry as far as it got.
    pub fn fail(self: *Loop, request: work_queue.Request, write_deadline: net.Deadline, entry: *const access_log.Entry) void {
        if (request.slot >= self.handoff.connections.len) return;
        const item = &self.handoff.connections[request.slot];
        item.lock.lock();
        defer item.lock.unlock();
        if (!item.matchesRequest(request)) return;
        self.readClock();
        item.setErrorResponse(error_response.Kind.internal_server_error) catch return self.resumeConnection(.{ .request = request, .action = Completion.Action.close });
        item.timeout = write_deadline;
        var crashed = entry.*;
        crashed.status = 500;
        crashed.outcome = access_log.Outcome.crashed;
        crashed.body_bytes = 0;
        item.finishAccess(&crashed);
        self.resumeConnection(.{ .request = request, .action = Completion.Action.close });
    }

    /// Closes the connection of a request that stopped after the head of
    /// its written body went out: its Roc code crashed, or its client
    /// went. Only the body stops.
    pub fn failWritten(self: *Loop, request: work_queue.Request, entry: *const access_log.Entry, outcome: access_log.Outcome) void {
        if (request.slot >= self.handoff.connections.len) return;
        const item = &self.handoff.connections[request.slot];
        item.lock.lock();
        defer item.lock.unlock();
        if (!item.matchesRequest(request)) return;
        self.readClock();
        var stopped = entry.*;
        stopped.outcome = outcome;
        item.finishAccess(&stopped);
        self.resumeConnection(.{ .request = request, .action = Completion.Action.close });
    }

    /// Accepts until the listener has nothing queued. Pauses when no slot is
    /// free, descriptors run out, or accept fails for the listener as a
    /// whole; the timer tick and freed slots resume it.
    fn acceptPending(self: *Loop) void {
        if (self.draining) return;
        // Paused for want of a slot: a new connection, or one still
        // waiting, may take the slot of an idle keep-alive connection.
        if (self.accept_paused and !self.handoff.hasFreeSlot() and !self.overload_paused) self.setAcceptPaused(false);
        // Overloaded: leave new connections to the other workers,
        // which share the listener. Past the grace, take them and answer
        // 503, so no client waits in the kernel's queue without an answer.
        var reject_new = false;
        if (self.overloaded()) {
            const since = self.overloaded_since orelse blk: {
                self.overloaded_since = self.now;
                break :blk self.now;
            };
            if (self.now -| since < overload_grace_milliseconds * std.time.ns_per_ms) {
                self.overload_paused = true;
                self.setAcceptPaused(true);
                return;
            }
            reject_new = true;
        } else {
            self.overloaded_since = null;
        }
        while (!self.accept_paused) {
            // Every slot taken: give the longest-idle keep-alive connection's
            // slot to the new one, as nginx does; its client only connects
            // again. Without one, wait for a slot.
            if (!self.handoff.hasFreeSlot() and !(self.listenerHasPending() and self.closeLongestIdle())) {
                self.setAcceptPaused(true);
                return;
            }
            switch (net.acceptPending(self.listener)) {
                net.PendingAccept.accepted => |accepted| {
                    self.accept_warned = false;
                    if (reject_new) self.openRejected(accepted) else self.open(accepted);
                },
                net.PendingAccept.none => return,
                net.PendingAccept.exhausted => {
                    self.setAcceptPaused(true);
                    return;
                },
                net.PendingAccept.failed => {
                    if (!self.accept_warned) {
                        diagnostics.warning("accept failed; retrying on the next timer tick");
                        self.accept_warned = true;
                    }
                    self.setAcceptPaused(true);
                    return;
                },
            }
        }
    }

    /// Whether the worker is overloaded: too many requests queued for
    /// the Roc thread, too many it started and has not finished, or its
    /// requests' memory near the limit.
    fn overloaded(self: *Loop) bool {
        return self.handoff.queuedJobs() >= self.limits.maximum_queued_requests or
            self.handoff.in_progress.load(std.builtin.AtomicOrder.acquire) >= self.limits.maximum_requests_in_progress or
            request_memory.nearLimit();
    }

    /// Whether a connection waits on the listener, without accepting it.
    fn listenerHasPending(self: *Loop) bool {
        var descriptor = [1]std.c.pollfd{.{ .fd = self.listener, .events = std.c.POLL.IN, .revents = 0 }};
        return std.c.poll(&descriptor, 1, 0) > 0 and descriptor[0].revents & std.c.POLL.IN != 0;
    }

    /// Closes the keep-alive connection that has waited longest for its next
    /// request: one that served a request and holds no bytes. All idle ones
    /// share the keep-alive timeout, so the earliest deadline is the longest
    /// wait. False when there is none.
    fn closeLongestIdle(self: *Loop) bool {
        var oldest: ?u32 = null;
        var oldest_deadline: u64 = std.math.maxInt(u64);
        for (self.handoff.connections, 0..) |*item, index| {
            if (!item.open.load(std.builtin.AtomicOrder.acquire)) continue;
            // One a thread is acting on is not idle.
            if (!item.lock.tryLock()) continue;
            defer item.lock.unlock();
            if (!isIdle(item)) continue;
            if (item.timeout.expires_at_nanoseconds < oldest_deadline) {
                oldest_deadline = item.timeout.expires_at_nanoseconds;
                oldest = @intCast(index);
            }
        }
        const slot = oldest orelse return false;
        const item = &self.handoff.connections[slot];
        item.lock.lock();
        defer item.lock.unlock();
        // A request may have arrived on it meanwhile.
        if (!isIdle(item)) return false;
        self.close(slot);
        return true;
    }

    fn isIdle(item: *const Connection) bool {
        if (item.http2) |protocol| return !protocol.busy() and protocol.owner.engine.activeStreams() == 0 and protocol.owner.engine.pending.len == 0;
        return item.state == Connection.State.reading and item.length == 0 and item.completed_requests > 0;
    }

    /// Takes a connection only to answer it 503 and close it.
    fn openRejected(self: *Loop, accepted: net.AcceptedSocket) void {
        if (self.handoff.http2) return net.closeSocket(accepted.socket);
        const slot = self.handoff.takeSlot().?;
        const item = &self.handoff.connections[slot];
        item.lock.lock();
        defer item.lock.unlock();
        item.accepted = accepted;
        item.generation +%= 1;
        item.open.store(true, std.builtin.AtomicOrder.release);
        item.length = 0;
        item.completed_requests = 0;
        item.client_gone = false;
        item.read_exhausted = false;
        item.prefetch = .{};
        self.poller.watchReadable(accepted.socket, token(slot, item.generation)) catch {
            item.state = Connection.State.reading;
            return self.close(slot);
        };
        self.reject(slot, access_log.Outcome.overloaded, self.now);
    }

    /// Answers 503 from the loop and closes after writing it.
    /// `started_at` is when the request's head was complete, or when the
    /// connection was accepted for one answered unread.
    fn reject(self: *Loop, slot: u32, outcome: access_log.Outcome, started_at: u64) void {
        const item = &self.handoff.connections[slot];
        item.resetHead();
        item.dropParsedHead();
        self.releasePrebuffer(item);
        item.state = Connection.State.writing;
        item.setErrorResponse(error_response.Kind.service_unavailable) catch return self.close(slot);
        if (access_log.enabled()) {
            const entry = item.accessFromHead(outcome, started_at, self.limits.request_id_source);
            item.finishAccess(&entry);
        }
        item.close_after_output = true;
        item.timeout = self.after(self.limits.response_write_timeout_milliseconds);
        self.flush(slot);
    }

    fn open(self: *Loop, accepted: net.AcceptedSocket) void {
        const slot = self.handoff.takeSlot().?;
        const item = &self.handoff.connections[slot];
        item.lock.lock();
        defer item.lock.unlock();
        item.accepted = accepted;
        item.generation +%= 1;
        item.open.store(true, std.builtin.AtomicOrder.release);
        item.state = Connection.State.reading;
        item.length = 0;
        item.completed_requests = 0;
        item.client_gone = false;
        item.prefetch = .{};
        item.timeout = self.after(self.limits.initial_request_timeout_milliseconds);
        if (self.handoff.http2) {
            item.http2 = h2.Connection.create(accepted.socket, self.poller, token(slot, item.generation), self.limits) catch return self.close(slot);
            return self.advanceHttp2(slot);
        }
        // The socket stays registered while a Roc thread runs its request;
        // readable notifications invalidate the last exhaustion observation.
        self.poller.watchReadable(accepted.socket, token(slot, item.generation)) catch
            return self.close(slot);
        self.advance(slot);
    }

    /// The worker lock serializes callbacks, transport steps and submissions.
    /// Bounded turns leave runnable work for the acceptor tick as well as events.
    fn advanceHttp2(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        const protocol = item.http2 orelse return;
        if (protocol.closed) return;
        protocol.expire(self.now);
        if (protocol.failed) return self.close(slot);
        for (0..4) |_| {
            const progress = protocol.owner.step() catch return self.close(slot);
            if (protocol.failed) return self.close(slot);
            protocol.recordCompleted();
            protocol.wakeClosed();
            if (progress == @import("http2/owner.zig").Progress.closed) return self.close(slot);
            while (protocol.streams.next()) |work| {
                switch (work) {
                    h2_streams.Work.cancel => |id| protocol.owner.cancel(id) catch return self.close(slot),
                    h2_streams.Work.execute => |execution| {
                        if (access_log.enabled()) {
                            const fields = execution.buffer.fields.items;
                            var entry = access_log.Entry{
                                .request_id = @import("request_id.zig").decideFields(self.limits.request_id_source, fields),
                                .started_at = self.now,
                            };
                            for (fields) |field| {
                                if (std.mem.eql(u8, field.name, ":method")) entry.method.set(field.value);
                                if (std.mem.eql(u8, field.name, ":path")) entry.path.set(field.value[0 .. std.mem.indexOfScalar(u8, field.value, '?') orelse field.value.len]);
                            }
                            protocol.access[execution.ticket.slot] = entry;
                        }
                        if (self.handoff.queuedJobs() >= self.limits.maximum_queued_requests) {
                            if (protocol.access[execution.ticket.slot]) |*entry| entry.outcome = access_log.Outcome.queue_full;
                            protocol.owner.cancel(execution.id) catch {};
                            _ = protocol.streams.finish(execution.ticket);
                            continue;
                        }
                        protocol.deadlines[execution.ticket.slot] = 0;
                        protocol.executions[execution.ticket.slot] = .{ .ticket = execution.ticket };
                        self.queue(.{ .request = .{ .slot = slot, .generation = item.generation, .sequence = execution.ticket.sequence, .queued_at = self.now, .http2 = execution.ticket } });
                    },
                }
            }
            if (protocol.draining and !protocol.busy() and protocol.owner.engine.activeStreams() == 0 and (protocol.owner.engine.output() catch return self.close(slot)).len == 0) return self.close(slot);
            if (progress == @import("http2/owner.zig").Progress.waiting) break;
        }
    }

    pub fn finishHttp2(self: *Loop, request: work_queue.Request, failure: ?access_log.Outcome) void {
        const item = &self.handoff.connections[request.slot];
        item.lock.lock();
        defer item.lock.unlock();
        self.finishHttp2Locked(request, failure);
    }

    fn finishHttp2Locked(self: *Loop, request: work_queue.Request, failure: ?access_log.Outcome) void {
        const item = &self.handoff.connections[request.slot];
        if (item.generation != request.generation) return;
        const protocol = item.http2 orelse return;
        const ticket = request.http2 orelse return;
        const execution = protocol.execution(ticket) orelse return;
        execution.waiter = null;
        if (failure) |outcome| {
            if (protocol.access[ticket.slot]) |*entry| entry.outcome = outcome;
            if (protocol.streams.leases.runningStream(ticket)) |id| protocol.owner.cancel(id) catch {};
        }
        _ = protocol.streams.finish(ticket);
        execution.* = .{};
        self.readClock();
        item.timeout = self.after(self.limits.keep_alive_idle_timeout_milliseconds);
        if (protocol.closed) {
            if (!protocol.busy()) self.close(request.slot);
            return;
        }
        self.advanceHttp2(request.slot);
    }

    /// Reads until the socket would block, dispatching once the buffered
    /// bytes hold a request head or cannot become a valid one.
    fn advance(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        if (self.headProgress(slot) != HeadProgress.incomplete) return;

        while (true) {
            // The Roc thread answers 431; the lingering close after it
            // discards whatever else the client sends.
            if (item.length >= maximum_loop_buffer_bytes) return self.dispatch(slot);
            if (item.length == item.buffer.len) {
                const grown = @min(
                    @max(initial_buffer_bytes, item.buffer.len * 2),
                    maximum_loop_buffer_bytes,
                );
                item.buffer = raw_bytes.realloc(item.buffer, grown) catch return self.close(slot);
            }

            const received = net.receiveAvailable(
                item.accepted.socket,
                item.buffer[item.length..],
            ) catch return self.close(slot);
            const count = received orelse return;
            if (count == 0) {
                // A clean close between requests needs no response; a close
                // inside a head is reported by the Roc thread's reader.
                if (item.length == 0) return self.close(slot);
                return self.dispatch(slot);
            }

            // epoll(7): a short stream read exhausts the current readable
            // bytes. Notifications received while dispatched are retained.
            item.read_exhausted = headReadExhausted(count, item.buffer.len - item.length);

            const first_bytes = item.length == 0;
            item.length += count;
            if (first_bytes) self.startHead(slot);
            if (self.headProgress(slot) != HeadProgress.incomplete) return;
        }
    }

    /// Feeds new bytes and acts on the result: dispatches a finished head,
    /// closes when the parser state cannot be kept.
    fn headProgress(self: *Loop, slot: u32) HeadProgress {
        const item = &self.handoff.connections[slot];
        const progress = item.feedHead(&self.parser);
        switch (progress) {
            HeadProgress.incomplete => {},
            HeadProgress.ready => self.finishHead(slot),
            HeadProgress.out_of_memory => self.close(slot),
        }
        return progress;
    }

    fn startHead(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        const head_deadline = self.after(self.limits.request_head_timeout_milliseconds);
        item.prefetch = .{ .head_deadline = head_deadline };
        item.timeout = head_deadline;
    }

    /// The head is complete or invalid. Waits for a small body here when the
    /// Roc thread would otherwise wait for it.
    fn finishHead(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        const parser = item.head_parser orelse &self.parser;
        const plan = bodyPlan(parser, item.bytes());
        const bodyless = if (parser.bodyFraming()) |framing| switch (framing) {
            http1.BodyFraming.none => true,
            http1.BodyFraming.content_length => |length| length == 0,
            http1.BodyFraming.chunked => false,
        } else false;
        if (!bodyless) item.read_exhausted = false;
        item.keepParsedHead(&self.parser);
        switch (plan) {
            BodyPlan.dispatch_now => self.dispatch(slot),
            BodyPlan.prebuffer => |prebuffer| {
                item.resetHead();
                self.startBody(slot, prebuffer);
            },
        }
    }

    fn startBody(self: *Loop, slot: u32, prebuffer: Prebuffer) void {
        const item = &self.handoff.connections[slot];
        const body_deadline = self.after(self.limits.request_body_timeout_milliseconds);
        item.prefetch.body_deadline = body_deadline;
        switch (prebuffer.body) {
            PrebufferBody.content_length_end => |end| item.body_end = end,
            PrebufferBody.chunked_start => |start| item.chunked_body = ChunkedBody{ .start = start, .decoded_end = start },
        }
        self.readBody(slot);
    }

    fn readBody(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        item.state = Connection.State.reading_body;
        item.timeout = item.prefetch.body_deadline.?;
        self.advanceBody(slot);
    }

    /// Reads body bytes until the body is complete or the socket would
    /// block. The buffer grows as `growBody` says, up to the end of the body.
    fn advanceBody(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        if (item.chunked_body != null) return self.advanceChunkedBody(slot);
        while (item.length < item.body_end) {
            if (item.length == item.buffer.len and !self.growBody(item, item.body_end))
                return self.dispatchBody(slot, connection.BodyPrefetch.over_budget);
            const received = net.receiveAvailable(
                item.accepted.socket,
                item.buffer[item.length..@min(item.buffer.len, item.body_end)],
            ) catch return self.close(slot);
            const count = received orelse return;
            if (count == 0) return self.dispatchBody(slot, connection.BodyPrefetch.closed);
            item.length += count;
        }
        self.dispatchBody(slot, connection.BodyPrefetch.complete);
    }

    /// Reads and decodes a chunked body until its decoder sees the end. The
    /// Roc thread gets the decoded body, as if it had a Content-Length.
    fn advanceChunkedBody(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        const body = &item.chunked_body.?;
        while (true) {
            switch (decodeChunked(body, item.buffer, &item.length)) {
                ChunkedProgress.complete => {
                    item.prefetch.decoded_body_length = @intCast(body.decoder.decoded_length);
                    return self.dispatchBody(slot, connection.BodyPrefetch.complete);
                },
                ChunkedProgress.invalid => return self.dispatchBody(slot, connection.BodyPrefetch.invalid),
                ChunkedProgress.too_large => return self.dispatchBody(slot, connection.BodyPrefetch.too_large),
                ChunkedProgress.more => {},
            }
            // A larger body goes on in the handler's reads, from what
            // the loop decoded.
            if (body.decoded_end - body.start >= request_limits.maximum_prebuffered_body_bytes) {
                item.prefetch.predecoded = .{
                    .decoder = body.decoder,
                    .length = body.decoded_end - body.start,
                    .wire = body.wire,
                };
                return self.dispatchBody(slot, connection.BodyPrefetch.partial);
            }
            // The head and the decoded body so far fit within
            // `maximum_wire_bytes`, so the buffer fails to grow only for the
            // budget.
            if (item.length == item.buffer.len and !self.growBody(item, request_limits.maximum_wire_bytes))
                return self.dispatchBody(slot, connection.BodyPrefetch.over_budget);
            const received = net.receiveAvailable(
                item.accepted.socket,
                item.buffer[item.length..],
            ) catch return self.close(slot);
            const count = received orelse return;
            if (count == 0) return self.dispatchBody(slot, connection.BodyPrefetch.closed);
            item.length += count;
        }
    }

    /// Grows the buffer, up to `limit` and the loop's prebuffer budget, to
    /// twice its size or to hold every byte already received, whichever is
    /// larger. A body that has arrived is then copied once, not at each
    /// doubling. Only received bytes count: a length the head announces
    /// reserves nothing until the client sends it.
    /// False when it cannot grow; the caller hands the request over.
    fn growBody(self: *Loop, item: *Connection, limit: usize) bool {
        if (item.buffer.len >= limit) return false;
        const doubled = @max(initial_buffer_bytes, item.buffer.len * 2);
        const received = item.length +| (net.bytesAvailable(item.accepted.socket) orelse 0);
        const grown = @min(@max(doubled, received), limit);
        const added = grown - item.buffer.len;
        // Taken before the check, so threads that grow at once stay within
        // the budget.
        const budget = &self.handoff.prebuffer_bytes;
        if (budget.fetchAdd(added, std.builtin.AtomicOrder.monotonic) + added > maximum_prebuffer_bytes) {
            _ = budget.fetchSub(added, std.builtin.AtomicOrder.monotonic);
            return false;
        }
        item.buffer = raw_bytes.realloc(item.buffer, grown) catch {
            _ = budget.fetchSub(added, std.builtin.AtomicOrder.monotonic);
            return false;
        };
        item.prebuffer_reserved += added;
        return true;
    }

    /// The body buffer stays counted against the budget until the Roc
    /// thread hands the connection back, having replaced the buffer if the
    /// connection stays open (`Connection.store`).
    fn dispatchBody(self: *Loop, slot: u32, body: connection.BodyPrefetch) void {
        const item = &self.handoff.connections[slot];
        item.prefetch.body = body;
        item.chunked_body = null;
        self.dispatch(slot);
    }

    /// Stops counting a connection's body buffer against the budget.
    fn releasePrebuffer(self: *Loop, item: *Connection) void {
        _ = self.handoff.prebuffer_bytes.fetchSub(item.prebuffer_reserved, std.builtin.AtomicOrder.monotonic);
        item.prebuffer_reserved = 0;
    }

    /// Writes the process's gauges for the metrics (the sum of
    /// its threads).
    fn publishGauges(self: *Loop) void {
        const gauges = metrics.gauges() orelse return;
        const order = std.builtin.AtomicOrder.monotonic;
        gauges.queued_requests.store(self.handoff.queuedJobs(), order);
        gauges.requests_in_progress.store(self.handoff.in_progress.load(order), order);
        gauges.connections.store(self.handoff.openConnections(), order);
        gauges.request_memory_bytes.store(request_memory.current(), order);
        gauges.streams.store(self.handoff.active_streams.load(order), order);
    }

    /// Runs on the acceptor's periodic timer: expires connections whose
    /// timeout has passed, answers 503 to requests queued too long, acts on
    /// connections while every Roc thread is busy, and retries an accept
    /// paused by exhaustion or failure (a paused listener raises no new
    /// edge-triggered event).
    fn tick(self: *Loop) void {
        self.publishGauges();
        for (self.handoff.connections, 0..) |*item, index| {
            if (!item.open.load(std.builtin.AtomicOrder.acquire)) continue;
            // A connection a thread is acting on now is looked at next tick.
            if (!item.lock.tryLock()) continue;
            defer item.lock.unlock();
            self.expireIfDue(@intCast(index));
        }
        if (self.draining and self.drain_deadline.hasPassedAt(self.now)) self.cutDrain("the drain timeout passed");
        self.rejectExpiredQueue();
        self.standIn();
        // An overload past its grace is taken here and answered 503.
        if (self.accept_paused and (self.handoff.hasFreeSlot() or self.listenerHasPending())) {
            self.setAcceptPaused(false);
            self.acceptPending();
        }
    }

    /// Called with the connection's lock held.
    fn expireIfDue(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        if (item.http2) |protocol| {
            protocol.expire(self.now);
            if (protocol.owner.runnable) self.advanceHttp2(slot);
            if (item.http2 == null) return;
            if (!protocol.busy() and protocol.owner.engine.activeStreams() == 0 and protocol.owner.engine.pending.len == 0 and item.timeout.hasPassedAt(self.now)) self.close(slot);
            return;
        }
        switch (item.state) {
            Connection.State.reading,
            Connection.State.reading_body,
            Connection.State.writing,
            Connection.State.lingering,
            => {},
            Connection.State.free, Connection.State.dispatched => return,
        }
        if (!item.timeout.hasPassedAt(self.now)) return;
        // A body that did not arrive in time: the Roc thread answers 408.
        if (item.state == Connection.State.reading_body) return self.dispatchBody(slot, connection.BodyPrefetch.timed_out);
        // A response write that outlives its deadline closes the connection,
        // as the blocking writer did; so does a client that neither closes
        // nor stops sending while the loop lingers.
        if (item.state != Connection.State.reading) return self.close(slot);
        self.expire(slot);
    }

    /// While every Roc thread is busy (none idle, none has looked at the
    /// process's poller for a tick), the acceptor looks at it in their place
    ///: it reads heads and answers the 503s of a full queue, and
    /// queues the waiting fibers whose wait ended for the first thread free.
    /// It never runs Roc code.
    fn standIn(self: *Loop) void {
        const handoff = self.handoff;
        if (handoff.work.idle_threads.load(std.builtin.AtomicOrder.acquire) != 0) return;
        if (self.now -| handoff.last_poll_at.load(std.builtin.AtomicOrder.acquire) < tick_milliseconds * std.time.ns_per_ms) return;
        var raw: [event_batch]poller_backend.RawEvent = undefined;
        var events: [event_batch * poller_backend.events_per_raw]poller_backend.Event = undefined;
        const batch = self.poller.wait(&raw, &events, 0) catch return;
        var took_wake = false;
        for (batch) |event| {
            if (event.kind == poller_backend.Event.Kind.wake) {
                took_wake = true;
                continue;
            }
            if (scheduler.isFiberToken(event.token)) {
                const waits = handoff.waits orelse continue;
                const resumed = waits.onEvent(event.token, self.now) catch diagnostics.fatal("out of memory resuming a fiber");
                if (resumed) |target| handoff.work.push(.{ .resumed = target }) catch diagnostics.fatal("out of memory queueing a fiber");
                continue;
            }
            self.onEvent(event);
        }
        const waits = handoff.waits orelse return;
        var ready: std.ArrayList(*fiber.Fiber) = .empty;
        defer ready.deinit(std.heap.smp_allocator);
        waits.collectExpired(self.now, &ready) catch diagnostics.fatal("out of memory resuming a fiber");
        // A wake meant for the thread blocked on the poller (`passOnWake`).
        if (took_wake) waits.passOnWake();
        for (ready.items) |target| handoff.work.push(.{ .resumed = target }) catch diagnostics.fatal("out of memory queueing a fiber");
    }

    /// Answers 503 to requests that waited in the queue longer than the
    /// queue timeout, even while the Roc thread is busy with a long
    /// computation.
    fn rejectExpiredQueue(self: *Loop) void {
        const timeout = self.limits.queue_timeout_milliseconds * std.time.ns_per_ms;
        if (self.now <= timeout) return;
        self.expired.clearRetainingCapacity();
        self.handoff.takeExpired(self.now - timeout, &self.expired) catch diagnostics.fatal("out of memory rejecting expired requests");
        for (self.expired.items) |request| {
            const slot = request.slot;
            if (slot >= self.handoff.connections.len) continue;
            const item = &self.handoff.connections[slot];
            item.lock.lock();
            defer item.lock.unlock();
            if (request.http2 != null) {
                self.finishHttp2Locked(request, access_log.Outcome.queue_timeout);
                continue;
            }
            if (!item.matchesRequest(request) or item.dispatch_claimed) continue;
            self.reject(slot, access_log.Outcome.queue_timeout, request.queued_at);
        }
    }

    /// The supervisor asks for a drain on the first SIGTERM or SIGINT it
    /// gets, and for a stop on the next one.
    fn onDrainSignal(self: *Loop) void {
        const requests = drain_signal.consume();
        if (requests.stop) self.cutDrain("a second termination signal arrived");
        if (requests.drain and !self.draining) self.startDrain();
    }

    /// Stops accepting (the listener is the supervisor's, shared with the
    /// other workers, so this worker only stops watching it and closes its
    /// descriptor), closes keep-alive connections waiting for a request,
    /// ends the bodies that may end on a drain, and lets everything
    /// else finish.
    fn startDrain(self: *Loop) void {
        self.draining = true;
        self.handoff.draining.store(true, std.builtin.AtomicOrder.release);
        self.drain_deadline = self.after(self.limits.drain_timeout_milliseconds);
        if (self.acceptor_poller) |own| own.unwatchReadable(self.listener) catch {};
        net.closeSocket(self.listener);
        self.listener = -1;
        for (self.handoff.connections, 0..) |*item, index| {
            if (!item.open.load(std.builtin.AtomicOrder.acquire)) continue;
            item.lock.lock();
            defer item.lock.unlock();
            if (item.http2) |protocol| {
                protocol.draining = true;
                protocol.owner.engine.beginDrain() catch {
                    self.close(@intCast(index));
                    continue;
                };
                protocol.owner.runnable = true;
                self.advanceHttp2(@intCast(index));
            } else if (isIdle(item)) {
                self.close(@intCast(index));
            } else {
                drainStream(item);
            }
        }
    }

    /// Every connection has finished: the drain is complete.
    fn finishDrainWhenEmpty(self: *Loop) void {
        if (!self.draining or self.handoff.openConnections() != 0) return;
        // Queued access log lines are written within the drain timeout.
        access_log.finish(self.drain_deadline.expires_at_nanoseconds, monotonicReading);
        std.c._exit(0);
    }

    /// Ends the drain with connections still open: exit 1, after saying how
    /// many were cut (D10).
    fn cutDrain(self: *Loop, reason: []const u8) noreturn {
        var buffer: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "stopping: {s}; {d} connections were cut", .{
            reason,
            self.handoff.openConnections(),
        }) catch "stopping with connections cut";
        diagnostics.warning(message);
        std.c._exit(1);
    }

    fn expire(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        // No bytes: an idle connection closes silently. Partial head: the
        // Roc thread sees the expired deadline and answers 408.
        if (item.length == 0) return self.close(slot);
        self.dispatch(slot);
    }

    fn dispatch(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        // A full queue answers at once rather than making the request wait
        // for its timeout.
        if (self.handoff.queuedJobs() >= self.limits.maximum_queued_requests) return self.reject(slot, access_log.Outcome.queue_full, self.now);
        item.resetHead();
        const request = item.dispatchRequest(slot, self.now) orelse return self.close(slot);
        self.queue(.{ .request = request });
    }

    /// Queues a job: on a Roc thread, at the end of its own queue; on the
    /// acceptor, for any thread, waking one that is idle.
    fn queue(self: *Loop, job: work_queue.Job) void {
        const work = &self.handoff.work;
        const queued = if (self.thread_index) |index| work.pushOwn(index, job) else work.push(job);
        queued catch diagnostics.fatal("out of memory queueing a job");
    }

    fn close(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        if (item.http2) |protocol| {
            protocol.disconnect();
            if (protocol.busy()) return;
            protocol.destroy();
            item.http2 = null;
            return self.free(slot);
        }
        // Closing the socket also removes its registration: accepted sockets
        // are never shared with another process, which epoll requires.
        net.closeSocket(item.accepted.socket);
        self.free(slot);
    }

    fn free(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        self.releasePrebuffer(item);
        item.release();
        item.watching_writable = false;
        item.state = Connection.State.free;
        item.open.store(false, std.builtin.AtomicOrder.release);
        self.handoff.giveSlot(slot);
    }

    fn resumeConnection(self: *Loop, completion: Completion) void {
        const slot = completion.request.slot;
        const item = &self.handoff.connections[slot];
        std.debug.assert(item.state == Connection.State.dispatched);
        // A fiber waiting on this socket replaces the loop's registration
        // with a one-shot watch (or removes it on timeout). Restore before
        // writing deferred output, lingering, or reading the next request.
        if (item.read_watch_replaced) {
            item.read_exhausted = false;
            self.poller.restoreReadable(item.accepted.socket, token(slot, item.generation)) catch return self.close(slot);
            item.read_watch_replaced = false;
        }
        item.close_after_output = completion.action == Completion.Action.close or self.drainingNow();
        // The Roc thread replaced a body buffer (`Connection.store`).
        self.releasePrebuffer(item);
        if (item.output_length > 0) {
            // The Roc thread set `timeout` to the response write deadline.
            item.state = Connection.State.writing;
            return self.flush(slot);
        }
        if (item.close_after_output) return self.startLinger(slot);
        self.resumeReading(slot);
    }

    /// Writes stored output until the socket would block, then waits for a
    /// writable event. A finished write resumes reading or closes.
    fn flush(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        while (item.output_sent < item.output_length) {
            const sent = net.sendAvailable(
                item.accepted.socket,
                item.output[item.output_sent..item.output_length],
            ) catch return self.close(slot);
            if (sent == 0) {
                if (!item.watching_writable) {
                    self.poller.watchWritable(
                        item.accepted.socket,
                        token(slot, item.generation),
                    ) catch return self.close(slot);
                    item.watching_writable = true;
                }
                return;
            }
            item.output_sent += sent;
        }

        if (item.watching_writable) {
            self.poller.unwatchWritable(
                item.accepted.socket,
                token(slot, item.generation),
            ) catch return self.close(slot);
            item.watching_writable = false;
        }
        item.releaseOutput();
        item.recordAccess(true);
        if (item.close_after_output) return self.startLinger(slot);
        self.resumeReading(slot);
    }

    /// Ends the response with FIN, then discards what the client still sends
    /// until it closes, the byte budget runs out, or the linger deadline
    /// passes. Closing with unread bytes would make the kernel send a reset,
    /// which can destroy the response before the client reads it.
    fn startLinger(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        item.release();
        if (!net.shutdownWrite(item.accepted.socket)) return self.close(slot);
        item.state = Connection.State.lingering;
        item.timeout = self.after(linger_milliseconds);
        item.linger_remaining = linger_maximum_bytes;
        // Bytes that arrived while the Roc thread owned the socket raised no
        // event the loop acted on, so read them now.
        self.drainLinger(slot);
    }

    fn drainLinger(self: *Loop, slot: u32) void {
        const item = &self.handoff.connections[slot];
        switch (lingerStep(item.accepted.socket, &self.scratch, &item.linger_remaining)) {
            LingerStep.would_block => {},
            LingerStep.finished => self.close(slot),
        }
    }

    fn resumeReading(self: *Loop, slot: u32) void {
        // A response that left before the drain began keeps its connection
        // until here; no next request is read.
        if (self.drainingNow()) return self.startLinger(slot);
        const item = &self.handoff.connections[slot];
        item.state = Connection.State.reading;
        item.prefetch = .{};
        if (item.length > 0) {
            // Pipelined bytes start a fresh head limit, as the blocking reader did.
            self.startHead(slot);
        } else {
            item.shrinkIdle();
            item.timeout = self.after(self.limits.keep_alive_idle_timeout_milliseconds);
        }
        if (item.length == 0 and item.read_exhausted) return;
        self.advance(slot);
    }
};

fn headReadExhausted(count: usize, capacity: usize) bool {
    return builtin.os.tag == std.Target.Os.Tag.linux and count < capacity;
}

test "released connection does not retain an exhausted socket observation" {
    var item = Connection{};
    item.read_exhausted = true;
    item.release();
    try std.testing.expect(!item.read_exhausted);
}

test "head read exhaustion at the receive capacity boundary" {
    // A positive read may be below or exactly at capacity, never above it.
    for ([_]usize{ initial_buffer_bytes - 1, initial_buffer_bytes }) |count| {
        try std.testing.expectEqual(builtin.os.tag == std.Target.Os.Tag.linux and count < initial_buffer_bytes, headReadExhausted(count, initial_buffer_bytes));
    }
}

test "idle read exhaustion preserves notifications pipeline fragments and EOF" {
    const Arrival = enum { before_completion, after_completion, buffered, fragmented, eof, replaced_watch };
    for ([_]Arrival{ Arrival.before_completion, Arrival.after_completion, Arrival.buffered, Arrival.fragmented, Arrival.eof, Arrival.replaced_watch }) |arrival| {
        var pair: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
        defer net.closeSocket(pair[1]);
        try net.setListenerNonBlocking(pair[0]);
        var poller = try poller_backend.Poller.init();
        defer poller.deinit();
        var handoff = try Handoff.init(1);
        defer std.heap.page_allocator.free(handoff.connections);
        defer std.heap.page_allocator.free(handoff.free_slots);
        defer handoff.work.injector.deinit();
        handoff.poller = &poller;
        var loop = Loop.init(&handoff);
        loop.readClock();
        loop.open(.{ .socket = pair[0], .remote_address = .{ .v4 = .{ 127, 0, 0, 1 } }, .remote_port = 1 });
        const item = &handoff.connections[0];
        defer if (item.open.load(std.builtin.AtomicOrder.acquire)) loop.close(0);
        item.state = Connection.State.dispatched;
        // Exercise the Linux exhaustion state on every host running the tests.
        item.read_exhausted = true;
        const head = "GET /next HTTP/1.1\r\nHost: x\r\n\r\n";
        const event = poller_backend.Event{ .kind = poller_backend.Event.Kind.readable, .token = Loop.token(0, item.generation), .hangup = arrival == Arrival.eof };
        if (arrival == Arrival.buffered) try item.store(head);
        if (arrival == Arrival.replaced_watch) {
            item.read_watch_replaced = true;
            try std.testing.expectEqual(@as(isize, head.len), std.c.send(pair[1], head, head.len, 0));
        }
        if (arrival == Arrival.before_completion) {
            try std.testing.expectEqual(@as(isize, head.len), std.c.send(pair[1], head, head.len, 0));
            loop.onEvent(event);
            try std.testing.expect(!item.read_exhausted);
        }
        if (arrival == Arrival.eof) {
            try std.testing.expectEqual(@as(c_int, 0), std.c.shutdown(pair[1], std.c.SHUT.WR));
            loop.onEvent(event);
        }
        loop.complete(.{ .request = handoff.connections[0].requestIdentity(0), .action = Completion.Action.reuse });
        if (arrival == Arrival.after_completion or arrival == Arrival.fragmented) {
            try std.testing.expectEqual(Connection.State.reading, item.state);
            try std.testing.expect(handoff.work.injector.pop() == null);
            const split = if (arrival == Arrival.fragmented) 9 else head.len;
            try std.testing.expectEqual(@as(isize, @intCast(split)), std.c.send(pair[1], head.ptr, split, 0));
            loop.onEvent(event);
            if (arrival == Arrival.fragmented) {
                try std.testing.expectEqual(Connection.State.reading, item.state);
                const rest = head[split..];
                try std.testing.expectEqual(@as(isize, @intCast(rest.len)), std.c.send(pair[1], rest.ptr, rest.len, 0));
                loop.onEvent(event);
            }
        }
        if (arrival == Arrival.eof) {
            try std.testing.expectEqual(Connection.State.free, item.state);
        } else {
            try std.testing.expectEqual(Connection.State.dispatched, item.state);
            try std.testing.expectEqual(@as(u32, 0), handoff.work.injector.pop().?.request.slot);
            try std.testing.expectEqualStrings(head, item.bytes());
        }
    }
}

test "connection store grows only when the pending bytes do not fit" {
    var item = Connection{};
    defer item.release();
    try item.store("abc");
    const first = item.buffer.ptr;
    try item.store("de");
    try std.testing.expectEqual(first, item.buffer.ptr);
    try std.testing.expectEqualStrings("de", item.bytes());
    try item.store("fghij");
    try std.testing.expectEqualStrings("fghij", item.bytes());
}

test "store replaces a buffer grown past the head limit" {
    for ([_]usize{ maximum_loop_buffer_bytes - 1, maximum_loop_buffer_bytes, maximum_loop_buffer_bytes + 1 }) |capacity| {
        for ([_][]const u8{ "", "GET / HTTP/1.1\r\n" }) |pending| {
            var item = Connection{};
            defer item.release();
            item.buffer = try raw_bytes.alloc(capacity);
            item.length = capacity;
            try item.store(pending);
            const kept = capacity <= maximum_loop_buffer_bytes;
            const expected_capacity: usize = if (kept) capacity else if (pending.len == 0) 0 else initial_buffer_bytes;
            try std.testing.expectEqual(expected_capacity, item.buffer.len);
            try std.testing.expectEqualStrings(pending, item.bytes());
        }
    }
}

test "an idle connection gives back a buffer grown past the initial size" {
    for ([_]usize{ initial_buffer_bytes - 1, initial_buffer_bytes, initial_buffer_bytes + 1 }) |capacity| {
        var item = Connection{};
        defer item.release();
        item.buffer = try raw_bytes.alloc(capacity);
        item.shrinkIdle();
        const kept = capacity <= initial_buffer_bytes;
        try std.testing.expectEqual(if (kept) capacity else 0, item.buffer.len);
    }
}

test "a paused accept resumes on the timer tick" {
    const listener = try net.listenIpv4(.{ 127, 0, 0, 1 }, 0);
    defer net.closeSocket(listener.socket);
    try net.setListenerNonBlocking(listener.socket);
    var poller = try poller_backend.Poller.init();
    defer poller.deinit();
    const handoff = try std.testing.allocator.create(Handoff);
    defer std.testing.allocator.destroy(handoff);
    handoff.* = try Handoff.init(2);
    handoff.poller = &poller;
    var loop = Loop.init(handoff);
    loop.listener = listener.socket;
    loop.setAcceptPaused(true);
    loop.readClock();

    const client = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(client >= 0);
    defer net.closeSocket(client);
    var address = std.c.sockaddr.in{
        .port = std.mem.nativeToBig(u16, listener.port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    try std.testing.expectEqual(@as(c_int, 0), std.c.connect(client, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)));

    // While paused, nothing is accepted; the tick resumes and accepts it.
    try std.testing.expectEqual(@as(usize, 0), handoff.openConnections());
    loop.tick();
    try std.testing.expect(!loop.accept_paused);
    try std.testing.expectEqual(@as(usize, 1), handoff.openConnections());
    const slot = handoff.free_slots[1];
    try std.testing.expectEqual(Connection.State.reading, handoff.connections[slot].state);
    loop.close(slot);

    // With no free slot, the tick leaves accept paused.
    loop.setAcceptPaused(true);
    handoff.free_count = 0;
    loop.tick();
    try std.testing.expect(loop.accept_paused);
}

fn waitReadable(socket: net.Socket) !void {
    var poll_fd = [_]std.c.pollfd{.{ .fd = socket, .events = std.c.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&poll_fd, 1, 1000));
}

test "a request expecting 100 Continue goes to the Roc thread before its body" {
    const listener = try net.listenIpv4(.{ 127, 0, 0, 1 }, 0);
    defer net.closeSocket(listener.socket);
    try net.setListenerNonBlocking(listener.socket);
    var poller = try poller_backend.Poller.init();
    defer poller.deinit();
    const handoff = try std.testing.allocator.create(Handoff);
    defer std.testing.allocator.destroy(handoff);
    handoff.* = try Handoff.init(1);
    handoff.poller = &poller;
    var loop = Loop.init(handoff);
    loop.listener = listener.socket;
    loop.readClock();

    const client = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(client >= 0);
    defer net.closeSocket(client);
    var address = std.c.sockaddr.in{
        .port = std.mem.nativeToBig(u16, listener.port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    try std.testing.expectEqual(@as(c_int, 0), std.c.connect(client, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)));
    try waitReadable(listener.socket);
    loop.acceptPending();
    const item = &handoff.connections[0];
    try std.testing.expectEqual(Connection.State.reading, item.state);

    // A body the loop would otherwise prebuffer: small Content-Length.
    const head = "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n";
    try std.testing.expectEqual(@as(isize, head.len), std.c.send(client, head, head.len, 0));
    try waitReadable(item.accepted.socket);
    loop.advance(0);

    // Dispatched on the head alone: no body read and no 100 Continue sent,
    // so the Roc thread decides first and its first body read sends 100.
    try std.testing.expectEqual(Connection.State.dispatched, item.state);
    try std.testing.expectEqual(connection.BodyPrefetch.not_read, item.prefetch.body);
    // A later body read can consume a readiness event; probe again on reuse.
    try std.testing.expect(!item.read_exhausted);
    try std.testing.expectEqual(@as(u32, 0), handoff.work.injector.pop().?.request.slot);
    var nothing: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, -1), std.c.recv(client, &nothing, nothing.len, std.c.MSG.DONTWAIT));
    item.state = Connection.State.reading;
    loop.close(0);
}

test "a head arriving one byte at a time is parsed once overall" {
    const head = "GET /items/42 HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n";
    var shared = http1.Parser{};
    var item = Connection{};
    defer item.release();
    item.buffer = try raw_bytes.alloc(head.len);
    for (head, 0..) |byte, index| {
        item.buffer[index] = byte;
        item.length = index + 1;
        const progress = item.feedHead(&shared);
        if (index + 1 < head.len) {
            try std.testing.expectEqual(HeadProgress.incomplete, progress);
            // The parser has seen exactly the bytes received so far.
            try std.testing.expectEqual(@as(u32, @intCast(index + 1)), item.head_parser.?.offset);
        } else {
            try std.testing.expectEqual(HeadProgress.ready, progress);
        }
    }
}

test "a head in one read and an early parse error need no parser of their own" {
    var shared = http1.Parser{};
    for ([_][]const u8{ "GET / HTTP/1.1\r\nHost: a\r\n\r\n", "\x01" }) |bytes| {
        var item = Connection{};
        defer item.release();
        try item.store(bytes);
        try std.testing.expectEqual(HeadProgress.ready, item.feedHead(&shared));
        try std.testing.expectEqual(@as(?*http1.Parser, null), item.head_parser);
    }
}

test "lingering discards up to its budget and stops at the client's close" {
    const Case = struct { sent: usize, close: bool, expected: LingerStep };
    const budget: usize = 64;
    for ([_]Case{
        .{ .sent = budget - 1, .close = true, .expected = LingerStep.finished },
        .{ .sent = budget, .close = true, .expected = LingerStep.finished },
        .{ .sent = budget - 1, .close = false, .expected = LingerStep.would_block },
        .{ .sent = budget, .close = false, .expected = LingerStep.finished },
        .{ .sent = budget + 1, .close = false, .expected = LingerStep.finished },
        .{ .sent = 0, .close = false, .expected = LingerStep.would_block },
    }) |case| {
        var pair: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
        defer net.closeSocket(pair[0]);
        var peer_open = true;
        defer if (peer_open) net.closeSocket(pair[1]);
        const flags = std.c.fcntl(pair[0], std.c.F.GETFL);
        _ = std.c.fcntl(pair[0], std.c.F.SETFL, flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));

        var bytes: [budget + 1]u8 = undefined;
        @memset(&bytes, 'x');
        if (case.sent > 0) try std.testing.expectEqual(@as(isize, @intCast(case.sent)), std.c.write(pair[1], &bytes, case.sent));
        if (case.close) {
            net.closeSocket(pair[1]);
            peer_open = false;
        }
        var scratch: [16]u8 = undefined;
        var remaining = budget;
        try std.testing.expectEqual(case.expected, lingerStep(pair[0], &scratch, &remaining));
        try std.testing.expectEqual(budget -| case.sent, remaining);
    }
}

fn planFor(head: []const u8) BodyPlan {
    var parser = http1.Parser{};
    _ = parser.feed(head);
    return bodyPlan(&parser, head);
}

test "the loop waits only for a Content-Length body within the limit" {
    const limit = request_limits.maximum_prebuffered_body_bytes;
    const Case = struct { length: usize, prebuffer: bool };
    for ([_]Case{
        .{ .length = 0, .prebuffer = false },
        .{ .length = 1, .prebuffer = true },
        .{ .length = limit - 1, .prebuffer = true },
        .{ .length = limit, .prebuffer = true },
        .{ .length = limit + 1, .prebuffer = false },
    }) |case| {
        var buffer: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(&buffer, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n", .{case.length});
        switch (planFor(head)) {
            BodyPlan.dispatch_now => try std.testing.expect(!case.prebuffer),
            BodyPlan.prebuffer => |prebuffer| {
                try std.testing.expect(case.prebuffer);
                const end = prebuffer.body.content_length_end;
                try std.testing.expectEqual(head.len + case.length, end);
                try std.testing.expect(end <= request_limits.maximum_wire_bytes);
            },
        }
    }
}

test "the loop prebuffers only bodies it may receive without asking the Roc thread" {
    const Case = struct { head: []const u8, prebuffer: bool };
    for ([_]Case{
        .{ .head = "GET / HTTP/1.1\r\nHost: x\r\n\r\n", .prebuffer = false },
        .{ .head = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n", .prebuffer = true },
        .{ .head = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\n", .prebuffer = true },
        // A client waiting for 100 Continue sends no body until the Roc
        // thread's pre-body layers accept the request.
        .{ .head = "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nTransfer-Encoding: chunked\r\n\r\n", .prebuffer = false },
        .{ .head = "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n", .prebuffer = false },
        .{ .head = "POST /a/../b HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n", .prebuffer = false },
        .{ .head = "POST / HTTP/1.1\r\nHost: x\r\nExpect: custom\r\nContent-Length: 1\r\n\r\n", .prebuffer = false },
        // HTTP/1.0 has no 100 Continue: the body follows, so it is prebuffered.
        .{ .head = "POST / HTTP/1.0\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n", .prebuffer = true },
        .{ .head = "\x01", .prebuffer = false },
    }) |case| {
        const prebuffered = switch (planFor(case.head)) {
            BodyPlan.dispatch_now => false,
            BodyPlan.prebuffer => true,
        };
        try std.testing.expectEqual(case.prebuffer, prebuffered);
    }
}

test "an over-long target is left to the Roc thread's 414" {
    const target_limit = request_limits.maximum_request_target_bytes;
    for ([_]usize{ target_limit, target_limit + 1 }) |target_length| {
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(std.testing.allocator);
        try head.appendSlice(std.testing.allocator, "POST /");
        try head.appendNTimes(std.testing.allocator, 'a', target_length - 1);
        try head.appendSlice(std.testing.allocator, " HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\n");
        const prebuffered = switch (planFor(head.items)) {
            BodyPlan.dispatch_now => false,
            BodyPlan.prebuffer => true,
        };
        try std.testing.expectEqual(target_length <= target_limit, prebuffered);
    }
}

/// Runs `decodeChunked` over `wire`, appended after `head` `step` bytes at a
/// time as reads would deliver it, and returns the last progress.
fn decodeInSteps(buffer: []u8, head: []const u8, wire: []const u8, step: usize) struct { progress: ChunkedProgress, length: usize } {
    @memcpy(buffer[0..head.len], head);
    var body = ChunkedBody{ .start = head.len, .decoded_end = head.len };
    var length = head.len;
    var offset: usize = 0;
    while (true) {
        const count = @min(step, wire.len - offset);
        @memcpy(buffer[length..][0..count], wire[offset..][0..count]);
        length += count;
        offset += count;
        const progress = decodeChunked(&body, buffer, &length);
        if (progress != ChunkedProgress.more or offset == wire.len) return .{ .progress = progress, .length = length };
    }
}

test "the loop decodes a chunked body in place however it is split" {
    const head = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
    const body = "3\r\nabc\r\n2;ext=1\r\nde\r\n0\r\nx-trailer: 1\r\n\r\n";
    const next = "GET /next HTTP/1.1\r\n";
    const expected = head ++ "abcde" ++ next;
    var buffer: [256]u8 = undefined;
    // Whole, one byte at a time, and in between: the head and the decoded
    // body end up in the same place, followed by whatever of the pipelined
    // bytes arrived with the end of the body.
    for ([_]usize{ body.len + next.len, 1, 2, 7 }) |step| {
        const result = decodeInSteps(&buffer, head, body ++ next, step);
        try std.testing.expectEqual(ChunkedProgress.complete, result.progress);
        const decoded = head.len + "abcde".len;
        try std.testing.expectEqualStrings(expected[0..decoded], buffer[0..decoded]);
        const arrived = (body.len + step - 1) / step * step - body.len;
        try std.testing.expectEqualStrings(next[0..@min(arrived, next.len)], buffer[decoded..result.length]);
    }
    // Before the end, only the head and the decoded bytes remain.
    const partial = decodeInSteps(&buffer, head, body[0..12], 1);
    try std.testing.expectEqual(ChunkedProgress.more, partial.progress);
    try std.testing.expectEqualStrings(head ++ "abc", buffer[0..partial.length]);
}

test "invalid framing and framing out of proportion to the data are answered" {
    var small: [16]u8 = undefined;
    try std.testing.expectEqual(ChunkedProgress.invalid, decodeInSteps(&small, "", "z\r\n", 3).progress);

    const allocator = std.testing.allocator;
    const buffer = try allocator.alloc(u8, request_limits.framing_allowance_bytes + 64);
    defer allocator.free(buffer);
    var wire: std.Io.Writer.Allocating = .init(allocator);
    defer wire.deinit();

    // A body larger than the loop receives decodes: the handler's reads
    // apply its limits.
    const limit = request_limits.maximum_prebuffered_body_bytes;
    for ([_]usize{ limit - 1, limit, limit + 1 }) |size| {
        wire.clearRetainingCapacity();
        try wire.writer.print("{x}\r\n", .{size});
        try wire.writer.splatByteAll('a', size);
        try wire.writer.writeAll("\r\n0\r\n\r\n");
        try std.testing.expectEqual(ChunkedProgress.complete, decodeInSteps(buffer, "", wire.written(), 4096).progress);
    }

    // One byte of data behind a chunk extension that pads the framing,
    // within the allowance and past it.
    const allowance = request_limits.framing_allowance_bytes;
    for ([_]struct { size: usize, expected: ChunkedProgress }{
        .{ .size = allowance - 64, .expected = ChunkedProgress.complete },
        .{ .size = allowance + 64, .expected = ChunkedProgress.too_large },
    }) |case| {
        wire.clearRetainingCapacity();
        try wire.writer.writeAll("1;x=");
        try wire.writer.splatByteAll('p', case.size - "1;x=\r\nX\r\n0\r\n\r\n".len);
        try wire.writer.writeAll("\r\nX\r\n0\r\n\r\n");
        // In small reads the buffer only ever holds what one read brings.
        try std.testing.expectEqual(case.expected, decodeInSteps(buffer, "", wire.written(), 1000).progress);
    }
}

test "requests past the queue timeout leave every queue" {
    var handoff = try Handoff.init(default_maximum_connections);
    defer {
        std.heap.page_allocator.free(handoff.connections);
        std.heap.page_allocator.free(handoff.free_slots);
        handoff.work.injector.deinit();
    }
    for ([_]u32{ 4, 2, 7 }, [_]u64{ 10, 20, 30 }) |slot, at| {
        handoff.connections[slot].dispatched_at = at;
        handoff.dispatch(slot);
    }
    var expired: std.ArrayList(work_queue.Request) = .empty;
    defer expired.deinit(std.heap.smp_allocator);
    try handoff.takeExpired(10, &expired);
    try std.testing.expectEqual(@as(usize, 0), expired.items.len);
    try handoff.takeExpired(21, &expired);
    try std.testing.expectEqualSlices(work_queue.Request, &.{ handoff.connections[4].requestIdentity(4), handoff.connections[2].requestIdentity(2) }, expired.items);
    try std.testing.expectEqual(@as(usize, 1), handoff.queuedJobs());
    try handoff.takeExpired(std.math.maxInt(u64), &expired);
    try std.testing.expectEqualSlices(work_queue.Request, &.{ handoff.connections[4].requestIdentity(4), handoff.connections[2].requestIdentity(2), handoff.connections[7].requestIdentity(7) }, expired.items);
    try std.testing.expectEqual(@as(usize, 0), handoff.queuedJobs());
}

test "TCP keep-alive consumes kernel readiness before and after completion" {
    if (builtin.os.tag != std.Target.Os.Tag.linux) return error.SkipZigTest;
    const Arrival = enum { before_completion, after_completion, fragmented, while_writing };
    for ([_]Arrival{ Arrival.before_completion, Arrival.after_completion, Arrival.fragmented, Arrival.while_writing }) |arrival| {
        const listener = try net.listenIpv4(.{ 127, 0, 0, 1 }, 0);
        defer net.closeSocket(listener.socket);
        try net.setListenerNonBlocking(listener.socket);
        var poller = try poller_backend.Poller.init();
        defer poller.deinit();
        var handoff = try Handoff.init(1);
        defer std.heap.page_allocator.free(handoff.connections);
        defer std.heap.page_allocator.free(handoff.free_slots);
        defer handoff.work.injector.deinit();
        handoff.poller = &poller;
        var loop = Loop.init(&handoff);
        loop.listener = listener.socket;
        loop.readClock();
        const client = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        try std.testing.expect(client >= 0);
        defer net.closeSocket(client);
        var address = std.c.sockaddr.in{
            .port = std.mem.nativeToBig(u16, listener.port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001),
        };
        try std.testing.expectEqual(@as(c_int, 0), std.c.connect(client, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)));
        try waitReadable(listener.socket);
        loop.acceptPending();
        const item = &handoff.connections[0];
        defer if (item.open.load(std.builtin.AtomicOrder.acquire)) loop.close(0);
        const head = "GET /next HTTP/1.1\r\nHost: x\r\n\r\n";
        const Receive = struct {
            fn events(target: *Loop) !void {
                var raw: [4]poller_backend.RawEvent = undefined;
                var ready: [4 * poller_backend.events_per_raw]poller_backend.Event = undefined;
                const batch = try target.poller.wait(&raw, &ready, 1000);
                try std.testing.expect(batch.len > 0);
                for (batch) |event| target.onEvent(event);
            }
        };
        try std.testing.expectEqual(@as(isize, head.len), std.c.send(client, head, head.len, 0));
        try Receive.events(&loop);
        // Reuse a connection repeatedly; no fabricated readability or exhaustion state.
        for (0..32) |_| {
            try std.testing.expectEqual(Connection.State.dispatched, item.state);
            try std.testing.expectEqual(@as(u32, 0), handoff.work.injector.pop().?.request.slot);
            try std.testing.expectEqualStrings(head, item.bytes());
            try std.testing.expect(item.read_exhausted);
            item.dropParsedHead();
            item.length = 0;
            if (arrival == Arrival.before_completion or arrival == Arrival.while_writing) {
                if (arrival == Arrival.while_writing) item.state = Connection.State.writing;
                try std.testing.expectEqual(@as(isize, head.len), std.c.send(client, head, head.len, 0));
                try Receive.events(&loop);
                try std.testing.expect(!item.read_exhausted);
            }
            if (arrival == Arrival.while_writing) {
                loop.flush(0);
            } else {
                loop.complete(.{ .request = handoff.connections[0].requestIdentity(0), .action = Completion.Action.reuse });
            }
            if (arrival == Arrival.after_completion or arrival == Arrival.fragmented) {
                try std.testing.expectEqual(Connection.State.reading, item.state);
                const split = if (arrival == Arrival.fragmented) 9 else head.len;
                try std.testing.expectEqual(@as(isize, @intCast(split)), std.c.send(client, head.ptr, split, 0));
                try Receive.events(&loop);
                if (arrival == Arrival.fragmented) {
                    try std.testing.expectEqual(Connection.State.reading, item.state);
                    const rest = head[split..];
                    try std.testing.expectEqual(@as(isize, @intCast(rest.len)), std.c.send(client, rest.ptr, rest.len, 0));
                    try Receive.events(&loop);
                }
            }
        }
        try std.testing.expectEqual(@as(u32, 0), handoff.work.injector.pop().?.request.slot);
        item.dropParsedHead();
        item.length = 0;
        loop.complete(.{ .request = handoff.connections[0].requestIdentity(0), .action = Completion.Action.reuse });
        try std.testing.expectEqual(@as(c_int, 0), std.c.shutdown(client, std.c.SHUT.WR));
        try Receive.events(&loop);
        try std.testing.expectEqual(Connection.State.free, item.state);
    }
}

test "a body buffer grows to hold the bytes already received, within its limit" {
    // A full 4096-byte buffer doubles to 8192 unless more has arrived: with
    // 4095, 4096 or 4097 bytes waiting it holds 8191, 8192 (both doubling)
    // or 8193. The limit caps the growth either way. Every amount fits a
    // UNIX socket's default buffer (8 KiB on macOS), so the sends here do
    // not wait for a reader.
    const Case = struct { waiting: usize, limit: usize, expected: usize };
    for ([_]Case{
        .{ .waiting = 0, .limit = 1 << 20, .expected = 8192 },
        .{ .waiting = 4095, .limit = 1 << 20, .expected = 8192 },
        .{ .waiting = 4096, .limit = 1 << 20, .expected = 8192 },
        .{ .waiting = 4097, .limit = 1 << 20, .expected = 8193 },
        .{ .waiting = 6000, .limit = 1 << 20, .expected = 10_096 },
        .{ .waiting = 6000, .limit = 9000, .expected = 9000 },
    }) |case| {
        var pair: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
        defer net.closeSocket(pair[0]);
        defer net.closeSocket(pair[1]);
        const sent = try std.testing.allocator.alloc(u8, case.waiting);
        defer std.testing.allocator.free(sent);
        @memset(sent, 'x');
        var offset: usize = 0;
        while (offset < sent.len) {
            const count = std.c.send(pair[1], sent[offset..].ptr, sent.len - offset, 0);
            try std.testing.expect(count > 0);
            offset += @intCast(count);
        }

        var handoff = try Handoff.init(1);
        defer std.heap.page_allocator.free(handoff.connections);
        defer std.heap.page_allocator.free(handoff.free_slots);
        defer handoff.work.injector.deinit();
        var poller = try poller_backend.Poller.init();
        defer poller.deinit();
        handoff.poller = &poller;
        var loop = Loop.init(&handoff);
        var item = Connection{};
        defer item.release();
        item.accepted = .{ .socket = pair[0], .remote_address = .{ .v4 = .{ 127, 0, 0, 1 } }, .remote_port = 1 };
        item.buffer = try raw_bytes.alloc(initial_buffer_bytes);
        item.length = item.buffer.len;

        try std.testing.expect(loop.growBody(&item, case.limit));
        try std.testing.expectEqual(case.expected, item.buffer.len);
        loop.releasePrebuffer(&item);
    }
}

test "dispatch identities reject old requests and reused connection slots" {
    var handoff = try Handoff.init(1);
    defer std.heap.page_allocator.free(handoff.connections);
    defer std.heap.page_allocator.free(handoff.free_slots);
    const item = &handoff.connections[0];
    item.generation = 1;
    const first = item.dispatchRequest(0, 10).?;
    try std.testing.expect(handoff.claimRequest(first));
    try std.testing.expect(!handoff.claimRequest(first));
    const next = item.dispatchRequest(0, 11).?;
    try std.testing.expect(!handoff.claimRequest(first));
    var wrong_connection = next;
    wrong_connection.generation = 0;
    try std.testing.expect(!handoff.claimRequest(wrong_connection));
    var out_of_range = next;
    out_of_range.slot = 1;
    try std.testing.expect(!handoff.claimRequest(out_of_range));
    try std.testing.expect(handoff.claimRequest(next));
    item.state = Connection.State.free;
    try std.testing.expect(!handoff.claimRequest(next));
    item.generation = 2;
    const reused = item.dispatchRequest(0, 12).?;
    try std.testing.expect(!handoff.claimRequest(next));
    try std.testing.expect(handoff.claimRequest(reused));
}

test "concurrent consumers claim a dispatched request exactly once" {
    var handoff = try Handoff.init(1);
    defer std.heap.page_allocator.free(handoff.connections);
    defer std.heap.page_allocator.free(handoff.free_slots);
    const request = handoff.connections[0].dispatchRequest(0, 0).?;
    var claimed = std.atomic.Value(u32).init(0);
    const Consumer = struct {
        fn run(shared: *Handoff, job: work_queue.Request, count: *std.atomic.Value(u32)) void {
            if (shared.claimRequest(job)) _ = count.fetchAdd(1, std.builtin.AtomicOrder.monotonic);
        }
    };
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Consumer.run, .{ &handoff, request, &claimed });
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    try std.testing.expectEqual(@as(u32, 1), claimed.load(std.builtin.AtomicOrder.monotonic));
}

test "stale completion failure and queue expiry cannot change a newer request" {
    var handoff = try Handoff.init(1);
    defer std.heap.page_allocator.free(handoff.connections);
    defer std.heap.page_allocator.free(handoff.free_slots);
    defer handoff.work.injector.deinit();
    var poller = try poller_backend.Poller.init();
    defer poller.deinit();
    handoff.poller = &poller;
    var loop = Loop.init(&handoff);
    defer loop.expired.deinit(std.heap.smp_allocator);
    const item = &handoff.connections[0];
    const stale = item.dispatchRequest(0, 0).?;
    try handoff.work.push(.{ .request = stale });
    const current = item.dispatchRequest(0, 1).?;
    item.timeout = .{ .expires_at_nanoseconds = 123 };
    const deadline = net.Deadline{ .expires_at_nanoseconds = 456 };
    var entry = access_log.Entry{};
    loop.complete(.{ .request = stale, .action = Completion.Action.reuse });
    loop.complete(.{ .request = stale, .action = Completion.Action.close });
    loop.rejectTaken(stale, deadline, access_log.Outcome.queue_timeout, request_id.Source.generate);
    loop.fail(stale, deadline, &entry);
    loop.failWritten(stale, &entry, access_log.Outcome.crashed);
    loop.now = (loop.limits.queue_timeout_milliseconds + 1) * std.time.ns_per_ms;
    loop.rejectExpiredQueue();
    try std.testing.expectEqual(@as(usize, 0), handoff.queuedJobs());
    try std.testing.expect(item.matchesRequest(current));
    try std.testing.expectEqual(@as(u64, 123), item.timeout.expires_at_nanoseconds);
    try std.testing.expectEqual(@as(usize, 0), item.output.len);
    try std.testing.expect(!item.dispatch_claimed);
}

test "dispatch sequence exhaustion never wraps into an older identity" {
    var item = Connection{ .dispatch_sequence = std.math.maxInt(u64) - 2 };
    const below = item.dispatchRequest(0, 0).?;
    const boundary = item.dispatchRequest(0, 1).?;
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, below.sequence);
    try std.testing.expectEqual(std.math.maxInt(u64), boundary.sequence);
    try std.testing.expect(item.dispatchRequest(0, 2) == null);
    try std.testing.expect(item.matchesRequest(boundary));
    try std.testing.expect(!item.matchesRequest(below));
}

test "HTTP/2 admission rejections record one access entry and metric before Roc runs" {
    // Exercise both consumers together and metrics with access logging disabled.
    for ([_]bool{ true, false }) |logging| {
        for ([_]access_log.Outcome{ access_log.Outcome.queue_full, access_log.Outcome.queue_timeout, access_log.Outcome.in_progress_full }) |outcome| {
            const region = try metrics.testRegion();
            defer metrics.endTestRegion(region);
            var capture: access_log.TestCapture = .{};
            if (logging) capture.start();
            defer if (logging) capture.stop();
            var pair: [2]c_int = undefined;
            try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
            defer net.closeSocket(pair[1]);
            try net.setListenerNonBlocking(pair[0]);
            var poller = try poller_backend.Poller.init();
            defer poller.deinit();
            var handoff = try Handoff.init(1);
            defer std.heap.page_allocator.free(handoff.connections);
            defer std.heap.page_allocator.free(handoff.free_slots);
            defer handoff.work.injector.deinit();
            handoff.poller = &poller;
            handoff.work = try work_queue.Jobs.init(1, &poller);
            defer std.heap.smp_allocator.free(handoff.work.queues);
            defer handoff.work.queues[0].deinit();
            handoff.http2 = true;
            handoff.limits.maximum_queued_requests = 1;
            var loop = Loop.init(&handoff);
            defer loop.expired.deinit(std.heap.smp_allocator);
            loop.readClock();
            loop.open(.{ .socket = pair[0], .remote_address = .{ .v4 = .{ 127, 0, 0, 1 } }, .remote_port = 1 });
            defer loop.close(0);
            const protocol = handoff.connections[0].http2.?;
            const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00";
            try std.testing.expectEqual(@as(isize, preface.len), std.c.send(pair[1], preface, preface.len, 0));
            protocol.owner.runnable = true;
            loop.advanceHttp2(0);
            var previous_id: request_id.Id = .{};
            // A second stream also checks slot reuse and duplicate cleanup.
            for ([_]u8{ 1, 3 }, 0..) |stream_id, index| {
                if (outcome == access_log.Outcome.queue_full) {
                    try handoff.work.push(.{ .request = .{ .slot = 0, .generation = 0, .sequence = 0, .queued_at = loop.now } });
                }
                const block = "\x82\x86\x04\x13/overload?q=secret!\x01\x09localhost";
                var frame = [_]u8{ 0, 0, block.len, 1, 5, 0, 0, 0, stream_id } ++ block.*;
                try std.testing.expectEqual(@as(isize, frame.len), std.c.send(pair[1], &frame, frame.len, 0));
                protocol.owner.runnable = true;
                loop.advanceHttp2(0);
                if (outcome == access_log.Outcome.queue_full) {
                    _ = handoff.work.next(0).?;
                    try std.testing.expectEqual(@as(usize, 0), handoff.queuedJobs());
                } else {
                    try std.testing.expectEqual(@as(usize, 1), handoff.queuedJobs());
                    if (outcome == access_log.Outcome.queue_timeout) {
                        loop.now += (loop.limits.queue_timeout_milliseconds + 1) * std.time.ns_per_ms;
                        loop.rejectExpiredQueue();
                    } else {
                        const request = handoff.work.next(0).?.request;
                        try std.testing.expect(handoff.claimRequest(request));
                        loop.rejectTaken(request, .{ .expires_at_nanoseconds = 0 }, outcome, request_id.Source.generate);
                        // A stale completion must not record the same request twice.
                        loop.rejectTaken(request, .{ .expires_at_nanoseconds = 0 }, outcome, request_id.Source.generate);
                    }
                }
                loop.advanceHttp2(0);
                protocol.recordCompleted();
                protocol.recordCompleted();
                try std.testing.expect(!protocol.busy());
                try std.testing.expectEqual(@as(usize, 0), protocol.budget.used);
                if (logging) {
                    try std.testing.expectEqual(index + 1, capture.count());
                    const entry = capture.entry(index);
                    try std.testing.expectEqual(outcome, entry.outcome);
                    // A reset has no HTTP response status.
                    try std.testing.expectEqual(@as(u16, 0), entry.status);
                    try std.testing.expectEqualStrings("GET", entry.method.slice());
                    try std.testing.expectEqualStrings("/overload", entry.path.slice());
                    try std.testing.expect(entry.request_id.len > 0);
                    try std.testing.expect(!std.mem.eql(u8, previous_id.slice(), entry.request_id.slice()));
                    previous_id = entry.request_id;
                    var buffer: [2048]u8 = undefined;
                    const json = capture.json(index, &buffer);
                    try std.testing.expect(std.mem.indexOf(u8, json, "secret") == null);
                    try std.testing.expect(std.mem.indexOf(u8, json, @tagName(outcome)) != null);
                }
            }
            var buffer: [8192]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try metrics.render(&writer, 0);
            var expected: [256]u8 = undefined;
            const series = try std.fmt.bufPrint(&expected, "roxum_http_requests_total{{route=\"\",method=\"GET\",status=\"0\",outcome=\"{s}\"}} 2\n", .{@tagName(outcome)});
            try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), series) != null);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.buffered(), "roxum_http_requests_total{"));
        }
    }
}
