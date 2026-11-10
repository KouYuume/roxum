const std = @import("std");
const allocator_context = @import("allocator/context.zig");
const host_allocator_module = @import("allocator/host_allocator.zig");
const bridge = @import("bridge.zig");
const MemoryLimit = @import("bridge/model.zig").MemoryLimit;
const connection = @import("connection.zig");
const diagnostics = @import("diagnostics.zig");
const event_loop = @import("event_loop.zig");
const net = @import("net.zig");
const poller_backend = @import("net/poller.zig");
const work_queue = @import("work_queue.zig");
const raw_bytes = @import("raw_bytes.zig");
const sync = @import("sync.zig");
const runtime = @import("runtime.zig");
const request_debug = @import("request_debug.zig");
const supervisor = @import("supervisor.zig");
const stdio = @import("stdio.zig");
const fiber = @import("fiber.zig");
const stack_overflow = @import("stack_overflow.zig");
const fiber_wait = @import("fiber_wait.zig");
const scheduler_module = @import("scheduler.zig");
const tcp = @import("net/tcp.zig");
const tcp_effect = @import("effect/tcp.zig");
const files_effect = @import("effect/files.zig");
const concurrency_effect = @import("effect/concurrency.zig");
const worker_count = @import("worker_count.zig");
const memory_budget = @import("memory_budget.zig");
const boxy = @import("boxy.zig");
const request_memory = @import("allocator/request_memory.zig");
const access_log = @import("access_log.zig");
const metrics = @import("metrics.zig");

const Domain = host_allocator_module.Domain;
const HostAllocator = host_allocator_module.HostAllocator;

pub const ConnectionError = net.Error ||
    stdio.Error ||
    connection.Error ||
    error{
        StartupFailed,
    };

/// The longest drain a worker accepts: one hour, past any orchestrator's
/// grace period.
const maximum_drain_timeout_milliseconds: u64 = 3_600_000;

/// Result of `init!`, passed from the Roc thread to the loop thread.
const Startup = struct {
    mutex: sync.Mutex = .{},
    done: sync.Condition = .{},
    result: ?Result = null,
    handoff_ready: bool = false,
    /// The process's waiting fibers, made with the handoff.
    waits: ?*scheduler_module.Waits = null,

    const Result = union(enum) {
        ready: Ready,
        failed,
    };

    /// What `init!` returned, and the settings the Roc thread checked.
    const Ready = struct {
        options: bridge.ListenOptions,
        settings: Settings,
    };

    fn finish(self: *Startup, result: Result) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.result = result;
        self.done.signal();
    }

    /// The loop thread made the handoff, sized for the application, and
    /// the process's waits.
    fn publishHandoff(self: *Startup, waits: *scheduler_module.Waits) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.waits = waits;
        self.handoff_ready = true;
        self.done.signal();
    }

    fn waitHandoff(self: *Startup) *scheduler_module.Waits {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.handoff_ready) self.done.wait(&self.mutex);
        return self.waits.?;
    }

    fn wait(self: *Startup) Result {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.result) |result| return result;
            self.done.wait(&self.mutex);
        }
    }
};

/// Runs one worker: this thread runs the connection event loop, and one
/// dedicated thread makes every Roc call (`init!`, handlers, body reads,
/// response producers), because allocator context and body tokens are
/// thread-local (R2).
pub fn run(
    environment: anytype,
    limits: connection.Limits,
    listen_port_override: ?u16,
) !void {
    // The Roc thread gets the handoff now and uses it once `init!` returned
    // and the loop sized it for the application's connection limit.
    const handoff = try std.heap.page_allocator.create(event_loop.Handoff);
    var startup = Startup{};
    stack_overflow.installProcess();

    const roc_thread = std.Thread.spawn(
        .{},
        runRocThread(@TypeOf(environment.*)),
        .{ environment, limits, handoff, &startup },
    ) catch diagnostics.fatal("failed to spawn the Roc thread");
    roc_thread.detach();

    const ready = switch (startup.wait()) {
        Startup.Result.ready => |ready| ready,
        Startup.Result.failed => return error.StartupFailed,
    };
    const listen_options = ready.options;
    const application_limits = ready.settings.limits;
    tcp_effect.setThreads(ready.settings.threads) catch {
        diagnostics.startupFailed("Tcp.OriginLimits (or HttpClient.Limits) takes up to 1024 connections per origin and 65536 idle connections for each thread");
        return error.StartupFailed;
    };
    handoff.* = try event_loop.Handoff.init(application_limits.maximum_connections);
    handoff.limits = application_limits;
    // One poller for the process: every connection's socket and
    // every waiting fiber's. The Roc threads wait on it; a new job wakes one
    // that is idle.
    const poller = try std.heap.page_allocator.create(poller_backend.Poller);
    poller.* = try poller_backend.Poller.init();
    try poller.registerWake(wait_wake_token);
    handoff.poller = poller;
    const waits = try std.heap.page_allocator.create(scheduler_module.Waits);
    waits.* = .{ .poller = poller };
    fiber_wait.waits = waits;
    handoff.waits = waits;
    handoff.work = try work_queue.Jobs.init(ready.settings.threads, poller);
    startup.publishHandoff(waits);
    const listener = supervisor.inherited_listener orelse try net.listenAddress(
        listen_options.address,
        listen_port_override orelse listen_options.port,
    );
    defer net.closeSocket(listener.socket);

    const workers = listen_options.processes;
    request_memory.setLimit(if (application_limits.request_memory_bytes) |bytes|
        std.math.cast(usize, bytes) orelse std.math.maxInt(usize)
    else
        memory_budget.automatic(workers, ready.settings.threads));
    access_log.start(listen_options.access_log) catch diagnostics.fatal("failed to start the access log");
    if (listen_options.metrics != null) metrics.startWorker(listen_options.routes) catch diagnostics.fatal("failed to start the metrics");
    const admin_port: ?supervisor.Admin = if (listen_options.metrics) |given| .{ .address = given.address, .port = given.port } else null;
    if (!try supervisor.notifyReady(listener, workers, application_limits.drain_timeout_milliseconds, admin_port)) try writePort(listener.port);
    try event_loop.run(listener.socket, handoff);
}

fn runRocThread(comptime Environment: type) fn (
    *Environment,
    connection.Limits,
    *event_loop.Handoff,
    *Startup,
) void {
    return struct {
        fn run(
            environment: *Environment,
            limits: connection.Limits,
            handoff: *event_loop.Handoff,
            startup: *Startup,
        ) void {
            stack_overflow.installThread() catch diagnostics.fatal("failed to give the Roc thread a signal stack");
            serveDispatched(environment, limits, handoff, startup) catch |err| {
                diagnostics.hostFailed(err);
                std.process.exit(1);
            };
        }
    }.run;
}

fn serveDispatched(
    environment: anytype,
    limits: connection.Limits,
    handoff: *event_loop.Handoff,
    startup: *Startup,
) !void {
    var host_allocator = environment.hostAllocator();
    var roc_host = runtime.makeRocHost(@ptrCast(&host_allocator));
    var application = initializeApplication(
        &host_allocator,
        &roc_host,
    ) catch |err| {
        startup.finish(Startup.Result.failed);
        return err;
    };
    defer deinitializeModel(
        &application.model_root,
        &host_allocator,
        environment.generation,
    );
    try environment.capturePersistentBaseline();
    const settings = applyListenOptions(limits, application.listen_options) catch |err| {
        startup.finish(Startup.Result.failed);
        return err;
    };
    const application_limits = settings.limits;
    startup.finish(.{ .ready = .{ .options = application.listen_options, .settings = settings } });
    const waits = startup.waitHandoff();

    // Sockets a request waits on suspend its fiber instead of the thread.
    tcp.fiber_wait = fiber_wait.waitSocketHook;

    const Request = RequestFiber(@TypeOf(environment.*));
    var shared = Request.Shared{
        .limits = application_limits,
        .handoff = handoff,
        .model_root = &application.model_root,
    };
    // `init!` has run, on this thread alone: the other Roc threads start
    // only now. The interpreter makes its process-wide RocOps on the
    // first call without a lock.
    roc_initialized.store(true, std.builtin.AtomicOrder.release);
    for (1..settings.threads) |index| {
        const own = try std.heap.page_allocator.create(@TypeOf(environment.*));
        own.* = environment.workerClone();
        const other = try std.heap.page_allocator.create(Request.Thread);
        other.* = .{ .index = index, .environment = own, .io = event_loop.Loop.initRoc(handoff, index), .waits = waits };
        try spawnRocThread(Request, other, &shared);
    }
    var thread = Request.Thread{ .index = 0, .environment = environment, .io = event_loop.Loop.initRoc(handoff, 0), .waits = waits };
    try serveJobs(Request, &thread, &shared);
}

/// Set once `init!` has run. A Roc thread other than the first starts only
/// after it.
var roc_initialized = std.atomic.Value(bool).init(false);

fn spawnRocThread(comptime Request: type, thread: *Request.Thread, shared: *Request.Shared) !void {
    std.debug.assert(roc_initialized.load(std.builtin.AtomicOrder.acquire));
    const Run = struct {
        fn run(own: *Request.Thread, process: *Request.Shared) void {
            stack_overflow.installThread() catch diagnostics.fatal("failed to give a Roc thread a signal stack");
            serveJobs(Request, own, process) catch |err| {
                diagnostics.hostFailed(err);
                std.process.exit(1);
            };
        }
    };
    const spawned = std.Thread.spawn(.{}, Run.run, .{ thread, shared }) catch diagnostics.fatal("failed to spawn a Roc thread");
    spawned.detach();
}

/// A Roc thread's work: the process poller's events (connections to read
/// and write, waiting fibers whose wait ended), then its jobs.
fn serveJobs(comptime Request: type, thread: *Request.Thread, shared: *Request.Shared) !void {
    const work = &shared.handoff.work;
    while (true) {
        // What the poller reports goes before new work: a head read now
        // becomes a job, and a resumed request finishes sooner. While an
        // idle thread waits on the poller it gets the events, and busy
        // threads leave the poller to it rather than contend for it.
        if (!work.pollerTaken()) try pollEvents(Request, thread, false);
        try resumeReady(Request, thread);
        const job = work.next(thread.index) orelse {
            // Nothing queued. Counted idle first, so a job queued after the
            // last look wakes this thread. One idle thread waits on the
            // poller for an event, a deadline, or a new job; the others
            // park until a job comes or the poller is free.
            work.beginIdle();
            if (work.next(thread.index)) |late| {
                work.endIdle();
                try runJob(Request, thread, shared, late);
            } else if (work.takePoller()) {
                try pollEvents(Request, thread, true);
            } else {
                work.park();
                work.endIdle();
            }
            try resumeReady(Request, thread);
            continue;
        };
        try runJob(Request, thread, shared, job);
    }
}

/// Runs a job a Roc thread took: a stream's next step, or a new request on
/// a fiber of its own.
fn runJob(comptime Request: type, thread: *Request.Thread, shared: *Request.Shared, job: work_queue.Job) !void {
    switch (job) {
        work_queue.Job.request => |slot| try runNewRequest(Request, thread, shared, slot),
        work_queue.Job.resumed => |target| try runRequest(Request, thread, target),
    }
}

fn runNewRequest(comptime Request: type, thread: *Request.Thread, shared: *Request.Shared, slot: u32) !void {
    const handoff = shared.handoff;
    const application_limits = shared.limits;
    const item = &handoff.connections[slot];
    // Admission: a request that waited too long in the queue, or that
    // would start past the limit of requests in progress, is answered 503
    // without running.
    if (admit(handoff, item, application_limits)) |outcome| {
        const deadline = net.Deadline.afterMilliseconds(application_limits.response_write_timeout_milliseconds) catch net.Deadline{ .expires_at_nanoseconds = 0 };
        thread.io.rejectTaken(slot, deadline, outcome, application_limits.request_id_source);
        return;
    }
    const request = try thread.pool.acquire(shared, thread, slot);
    const target = try thread.fibers.acquire(Request.start, request);
    try runRequest(Request, thread, target);
}

/// Counts the request in progress, or says why it is answered 503 without
/// running. The place is taken before the check, so threads that admit at
/// once stay within the limit.
fn admit(handoff: *event_loop.Handoff, item: *const event_loop.Connection, limits: connection.Limits) ?access_log.Outcome {
    if (handoff.in_progress.fetchAdd(1, std.builtin.AtomicOrder.acq_rel) >= limits.maximum_requests_in_progress) {
        _ = handoff.in_progress.fetchSub(1, std.builtin.AtomicOrder.release);
        return access_log.Outcome.in_progress_full;
    }
    const now = net.monotonicNanoseconds() catch return null;
    if (now -| item.dispatched_at >= limits.queue_timeout_milliseconds * std.time.ns_per_ms) {
        _ = handoff.in_progress.fetchSub(1, std.builtin.AtomicOrder.release);
        return access_log.Outcome.queue_timeout;
    }
    return null;
}

/// Runs a request's fiber until it finishes or waits. A request that waits
/// for the first time takes its values out of the shared request heap, which
/// starts the next request empty: a request that never waits pays nothing
/// for fibers beyond the switch.
fn runRequest(comptime Request: type, thread: *Request.Thread, target: *fiber.Fiber) !void {
    const request: *Request = @ptrCast(@alignCast(target.userdata.?));
    // A request that waited may go on on another thread than it started on
    //: from here it uses this thread's environment, and its heap this
    // thread's cache. One that never waited is still on its own thread.
    if (request.heap) |*heap| {
        thread.environment.adoptStream(heap);
    } else {
        std.debug.assert(request.thread == thread);
    }
    request.thread = thread;
    fiber.resumeFiber(target);
    if (target.crashed or target.cancelled) {
        // Its Roc code crashed, or it stopped at a wait while it wrote its
        // body: only this request stops.
        tcp_effect.closeHeldBy(target);
        files_effect.closeHeldBy(target);
        concurrency_effect.releaseHeldBy(target);
        try request.abandon(if (target.cancelled) target.stop.load(std.builtin.AtomicOrder.acquire) else fiber.Stop.none);
        _ = request.shared.handoff.in_progress.fetchSub(1, std.builtin.AtomicOrder.release);
        thread.pool.release(request);
        thread.fibers.release(target);
        return;
    }
    if (target.finished) {
        files_effect.closeHeldBy(target);
        concurrency_effect.releaseHeldBy(target);
        _ = request.shared.handoff.in_progress.fetchSub(1, std.builtin.AtomicOrder.release);
        if (request.failure) |err| return err;
        thread.pool.release(request);
        thread.fibers.release(target);
        return;
    }
    if (request.heap == null) try request.detach();
    // Registered only now that the fiber has suspended: whichever thread
    // the wait ends on may resume it at once.
    try thread.waits.addWaiting(target);
}

/// Poller token of the wake that a new job, or a wake from another thread,
/// sends the poller of the waiting fibers. Never a fiber's token.
const wait_wake_token: u64 = std.math.maxInt(u64) - 1;

/// Acts on what the process's poller reports: a connection's event on
/// this thread's view of the connections, a waiting fiber whose socket is
/// ready, and the waits whose deadline passed, which go to `ready`. With
/// `block`, first waits for an event, a wake, or the earliest deadline.
fn pollEvents(comptime Request: type, thread: *Request.Thread, block: bool) !void {
    const waits = thread.waits;
    const io = &thread.io;
    const before = net.monotonicNanoseconds() catch return error.ClockFailed;
    const limit: ?u32 = if (block) waits.beginBlockingWait(before) else 0;
    const reported = waits.poller.wait(&thread.raw_events, &thread.events, limit) catch |err| {
        if (block) waits.endBlockingWait();
        return err;
    };
    if (block) waits.endBlockingWait();
    // No longer idle: what it reads now becomes its own work, and a job
    // queued meanwhile wakes another thread. A parked thread takes the
    // poller in its place.
    if (block) {
        io.handoff.work.endIdle();
        io.handoff.work.releasePoller();
    }
    io.readClock();
    io.handoff.last_poll_at.store(io.now, std.builtin.AtomicOrder.release);
    var took_wake = false;
    for (reported) |event| {
        if (event.kind == poller_backend.Event.Kind.wake) {
            took_wake = true;
            continue;
        }
        if (scheduler_module.isFiberToken(event.token)) {
            if (try waits.onEvent(event.token, io.now)) |target| try thread.ready.append(std.heap.smp_allocator, target);
            continue;
        }
        io.onEvent(event);
    }
    try waits.collectExpired(io.now, &thread.ready);
    if (!block and took_wake) waits.passOnWake();
}

fn resumeReady(comptime Request: type, thread: *Request.Thread) !void {
    for (thread.ready.items) |target| try runRequest(Request, thread, target);
    thread.ready.clearRetainingCapacity();
}

/// One request on its own fiber: the Session that reads and answers it, and
/// the allocator its Roc values use. Requests share the request heap until
/// they wait (`heap` is then their own).
fn RequestFiber(comptime Environment: type) type {
    return struct {
        const Self = @This();

        /// What every Roc thread of the process shares.
        pub const Shared = struct {
            limits: connection.Limits,
            handoff: *event_loop.Handoff,
            model_root: *bridge.ModelRoot,
        };

        /// One Roc thread's own: its environment, whose shared
        /// request heap and page cache only it uses, its scheduler, and the
        /// requests it keeps for reuse.
        pub const Thread = struct {
            /// Which of the process's Roc threads, for its own job queue.
            index: usize,
            environment: *Environment,
            /// This thread's view of the process's connections, which it
            /// reads, writes, and finishes requests on.
            io: event_loop.Loop,
            /// The process's waiting fibers.
            waits: *scheduler_module.Waits,
            fibers: scheduler_module.FiberPool = .{},
            pool: Pool = .{},
            ready: std.ArrayList(*fiber.Fiber) = .empty,
            /// Kept here rather than on the stack of each poll: a safe
            /// build fills an `undefined` stack array on every call.
            raw_events: [64]poller_backend.RawEvent = undefined,
            events: [64 * poller_backend.events_per_raw]poller_backend.Event = undefined,
        };

        /// Requests kept for reuse with their Session and its buffers. A
        /// burst of waiting requests may create more; the extra ones are
        /// freed when they end.
        pub const Pool = struct {
            idle: std.ArrayList(*Self) = .empty,

            const maximum_idle = 64;

            pub fn acquire(self: *Pool, shared: *Shared, thread: *Thread, slot: u32) !*Self {
                const request = self.idle.pop() orelse try Self.create(shared.limits);
                request.shared = shared;
                request.thread = thread;
                request.slot = slot;
                request.heap = null;
                request.failure = null;
                request.generation = thread.environment.generation;
                request.host_allocator = thread.environment.hostAllocator();
                request.roc_host = runtime.makeRocHost(@ptrCast(&request.host_allocator));
                request.started_at = net.monotonicNanoseconds() catch 0;
                return request;
            }

            pub fn release(self: *Pool, request: *Self) void {
                request.session.reader.forget();
                if (self.idle.items.len >= maximum_idle) return request.destroy();
                self.idle.append(std.heap.smp_allocator, request) catch request.destroy();
            }
        };

        shared: *Shared = undefined,
        /// The Roc thread running the request now. It changes only when the
        /// request resumes after a wait, once its values are in `heap`.
        thread: *Thread = undefined,
        slot: u32 = 0,
        session: *connection.Session,
        generation: usize = 0,
        host_allocator: HostAllocator = undefined,
        roc_host: bridge.RocHost = undefined,
        /// The connection's side of a written body's guard.
        watch: event_loop.ClientWatch = undefined,
        heap: ?Environment.Stream = null,
        /// Set when the request failed in a way that stops the worker; the
        /// thread returns it once the fiber has finished.
        failure: ?anyerror = null,
        /// When the Roc thread took the request from the queue.
        started_at: u64 = 0,

        fn create(limits: connection.Limits) !*Self {
            const self = try std.heap.smp_allocator.create(Self);
            errdefer std.heap.smp_allocator.destroy(self);
            const session = try std.heap.page_allocator.create(connection.Session);
            session.* = connection.Session.initWithLimits(undefined, limits);
            // Bytes a slow reader does not accept at once go back to the loop.
            session.defer_buffered_writes = true;
            self.* = .{ .session = session };
            return self;
        }

        fn destroy(self: *Self) void {
            self.session.reader.deinit();
            std.heap.page_allocator.destroy(self.session);
            std.heap.smp_allocator.destroy(self);
        }

        /// Moves the request's values into a heap of its own. The request's
        /// allocator is updated in place, so the Roc host and the saved
        /// allocator context, which point at it, follow.
        fn detach(self: *Self) !void {
            const environment = self.thread.environment;
            self.heap = try environment.detachRequest();
            try environment.resetRequest();
            self.host_allocator = environment.streamHostAllocator(&self.heap.?);
        }

        /// Frees the values of a request that crashed (`stop` is `none`), or
        /// that stopped at a wait while it wrote its body,
        /// without running their decrefs. A crash before the head is
        /// answered 500; after the head, the connection only closes.
        fn abandon(self: *Self, stop: fiber.Stop) !void {
            const shared = self.shared;
            const environment = self.thread.environment;
            self.session.discardPendingOutput();
            const head_sent = self.session.abandonWritten();
            if (self.heap) |*heap| environment.abandonStream(heap) else try environment.abandonRequest();
            self.heap = null;
            if (head_sent) {
                const written_entry = self.accessEntry();
                const outcome = switch (stop) {
                    fiber.Stop.none => access_log.Outcome.crashed,
                    fiber.Stop.client_gone => access_log.Outcome.client_closed,
                    fiber.Stop.drained => access_log.Outcome.drained,
                };
                return self.thread.io.failWritten(self.slot, &written_entry, outcome);
            }
            const deadline = net.Deadline.afterMilliseconds(shared.limits.response_write_timeout_milliseconds) catch net.Deadline{ .expires_at_nanoseconds = 0 };
            const entry = self.accessEntry();
            self.thread.io.fail(self.slot, deadline, &entry);
        }

        /// The request's access log entry, as its session filled it in, with
        /// when it started and how long it waited in the queue.
        fn accessEntry(self: *const Self) access_log.Entry {
            var entry = self.session.access;
            const dispatched_at = self.shared.handoff.connections[self.slot].dispatched_at;
            entry.started_at = dispatched_at;
            entry.queue_nanoseconds = self.started_at -| dispatched_at;
            return entry;
        }

        pub fn start(target: *fiber.Fiber) void {
            const self: *Self = @ptrCast(@alignCast(target.userdata.?));
            self.serve() catch |err| {
                self.failure = err;
            };
        }

        fn serve(self: *Self) !void {
            const shared = self.shared;
            const handoff = shared.handoff;
            const slot = self.slot;
            const item = &handoff.connections[slot];
            const session = self.session;
            const locals = fiber.currentLocals() orelse unreachable;
            locals.client_socket = item.accepted.socket;
            locals.client_watch_replaced = &item.read_watch_replaced;
            session.active_streams = &handoff.active_streams;
            self.watch = .{ .handoff = handoff, .slot = slot };
            session.client_hooks = .{
                .context = @ptrCast(&self.watch),
                .arm = event_loop.ClientWatch.arm,
                .disarm = event_loop.ClientWatch.disarm,
                .restore = event_loop.ClientWatch.restore,
            };
            session.draining = &handoff.draining;
            session.accepted = item.accepted;
            session.completed_requests = item.completed_requests;
            {
                const parsed = item.takeParsedHead();
                defer if (parsed) |parser| event_loop.destroyParser(parser);
                try session.reader.seedFrom(&item.buffer, &item.length, parsed);
            }

            const outcome = session.handleDispatched(
                &self.host_allocator,
                self.generation,
                shared.model_root,
                &self.roc_host,
                item.prefetch,
            ) catch |err| {
                const environment = self.thread.environment;
                session.discardPendingOutput();
                if (self.heap) |*heap| try environment.releaseStream(heap) else try environment.resetRequest();
                return err;
            };
            // The request's values are released here. The response and every
            // Roc decref complete before; pending output is host-owned and
            // survives. The handler may have waited and gone on on another
            // thread.
            const environment = self.thread.environment;
            if (self.heap) |*heap| {
                try environment.releaseStream(heap);
            } else {
                try environment.resetRequest();
            }
            self.heap = null;

            // Pipelined bytes are kept only for a connection that stays open.
            // Either way the store gives up a buffer grown for a body.
            var keep_alive = outcome == connection.Outcome.reuse;
            if (keep_alive) item.completed_requests = session.completed_requests;
            item.store(if (keep_alive) session.reader.pendingBytes() else &.{}) catch {
                keep_alive = false;
            };
            if (session.takePendingOutput()) |pending| {
                item.output = pending.allocation;
                item.output_length = pending.length;
                item.output_sent = 0;
                item.timeout = pending.deadline;
            }
            if (access_log.enabled() and session.answered) {
                const entry = self.accessEntry();
                item.finishAccess(&entry);
            }
            // The loop closes the connection, after a lingering close, so a
            // response sent while request bytes are unread is not lost to a
            // reset.
            const action = if (keep_alive)
                event_loop.Completion.Action.reuse
            else
                event_loop.Completion.Action.close;
            self.thread.io.complete(.{ .slot = slot, .action = action });
        }
    };
}

/// What `init!` asked for, checked: the process's limits and its threads.
const Settings = struct {
    limits: connection.Limits,
    threads: usize,
};

fn applyListenOptions(base: connection.Limits, options: bridge.ListenOptions) error{StartupFailed}!Settings {
    const threads = try threadCount(options.threads, boxy.linked());
    try checkProcesses(options.processes);
    try checkDrainTimeout(options.drain_timeout_milliseconds);
    var limits = try applyLimits(try applyTimeouts(base, options.timeouts), options.limits, threads);
    limits.drain_timeout_milliseconds = options.drain_timeout_milliseconds;
    limits.request_id_source = options.request_id;
    return .{ .limits = limits, .threads = threads };
}

/// The process's threads. An app that links Roc's erased-callable runtime
/// runs on one: `Auto` falls back to it, and a fixed count above
/// it stops startup rather than run fewer threads than asked.
fn threadCount(threads: bridge.ListenThreads, boxy_linked: bool) error{StartupFailed}!usize {
    switch (threads) {
        bridge.ListenThreads.auto => {
            if (!boxy_linked) return worker_count.automatic();
            diagnostics.warning("the app puts a function in a Box, whose Roc runtime is not yet safe on several threads; it runs on one thread per process (raise Server.ListenOptions.processes to use more CPUs)");
            return 1;
        },
        bridge.ListenThreads.fixed => |count| {
            if (count == 0 or count > worker_count.maximum_threads) {
                diagnostics.startupFailed("Server.Threads.Fixed takes 1 to 256 threads");
                return error.StartupFailed;
            }
            if (boxy_linked and count > 1) {
                diagnostics.startupFailed("the app puts a function in a Box, whose Roc runtime is not yet safe on several threads: Server.Threads.Fixed must be 1 (raise Server.ListenOptions.processes to use more CPUs)");
                return error.StartupFailed;
            }
            return count;
        },
    }
}

fn checkProcesses(processes: u16) error{StartupFailed}!void {
    if (processes == 0 or processes > worker_count.maximum) {
        diagnostics.startupFailed("Server.ListenOptions.processes takes 1 to 64");
        return error.StartupFailed;
    }
}

/// A drain of zero would cut every request in flight, which is what the
/// timeout exists to avoid.
fn checkDrainTimeout(milliseconds: u64) error{StartupFailed}!void {
    if (milliseconds == 0 or milliseconds > maximum_drain_timeout_milliseconds) {
        diagnostics.startupFailed("Server.ListenOptions.drain_timeout_milliseconds takes 1 to 3600000 (one hour)");
        return error.StartupFailed;
    }
}

/// A limit for the process: the application's, or `per_thread` for each
/// thread. Zero would answer every request (or stream) 503, so it
/// stops startup.
fn countFor(count: bridge.ListenCount, per_thread: u64, threads: usize, message: []const u8) error{StartupFailed}!u64 {
    return switch (count) {
        bridge.ListenCount.auto => per_thread * threads,
        bridge.ListenCount.fixed => |value| if (value == 0) {
            diagnostics.startupFailed(message);
            return error.StartupFailed;
        } else value,
    };
}

/// Replaces the process's limits with the application's choice. `Auto`
/// gives each thread the per-thread defaults.
fn applyLimits(base: connection.Limits, limits: bridge.ListenLimits, threads: usize) error{StartupFailed}!connection.Limits {
    const defaults = connection.Limits{};
    const streams = try countFor(limits.maximum_streams, defaults.maximum_streams, threads, "Server.Limits.maximum_streams must be at least 1");
    const queued = try countFor(limits.maximum_queued_requests, defaults.maximum_queued_requests, threads, "Server.Limits.maximum_queued_requests must be at least 1");
    const in_progress = try countFor(limits.maximum_requests_in_progress, defaults.maximum_requests_in_progress, threads, "Server.Limits.maximum_requests_in_progress must be at least 1");
    const connections = try countFor(limits.maximum_connections, defaults.maximum_connections, threads, "Server.Limits.maximum_connections takes 1 to 65536 for each thread");
    if (connections > @as(u64, event_loop.largest_maximum_connections) * threads) {
        diagnostics.startupFailed("Server.Limits.maximum_connections takes 1 to 65536 for each thread");
        return error.StartupFailed;
    }
    if (limits.queue_timeout_milliseconds == 0) {
        diagnostics.startupFailed("Server.Limits.queue_timeout_milliseconds must be at least 1");
        return error.StartupFailed;
    }
    switch (limits.request_memory) {
        MemoryLimit.auto => {},
        MemoryLimit.bytes => |bytes| if (bytes == 0) {
            diagnostics.startupFailed("Server.MemoryLimit.Bytes must be at least 1");
            return error.StartupFailed;
        },
    }
    var applied = base;
    applied.maximum_streams = std.math.cast(usize, streams) orelse std.math.maxInt(usize);
    applied.maximum_queued_requests = std.math.cast(usize, queued) orelse std.math.maxInt(usize);
    applied.queue_timeout_milliseconds = limits.queue_timeout_milliseconds;
    applied.maximum_requests_in_progress = std.math.cast(usize, in_progress) orelse std.math.maxInt(usize);
    applied.maximum_connections = @intCast(connections);
    applied.request_memory_bytes = switch (limits.request_memory) {
        MemoryLimit.auto => null,
        MemoryLimit.bytes => |bytes| bytes,
    };
    applied.maximum_body_bytes = limits.maximum_body_bytes;
    applied.maximum_streamed_body_bytes = limits.maximum_streamed_body_bytes orelse std.math.maxInt(u64);
    return applied;
}

/// Replaces the connection timeouts with the application's choice. A zero
/// timeout would close every connection at once, so it stops startup.
fn applyTimeouts(
    base: connection.Limits,
    timeouts: bridge.Timeouts,
) error{StartupFailed}!connection.Limits {
    const values = [_]u64{
        timeouts.initial_request_milliseconds,
        timeouts.keep_alive_idle_milliseconds,
        timeouts.request_head_milliseconds,
        timeouts.request_body_milliseconds,
        timeouts.response_write_milliseconds,
    };
    for (values) |value| {
        if (value == 0) {
            diagnostics.startupFailed("every Server.Timeouts value must be at least 1 millisecond");
            return error.StartupFailed;
        }
    }
    var limits = base;
    limits.initial_request_timeout_milliseconds = timeouts.initial_request_milliseconds;
    limits.keep_alive_idle_timeout_milliseconds = timeouts.keep_alive_idle_milliseconds;
    limits.request_head_timeout_milliseconds = timeouts.request_head_milliseconds;
    limits.request_body_timeout_milliseconds = timeouts.request_body_milliseconds;
    limits.response_write_timeout_milliseconds = timeouts.response_write_milliseconds;
    return limits;
}

fn initializeApplication(
    host_allocator: *HostAllocator,
    roc_host: *bridge.RocHost,
) ConnectionError!bridge.Application {
    allocator_context.setCurrent(.{
        .host_allocator = host_allocator,
        .domain = Domain.persistent,
        .generation = 0,
    });
    defer allocator_context.clearCurrent();

    const result = bridge.rocInit();
    return switch (result.tag) {
        bridge.InitResultTag.Ok => try bridge.Application.initOwned(
            result.payload_ok(),
            roc_host,
        ),
        bridge.InitResultTag.Err => {
            const message = result.payload_err();
            diagnostics.startupFailed(message.asSlice());
            result.decref(roc_host);
            return error.StartupFailed;
        },
    };
}

fn deinitializeModel(
    model_root: *bridge.ModelRoot,
    host_allocator: *HostAllocator,
    generation: usize,
) void {
    allocator_context.setCurrent(.{
        .host_allocator = host_allocator,
        .domain = Domain.persistent,
        .generation = generation,
    });
    defer allocator_context.clearCurrent();
    model_root.deinit();
}

fn writePort(port: u16) stdio.Error!void {
    try stdio.writeStdoutPort(port);
}

test "application timeouts replace only the timeout limits" {
    const base = connection.Limits{ .unread_body_maximum_bytes = 7 };
    const applied = try applyTimeouts(base, .{
        .initial_request_milliseconds = 1,
        .keep_alive_idle_milliseconds = 75_000,
        .request_head_milliseconds = 3,
        .request_body_milliseconds = 4,
        .response_write_milliseconds = 5,
    });
    try std.testing.expectEqual(@as(u64, 1), applied.initial_request_timeout_milliseconds);
    try std.testing.expectEqual(@as(u64, 75_000), applied.keep_alive_idle_timeout_milliseconds);
    try std.testing.expectEqual(@as(u64, 3), applied.request_head_timeout_milliseconds);
    try std.testing.expectEqual(@as(u64, 4), applied.request_body_timeout_milliseconds);
    try std.testing.expectEqual(@as(u64, 5), applied.response_write_timeout_milliseconds);
    try std.testing.expectEqual(@as(usize, 7), applied.unread_body_maximum_bytes);
}

test "a zero timeout stops startup" {
    const valid = bridge.Timeouts{
        .initial_request_milliseconds = 1,
        .keep_alive_idle_milliseconds = 1,
        .request_head_milliseconds = 1,
        .request_body_milliseconds = 1,
        .response_write_milliseconds = 1,
    };
    _ = try applyTimeouts(.{}, valid);
    var zero = valid;
    zero.keep_alive_idle_milliseconds = 0;
    try std.testing.expectError(error.StartupFailed, applyTimeouts(.{}, zero));
}

test "every limit is at least 1 and replaces only itself" {
    const base = connection.Limits{ .unread_body_maximum_bytes = 7 };
    const valid = bridge.ListenLimits{
        .maximum_streams = bridge.ListenCount.auto,
        .maximum_queued_requests = bridge.ListenCount.auto,
        .queue_timeout_milliseconds = 5_000,
        .maximum_requests_in_progress = bridge.ListenCount.auto,
        .maximum_connections = bridge.ListenCount.auto,
        .request_memory = MemoryLimit.auto,
        .maximum_body_bytes = 2 * 1024 * 1024,
        .maximum_streamed_body_bytes = null,
    };
    inline for (.{ "maximum_streams", "maximum_queued_requests", "maximum_requests_in_progress" }) |field| {
        var zero = valid;
        @field(zero, field) = .{ .fixed = 0 };
        try std.testing.expectError(error.StartupFailed, applyLimits(base, zero, 1));
        for ([_]u64{ 1, 2, 64 }) |value| {
            var limits = valid;
            @field(limits, field) = .{ .fixed = value };
            const applied = try applyLimits(base, limits, 4);
            try std.testing.expectEqual(value, @as(u64, @intCast(@field(applied, field))));
            try std.testing.expectEqual(@as(usize, 7), applied.unread_body_maximum_bytes);
        }
    }
    var no_timeout = valid;
    no_timeout.queue_timeout_milliseconds = 0;
    try std.testing.expectError(error.StartupFailed, applyLimits(base, no_timeout, 1));
    // Up to 65,536 connections for each thread.
    for ([_]u64{ 0, 65_537 }) |value| {
        var connections = valid;
        connections.maximum_connections = .{ .fixed = value };
        try std.testing.expectError(error.StartupFailed, applyLimits(base, connections, 1));
    }
    var largest = valid;
    largest.maximum_connections = .{ .fixed = 131_072 };
    try std.testing.expectEqual(@as(u32, 131_072), (try applyLimits(base, largest, 2)).maximum_connections);
    var unbounded = valid;
    unbounded.maximum_streams = .{ .fixed = std.math.maxInt(u64) };
    try std.testing.expectEqual(std.math.cast(usize, std.math.maxInt(u64)) orelse std.math.maxInt(usize), (try applyLimits(base, unbounded, 1)).maximum_streams);
}

test "Auto limits give each thread the per-thread defaults" {
    const valid = bridge.ListenLimits{
        .maximum_streams = bridge.ListenCount.auto,
        .maximum_queued_requests = bridge.ListenCount.auto,
        .queue_timeout_milliseconds = 5_000,
        .maximum_requests_in_progress = bridge.ListenCount.auto,
        .maximum_connections = bridge.ListenCount.auto,
        .request_memory = MemoryLimit.auto,
        .maximum_body_bytes = 2 * 1024 * 1024,
        .maximum_streamed_body_bytes = null,
    };
    const applied = try applyLimits(.{}, valid, 8);
    try std.testing.expectEqual(@as(usize, 64 * 8), applied.maximum_streams);
    try std.testing.expectEqual(@as(usize, 1024 * 8), applied.maximum_queued_requests);
    try std.testing.expectEqual(@as(usize, 1024 * 8), applied.maximum_requests_in_progress);
    try std.testing.expectEqual(@as(u32, 4096 * 8), applied.maximum_connections);
}

test "threads take 1 to 256 and processes 1 to 64" {
    _ = try threadCount(bridge.ListenThreads.auto, false);
    for ([_]u16{ 1, 2, 255, 256 }) |count| try std.testing.expectEqual(@as(usize, count), try threadCount(.{ .fixed = count }, false));
    for ([_]u16{ 0, 257, std.math.maxInt(u16) }) |count| {
        try std.testing.expectError(error.StartupFailed, threadCount(.{ .fixed = count }, false));
    }
    for ([_]u16{ 1, 64 }) |count| try checkProcesses(count);
    for ([_]u16{ 0, 65 }) |count| try std.testing.expectError(error.StartupFailed, checkProcesses(count));
}

test "an app that links boxy runs on one thread" {
    try std.testing.expectEqual(@as(usize, 1), try threadCount(bridge.ListenThreads.auto, true));
    try std.testing.expectEqual(@as(usize, 1), try threadCount(.{ .fixed = 1 }, true));
    try std.testing.expectError(error.StartupFailed, threadCount(.{ .fixed = 2 }, true));
}

test "drain timeouts from 1 ms to one hour are accepted" {
    for ([_]u64{ 1, 2, 20_000, 3_599_999, 3_600_000 }) |value| try checkDrainTimeout(value);
    for ([_]u64{ 0, 3_600_001, std.math.maxInt(u64) }) |value| {
        try std.testing.expectError(error.StartupFailed, checkDrainTimeout(value));
    }
}

test {
    _ = worker_count;
    _ = fiber;
    _ = fiber_wait;
    _ = scheduler_module;
}
