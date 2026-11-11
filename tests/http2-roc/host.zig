//! Byte-driven HTTP/2 fixture linked to the real platform and Roc application.
const std = @import("std");
const host = @import("host");
const h2 = host.http2;
const bridge = host.bridge;
const context = host.allocator_context;
const fiber = host.fiber;
const scheduler = host.scheduler;
const poller_backend = host.poller;
const tracking = @import("options").tracking;
const Environment = if (tracking) @import("tracking_environment").Environment else host.arena.ArenaEnvironment;

comptime {
    host.exportRuntime();
    @export(&main, .{ .name = "main" });
}

const State = struct {
    budget: h2.input.Budget = .{ .backing = std.heap.smp_allocator, .limit = 128 * 1024 },
    streams: h2.streams.Streams = undefined,
    failed: bool = false,

    fn from(ptr: *anyopaque) *State {
        return @ptrCast(@alignCast(ptr));
    }
    fn header(ptr: *anyopaque, id: h2.engine.StreamId, field: h2.engine.Header) void {
        from(ptr).streams.header(id, field) catch {
            from(ptr).failed = true;
        };
    }
    fn headersComplete(ptr: *anyopaque, id: h2.engine.StreamId) void {
        from(ptr).streams.headersComplete(id, 1) catch {
            from(ptr).failed = true;
        };
    }
    fn data(ptr: *anyopaque, id: h2.engine.StreamId, bytes: []const u8) void {
        from(ptr).streams.data(id, bytes) catch {
            from(ptr).failed = true;
        };
    }
    fn end(ptr: *anyopaque, id: h2.engine.StreamId) void {
        from(ptr).streams.end(id) catch {
            from(ptr).failed = true;
        };
    }
    fn closed(ptr: *anyopaque, id: h2.engine.StreamId) void {
        from(ptr).streams.close(id);
    }
};

// Stable job storage keeps allocator pointers in suspended fiber locals valid.
const Job = struct {
    target: ?*fiber.Fiber = null,
    waits: *scheduler.Waits = undefined,
    registered: bool = false,
    owner: *h2.owner.Owner = undefined,
    streams: *h2.streams.Streams = undefined,
    ticket: h2.streams.Ticket = undefined,
    model: *bridge.ModelRoot = undefined,
    allocator: host.HostAllocator = undefined,
    roc_host: bridge.RocHost = undefined,
    generation: usize = 0,
    heap: ?Environment.Stream = null,
    failure: ?anyerror = null,

    fn start(target: *fiber.Fiber) void {
        const self: *Job = @ptrCast(@alignCast(target.userdata.?));
        execute(self.owner, self.streams, self.ticket, self.model, &self.allocator, &self.roc_host, self.generation) catch |err| {
            self.failure = err;
        };
    }

    fn resumeJob(self: *Job, environment: *Environment, handled: *usize, rejected: *usize) !void {
        if (self.registered) return error.ResumeWhileRegistered;
        const target = self.target.?;
        if (self.heap) |*heap| {
            environment.adoptStream(heap);
            std.debug.print("resumed-request\n", .{});
        }
        fiber.resumeFiber(target);
        if (context.current() != null) return error.LeakedFiberContext;
        if (target.crashed) return error.UnexpectedFiberStop;
        if (target.cancelled) {
            if (self.streams.leases.runningStream(self.ticket) != null) return error.CancelledLiveStream;
            if (target.locals.concurrency.count != 1) return error.MissingHeldPermit;
            host.tcp_effect.closeHeldBy(target);
            host.files_effect.closeHeldBy(target);
            host.concurrency_effect.releaseHeldBy(target);
            if (self.heap) |*heap| environment.abandonStream(heap) else return error.MissingDetachedHeap;
            self.heap = null;
            target.locals.allocator = null;
            if (!self.streams.finish(self.ticket)) return error.InvalidLease;
            target.destroy();
            self.target = null;
            std.debug.print("cancelled-request\n", .{});
            return;
        }
        if (!target.finished) {
            // Only deadline waits are part of this fixture's contract.
            if (target.wait.socket != -1) return error.UnexpectedSocketWait;
            if (self.heap == null) {
                self.heap = try environment.detachRequest();
                std.debug.print("detached-request\n", .{});
                try environment.resetRequest();
                self.allocator = environment.streamHostAllocator(&self.heap.?);
            }
            try self.waits.addWaiting(target);
            self.registered = true;
            std.debug.print("registered-wait\n", .{});
            return;
        }
        if (target.locals.allocator != null) return error.LeakedFiberContext;
        host.files_effect.closeHeldBy(target);
        host.concurrency_effect.releaseHeldBy(target);
        if (self.heap) |*heap| {
            if (!tracking and heap.heap.live_bytes != 0) return error.RequestLeak;
            try environment.releaseStream(heap);
            self.heap = null;
        } else {
            if (!tracking and environment.request_heap.live_bytes != 0) return error.RequestLeak;
            try environment.resetRequest();
        }
        if (self.failure != null) {
            rejected.* += 1;
            // A peer reset already closed this stream; do not cancel a reused ID.
            if (self.streams.leases.runningStream(self.ticket)) |id| try self.owner.cancel(id);
        } else {
            handled.* += 1;
        }
        if (!self.streams.finish(self.ticket)) return error.InvalidLease;
        target.destroy();
        self.target = null;
    }
};

// Protocol callbacks only invalidate leases. Wakes go through the production
// registry; only its ready list may resume a fiber or permit its destruction.
fn cancelClosed(jobs: *[16]Job, waits: *scheduler.Waits, environment: *Environment, handled: *usize, rejected: *usize) !void {
    for (jobs) |*job| {
        const target = job.target orelse continue;
        if (job.streams.leases.runningStream(job.ticket) != null) continue;
        if (!job.registered) return error.UnregisteredCancellation;
        host.fiber_wait.wakeStopped(target, target.wait_serial, fiber.Stop.client_gone);
    }
    try runReady(waits, environment, handled, rejected, false);
    for (jobs) |*job| {
        if (job.target != null and job.streams.leases.runningStream(job.ticket) == null) return error.CancellationDidNotStop;
    }
}

fn runReady(waits: *scheduler.Waits, environment: *Environment, handled: *usize, rejected: *usize, block: bool) !void {
    var ready: std.ArrayList(*fiber.Fiber) = .empty;
    defer ready.deinit(std.heap.smp_allocator);
    // At most sixteen stream jobs can wait. Reserve before the registry removes
    // entries so appending a ready fiber cannot lose it to allocation failure.
    try ready.ensureTotalCapacity(std.heap.smp_allocator, 16);
    var raw: [16]poller_backend.RawEvent = undefined;
    var events: [16 * poller_backend.events_per_raw]poller_backend.Event = undefined;
    const timeout = if (block) waits.beginBlockingWait(try host.net.monotonicNanoseconds()) else @as(?u32, 0);
    const reported = waits.poller.wait(&raw, &events, timeout) catch |err| {
        if (block) waits.endBlockingWait();
        return err;
    };
    if (block) waits.endBlockingWait();
    for (reported) |event| {
        // This fixture currently registers only deadline waits and owner wakes.
        if (event.kind != poller_backend.Event.Kind.wake) return error.UnexpectedSocketEvent;
        std.debug.print("poller-wake\n", .{});
    }
    try waits.collectExpired(try host.net.monotonicNanoseconds(), &ready);
    for (ready.items) |target| {
        const job: *Job = @ptrCast(@alignCast(target.userdata.?));
        if (!job.registered or job.target != target) return error.InvalidReadyJob;
        // A slot may be reused by an earlier resumed job from this batch.
        if (waits.slots.items[target.wait.slot]) |entry| {
            if (entry.target == target) return error.ResumeWhileRegistered;
        }
        job.registered = false;
        std.debug.print("collected-wait\n", .{});
        try job.resumeJob(environment, handled, rejected);
    }
}

// Empty records let the real poller drive every remaining deadline to completion.
fn drainJobs(waits: *scheduler.Waits, environment: *Environment, handled: *usize, rejected: *usize) !void {
    while (waits.hasWaiting()) try runReady(waits, environment, handled, rejected, true);
}

fn main() callconv(std.builtin.CallingConvention.c) c_int {
    run() catch |err| {
        std.debug.print("HTTP/2 Roc fixture failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run() !void {
    var environment = if (tracking) Environment.init(std.heap.smp_allocator) else Environment.production();
    defer environment.deinit();
    var allocator = environment.hostAllocator();
    var roc_host = host.runtime.makeRocHost(&environment);
    var app = try initialize(&allocator, &roc_host);
    defer {
        context.setCurrent(.{ .host_allocator = &allocator, .domain = host.Domain.persistent, .generation = environment.generation });
        app.model_root.deinit();
        // The fixture model contains only scalar values, so releasing its final box
        // must return the persistent tracker to zero as well.
        if (tracking) std.debug.assert(environment.persistent.liveCount() == 0);
        context.clearCurrent();
        for (app.listen_options.routes) |route| std.heap.smp_allocator.free(route);
        std.heap.smp_allocator.free(app.listen_options.routes);
    }
    try environment.capturePersistentBaseline();
    var state: State = .{};
    state.streams = h2.streams.Streams.init(1, &state.budget, .{ .header_bytes = 4096, .body_bytes = 4096 });
    defer state.streams.disconnect();
    const engine = try h2.engine.Engine.create(std.heap.smp_allocator, .{}, .{
        .context = &state,
        .header = State.header,
        .headers_complete = State.headersComplete,
        .data = State.data,
        .end = State.end,
        .closed = State.closed,
    });
    defer engine.destroy();
    // The transport owner remains byte-driven; the separate poller below drives
    // application waits, not HTTP/2 socket I/O.
    var owner = h2.owner.Owner{ .engine = engine, .socket = -1, .poller = undefined, .token = 1 };
    var handled: usize = 0;
    var rejected: usize = 0;
    var jobs: [16]Job = @splat(.{});
    var poller = try poller_backend.Poller.init();
    defer poller.deinit();
    try poller.registerWake(std.math.maxInt(u64) - 1);
    var waits = scheduler.Waits{ .poller = &poller };
    defer waits.deinit();
    if (host.fiber_wait.waits != null) return error.WaitRegistryAlreadyInstalled;
    host.fiber_wait.waits = &waits;
    defer host.fiber_wait.waits = null;
    var record: [65536]u8 = undefined;
    while (true) {
        var prefix: [4]u8 = undefined;
        if (!try readExact(&prefix)) break;
        const length = std.mem.readInt(u32, &prefix, std.builtin.Endian.big);
        if (length > record.len) return error.RecordTooLarge;
        if (length > 0 and !try readExact(record[0..length])) return error.TruncatedRecord;
        try engine.receive(record[0..length]);
        if (state.failed) return error.ObserverFailed;
        try cancelClosed(&jobs, &waits, &environment, &handled, &rejected);
        while (state.streams.next()) |work| {
            switch (work) {
                h2.streams.Work.cancel => |id| try owner.cancel(id),
                h2.streams.Work.execute => |execution| {
                    const job = &jobs[execution.ticket.slot];
                    if (job.target != null) return error.ReusedRunningSlot;
                    job.* = .{
                        .target = try fiber.Fiber.create(),
                        .waits = &waits,
                        .owner = &owner,
                        .streams = &state.streams,
                        .ticket = execution.ticket,
                        .model = &app.model_root,
                        .allocator = environment.hostAllocator(),
                        .generation = environment.generation,
                    };
                    job.roc_host = host.runtime.makeRocHost(@ptrCast(&job.allocator));
                    job.target.?.prepare(Job.start, job);
                    try job.resumeJob(&environment, &handled, &rejected);
                },
            }
        }
        if (length == 0) try drainJobs(&waits, &environment, &handled, &rejected);
        // Collection after serialization can finish a timer and submit another
        // response. Flush it before waiting for the next input record.
        while (true) {
            while (true) {
                const bytes = try engine.output();
                if (bytes.len == 0) break;
                try writeAll(bytes);
                try engine.consumeOutput(bytes.len);
            }
            try cancelClosed(&jobs, &waits, &environment, &handled, &rejected);
            if ((try engine.output()).len == 0) break;
        }
    }
    state.streams.disconnect();
    try cancelClosed(&jobs, &waits, &environment, &handled, &rejected);
    try drainJobs(&waits, &environment, &handled, &rejected);
    if (waits.hasWaiting()) return error.WaitRegistryLeak;
    for (jobs) |job| {
        if (job.target != null or job.registered) return error.LiveJobAtShutdown;
    }
    if (state.budget.used != 0) return error.InputLeak;
    if (host.request_memory.current() != 0) return error.RequestLeak;
    std.debug.print("handled={d} rejected={d}\n", .{ handled, rejected });
}

fn initialize(allocator: *host.HostAllocator, roc_host: *bridge.RocHost) !bridge.Application {
    context.setCurrent(.{ .host_allocator = allocator, .domain = host.Domain.persistent, .generation = 0 });
    defer context.clearCurrent();
    const result = bridge.rocInit();
    if (result.tag != bridge.InitResultTag.Ok) {
        result.decref(roc_host);
        return error.StartupFailed;
    }
    return bridge.Application.initOwned(result.payload_ok(), roc_host);
}

fn execute(owner: *h2.owner.Owner, streams: *h2.streams.Streams, ticket: h2.streams.Ticket, model: *bridge.ModelRoot, allocator: *host.HostAllocator, roc_host: *bridge.RocHost, generation: usize) !void {
    context.setCurrent(.{ .host_allocator = allocator, .domain = host.Domain.request, .generation = generation });
    defer context.clearCurrent();
    const request = try owner.requestOwned(streams, ticket, bridge.RemoteAddress.unix, "live-roc-request", .{ .roc_host = roc_host, .try_alloc = host.runtime.tryAllocWithHost });
    const semantics = if (request.method == bridge.HttpMethod.head) bridge.ResponseRequestSemantics.head else bridge.ResponseRequestSemantics.regular;
    const answered = bridge.rocHandle(model.retainForHandle(), request);
    defer answered.route.decref(roc_host);
    try owner.respondOwned(streams, ticket, answered.response, roc_host, semantics);
}

fn readExact(bytes: []u8) !bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.read(0, bytes.ptr + offset, bytes.len - offset);
        if (count < 0) return error.ReadFailed;
        if (count == 0) {
            if (offset != 0) return error.TruncatedRecord;
            return false;
        }
        offset += @intCast(count);
    }
    return true;
}

fn writeAll(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.write(1, bytes.ptr + offset, bytes.len - offset);
        if (count <= 0) return error.WriteFailed;
        offset += @intCast(count);
    }
}
