//! Name resolution for outbound connections. `getaddrinfo` blocks the thread
//! that calls it, so names are resolved on threads of their own and the
//! caller waits for a pipe with a deadline: on a request fiber only the
//! fiber waits (the same split as hyper's default resolver). A literal
//! address is converted on the spot.
const std = @import("std");
const sync = @import("sync.zig");
const tcp = @import("net/tcp.zig");

/// Threads that call `getaddrinfo`, started in a worker the first time a
/// name is resolved. A lookup cannot be cancelled; a server that does not
/// answer keeps one thread until the system gives up, and the others go on.
const thread_count = 2;
/// At most this many lookups wait behind the active resolver threads.
const maximum_pending = 256;
/// Addresses kept from one lookup, tried in the order the system gives.
pub const maximum_addresses = 8;

pub const Error = error{ ResolveFailed, ResolveTimeout, OutOfMemory };

pub const Address = struct {
    storage: std.c.sockaddr.storage,
    length: u32,

    pub fn sockaddr(self: *const Address) *const std.c.sockaddr {
        return @ptrCast(&self.storage);
    }
};

pub const Addresses = struct {
    items: [maximum_addresses]Address = undefined,
    count: usize = 0,

    pub fn slice(self: *const Addresses) []const Address {
        return self.items[0..self.count];
    }
};

const Request = struct {
    name: [256:0]u8 = undefined,
    port: u16,
    /// The thread writes one byte to `pipe[1]` when the result is ready.
    pipe: [2]c_int,
    result: Addresses = .{},
    failed: bool = false,
    // The caller and worker each own a reference. Publishing a result does
    // not end the worker's ownership: it still has to write the notification.
    references: std.atomic.Value(u8) = .init(2),
    completed: std.atomic.Value(bool) = .init(false),
    next: ?*Request = null,
    deadline: tcp.Deadline = .{ .expires_at_nanoseconds = std.math.maxInt(u64) },

    fn destroy(self: *Request) void {
        _ = std.c.close(self.pipe[0]);
        _ = std.c.close(self.pipe[1]);
        std.heap.smp_allocator.destroy(self);
    }

    fn release(self: *Request) void {
        if (self.references.fetchSub(1, std.builtin.AtomicOrder.acq_rel) == 1) self.destroy();
    }

    fn notifyAndRelease(self: *Request) void {
        defer self.release();
        const byte = [1]u8{1};
        _ = std.c.write(self.pipe[1], &byte, 1);
    }
};

const Queue = struct {
    mutex: sync.Mutex = .{},
    ready: sync.Condition = .{},
    head: ?*Request = null,
    tail: ?*Request = null,
    threads_started: usize = 0,
    count: usize = 0,

    fn push(self: *Queue, request: *Request) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count >= maximum_pending) return error.ResolveFailed;
        while (self.threads_started < thread_count) {
            // Remember each successful spawn even if a later spawn fails.
            const thread = std.Thread.spawn(.{}, work, .{self}) catch return error.ResolveFailed;
            thread.detach();
            self.threads_started += 1;
        }
        self.count += 1;
        if (self.tail) |tail| tail.next = request else self.head = request;
        self.tail = request;
        self.ready.signal();
    }

    /// Remove only jobs the worker has not taken. The caller still owns a
    /// reference, so racing completion cannot free the request underneath us.
    fn cancel(self: *Queue, target: *Request) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var previous: ?*Request = null;
        var current = self.head;
        while (current) |request| : (current = request.next) {
            if (request == target) {
                if (previous) |before| before.next = request.next else self.head = request.next;
                if (self.tail == request) self.tail = previous;
                self.count -= 1;
                request.release();
                return;
            }
            previous = request;
        }
    }

    fn pop(self: *Queue) *Request {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.head) |request| {
                self.count -= 1;
                self.head = request.next;
                if (self.head == null) self.tail = null;
                return request;
            }
            self.ready.wait(&self.mutex);
        }
    }
};

var queue: Queue = .{};

fn work(owner: *Queue) void {
    while (true) {
        const request = owner.pop();
        const remaining = request.deadline.remainingPollMilliseconds() catch null;
        request.failed = remaining == null or !lookup(std.mem.sliceTo(&request.name, 0), request.port, false, &request.result);
        request.completed.store(true, std.builtin.AtomicOrder.release);
        request.notifyAndRelease();
    }
}

/// Addresses for `name` and `port`, no later than `deadline`.
pub fn resolve(name: []const u8, port: u16, deadline: tcp.Deadline) Error!Addresses {
    if (name.len == 0 or name.len >= 256 or std.mem.indexOfScalar(u8, name, 0) != null) return error.ResolveFailed;
    var literal: Addresses = .{};
    if (lookup(name, port, true, &literal)) return literal;

    const request = try std.heap.smp_allocator.create(Request);
    var ends: [2]c_int = undefined;
    if (std.c.pipe(&ends) != 0) {
        std.heap.smp_allocator.destroy(request);
        return error.ResolveFailed;
    }
    request.* = .{ .port = port, .pipe = ends, .deadline = deadline };
    @memcpy(request.name[0..name.len], name);
    request.name[name.len] = 0;
    _ = tcp.setCloseOnExec(ends[0]);
    _ = tcp.setCloseOnExec(ends[1]);
    queue.push(request) catch |err| {
        request.destroy();
        return err;
    };
    return awaitQueued(&queue, request, deadline);
}

fn awaitQueued(owner: *Queue, request: *Request, deadline: tcp.Deadline) Error!Addresses {
    // awaitResult releases one reference; retain one through queue removal.
    _ = request.references.fetchAdd(1, std.builtin.AtomicOrder.monotonic);
    defer request.release();
    defer owner.cancel(request);
    return awaitResult(request, deadline);
}

fn awaitResult(request: *Request, deadline: tcp.Deadline) Error!Addresses {
    defer request.release();
    tcp.waitReadable(request.pipe[0], deadline) catch return error.ResolveTimeout;
    if (!request.completed.load(std.builtin.AtomicOrder.acquire)) return error.ResolveFailed;
    if (request.failed or request.result.count == 0) return error.ResolveFailed;
    return request.result;
}

/// Runs `getaddrinfo` for TCP addresses. With `numeric_only` only a literal
/// address is accepted, so no lookup is made.
fn lookup(name: []const u8, port: u16, numeric_only: bool, into: *Addresses) bool {
    var name_buffer: [256:0]u8 = undefined;
    if (name.len >= name_buffer.len) return false;
    @memcpy(name_buffer[0..name.len], name);
    name_buffer[name.len] = 0;
    var port_buffer: [6:0]u8 = undefined;
    const port_text = std.fmt.bufPrintZ(&port_buffer, "{d}", .{port}) catch return false;
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.UNSPEC;
    hints.socktype = std.c.SOCK.STREAM;
    hints.flags = .{ .NUMERICHOST = numeric_only, .NUMERICSERV = true };
    var result: ?*std.c.addrinfo = null;
    if (@intFromEnum(std.c.getaddrinfo(&name_buffer, port_text, &hints, &result)) != 0) return false;
    defer if (result) |first| std.c.freeaddrinfo(first);
    into.count = 0;
    var item = result;
    while (item) |entry| : (item = entry.next) {
        if (into.count == maximum_addresses) break;
        const address = entry.addr orelse continue;
        const length: u32 = @intCast(entry.addrlen);
        if (length > @sizeOf(std.c.sockaddr.storage)) continue;
        var stored = Address{ .storage = std.mem.zeroes(std.c.sockaddr.storage), .length = length };
        @memcpy(std.mem.asBytes(&stored.storage)[0..length], @as([*]const u8, @ptrCast(address))[0..length]);
        into.items[into.count] = stored;
        into.count += 1;
    }
    return into.count != 0;
}

test "a literal address is converted without a lookup thread" {
    const deadline = try tcp.Deadline.afterMilliseconds(1000);
    const v4 = try resolve("127.0.0.1", 5432, deadline);
    try std.testing.expectEqual(@as(usize, 1), v4.count);
    try std.testing.expectEqual(@as(c_ushort, std.c.AF.INET), v4.items[0].sockaddr().family);
    const v6 = try resolve("::1", 80, deadline);
    try std.testing.expectEqual(@as(c_ushort, std.c.AF.INET6), v6.items[0].sockaddr().family);
}

test "a name is resolved on a lookup thread" {
    const addresses = try resolve("localhost", 80, try tcp.Deadline.afterMilliseconds(5000));
    try std.testing.expect(addresses.count >= 1);
}

test "a name that cannot exist fails" {
    try std.testing.expectError(error.ResolveFailed, resolve("name-that-does-not-exist.invalid", 80, try tcp.Deadline.afterMilliseconds(10_000)));
}

test "bad names are refused before any lookup" {
    const deadline = try tcp.Deadline.afterMilliseconds(1000);
    try std.testing.expectError(error.ResolveFailed, resolve("", 80, deadline));
    try std.testing.expectError(error.ResolveFailed, resolve("a\x00b", 80, deadline));
}

test "a timeout before or after publication keeps the notification pipe alive" {
    // The deadline can fall on either side of result publication, but before
    // notification. Exercise both orderings without depending on OS timing.
    for ([_]bool{ false, true }) |published| {
        var ends: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&ends));
        const request = try std.heap.smp_allocator.create(Request);
        request.* = .{ .port = 80, .pipe = ends };
        request.completed.store(published, std.builtin.AtomicOrder.release);
        try std.testing.expectError(error.ResolveTimeout, awaitResult(request, try tcp.Deadline.afterMilliseconds(0)));
        try std.testing.expect(tcp.setCloseOnExec(ends[0]));
        try std.testing.expect(tcp.setCloseOnExec(ends[1]));
        request.completed.store(true, std.builtin.AtomicOrder.release);
        request.notifyAndRelease();
        try std.testing.expect(!tcp.setCloseOnExec(ends[0]));
        try std.testing.expect(!tcp.setCloseOnExec(ends[1]));
    }
}

test "notification before the deadline keeps the result alive for its caller" {
    var ends: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&ends));
    const request = try std.heap.smp_allocator.create(Request);
    request.* = .{ .port = 80, .pipe = ends };
    try std.testing.expect(lookup("127.0.0.1", 80, true, &request.result));
    request.completed.store(true, std.builtin.AtomicOrder.release);
    request.notifyAndRelease();
    const result = try awaitResult(request, try tcp.Deadline.afterMilliseconds(1000));
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(@as(c_ushort, std.c.AF.INET), result.items[0].sockaddr().family);
    try std.testing.expect(!tcp.setCloseOnExec(ends[0]));
    try std.testing.expect(!tcp.setCloseOnExec(ends[1]));
}

fn queuedTestRequest() !*Request {
    var ends: [2]c_int = undefined;
    if (std.c.pipe(&ends) != 0) return error.PipeFailed;
    const request = try std.heap.smp_allocator.create(Request);
    request.* = .{ .port = 80, .pipe = ends };
    return request;
}

test "pending capacity accepts below and at the limit and rejects above" {
    // No worker consumes this queue; placeholder descriptors need no I/O.
    var pending = Queue{ .threads_started = thread_count };
    var requests: [maximum_pending + 1]*Request = undefined;
    for (&requests) |*item| {
        item.* = try std.heap.smp_allocator.create(Request);
        item.*.* = .{ .port = 80, .pipe = .{ -1, -1 } };
    }
    defer for (requests) |request| request.destroy();
    for (requests[0 .. maximum_pending - 1]) |request| try pending.push(request);
    try std.testing.expectEqual(maximum_pending - 1, pending.count);
    try pending.push(requests[maximum_pending - 1]);
    try std.testing.expectEqual(maximum_pending, pending.count);
    try std.testing.expectError(error.ResolveFailed, pending.push(requests[maximum_pending]));
    try std.testing.expectEqual(maximum_pending, pending.count);
    // Taking a job frees capacity immediately.
    _ = pending.pop();
    try pending.push(requests[maximum_pending]);
}

test "expired queued requests free descriptors without a worker" {
    var pending = Queue{ .threads_started = thread_count };
    // Repeated timeouts must not consume the bounded queue's capacity.
    for (0..maximum_pending + 1) |_| {
        const request = try queuedTestRequest();
        const ends = request.pipe;
        try pending.push(request);
        try std.testing.expectError(error.ResolveTimeout, awaitQueued(&pending, request, .{ .expires_at_nanoseconds = 0 }));
        try std.testing.expectEqual(@as(usize, 0), pending.count);
        try std.testing.expect(pending.head == null and pending.tail == null);
        try std.testing.expect(!tcp.setCloseOnExec(ends[0]));
        try std.testing.expect(!tcp.setCloseOnExec(ends[1]));
    }
}

test "cancellation unlinks the head middle and tail" {
    for (0..3) |removed| {
        var pending = Queue{ .threads_started = thread_count };
        var requests: [3]*Request = undefined;
        for (&requests) |*item| {
            item.* = try queuedTestRequest();
            try pending.push(item.*);
        }
        pending.cancel(requests[removed]);
        requests[removed].release();
        try std.testing.expectEqual(@as(usize, 2), pending.count);
        for (requests, 0..) |request, index| {
            if (index == removed) continue;
            try std.testing.expectEqual(request, pending.pop());
            request.release();
            request.release();
        }
        try std.testing.expect(pending.head == null and pending.tail == null);
    }
}

test "timeout after worker dequeue retains the pipe until notification" {
    var pending = Queue{ .threads_started = thread_count };
    const request = try queuedTestRequest();
    const ends = request.pipe;
    try pending.push(request);
    try std.testing.expectEqual(request, pending.pop());
    try std.testing.expectError(error.ResolveTimeout, awaitQueued(&pending, request, .{ .expires_at_nanoseconds = 0 }));
    try std.testing.expect(tcp.setCloseOnExec(ends[0]));
    request.notifyAndRelease();
    try std.testing.expect(!tcp.setCloseOnExec(ends[0]));
    try std.testing.expect(!tcp.setCloseOnExec(ends[1]));
}
