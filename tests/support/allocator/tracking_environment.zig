const std = @import("std");
const host = @import("host");
const tracking_allocator_module = @import("tracking_allocator");

const HostAllocator = host.HostAllocator;
const Domain = host.Domain;
const TrackingAllocator = tracking_allocator_module.TrackingAllocator;

fn requestTracker(backing_allocator: std.mem.Allocator) TrackingAllocator {
    var tracker = TrackingAllocator.init(backing_allocator);
    tracker.live_change = changeRequestMemory;
    return tracker;
}

fn changeRequestMemory(grew: bool, bytes: usize) void {
    if (grew) host.request_memory.grow(bytes) else host.request_memory.shrink(bytes);
}

pub const Environment = struct {
    /// Shared by the environments of one process's threads; the
    /// first one owns it.
    persistent: *TrackingAllocator,
    owns_persistent: bool = true,
    request: TrackingAllocator,
    generation: usize = 0,
    persistent_baseline: ?usize = null,
    /// Set by `detachRequest`: the request's checks and marker move to the
    /// end of its stream.
    request_detached: bool = false,

    pub fn init(
        backing_allocator: std.mem.Allocator,
    ) Environment {
        const persistent = backing_allocator.create(TrackingAllocator) catch @panic("out of memory");
        persistent.* = TrackingAllocator.init(backing_allocator);
        return .{
            .persistent = persistent,
            .request = requestTracker(backing_allocator),
        };
    }

    pub fn deinit(self: *Environment) void {
        self.request.deinit();
        if (!self.owns_persistent) return;
        const backing = self.persistent.backing_allocator;
        self.persistent.deinit();
        backing.destroy(self.persistent);
    }

    /// Another thread's environment: its own request tracker, the same
    /// persistent tracker and baseline.
    pub fn workerClone(self: *const Environment) Environment {
        return .{
            .persistent = self.persistent,
            .owns_persistent = false,
            .persistent_baseline = self.persistent_baseline,
            .request = requestTracker(self.persistent.backing_allocator),
        };
    }

    pub fn hostAllocator(self: *Environment) HostAllocator {
        return .{
            .persistent_allocator = self.persistent.allocator(),
            .request_allocator = self.request.allocator(),
        };
    }

    pub fn capturePersistentBaseline(
        self: *Environment,
    ) error{
        BaselineAlreadyCaptured,
        RequestLeak,
    }!void {
        if (self.persistent_baseline != null) {
            return error.BaselineAlreadyCaptured;
        }
        if (self.request.live_count != 0) return error.RequestLeak;
        self.persistent_baseline = self.persistent.liveCount();
    }

    /// A streaming response's values after its request ended, tracked on
    /// their own so the request's leak check can run when the stream ends.
    pub const Stream = struct {
        tracker: *TrackingAllocator,
        generation: usize,
    };

    pub fn detachRequest(self: *Environment) error{OutOfMemory}!Stream {
        const tracker = try self.request.backing_allocator.create(TrackingAllocator);
        tracker.* = self.request;
        self.request = requestTracker(tracker.backing_allocator);
        self.request_detached = true;
        return .{ .tracker = tracker, .generation = self.generation };
    }

    /// A tracker keeps no cache, so it needs nothing to go on on another
    /// thread.
    pub fn adoptStream(self: *Environment, stream: *Stream) void {
        _ = self;
        _ = stream;
    }

    pub fn streamHostAllocator(self: *Environment, stream: *Stream) HostAllocator {
        return .{
            .persistent_allocator = self.persistent.allocator(),
            .request_allocator = stream.tracker.allocator(),
        };
    }

    /// The request checks `resetRequest` deferred: everything the stream
    /// allocated is freed, with intact canaries and only valid frees. Prints
    /// the request's marker.
    pub fn releaseStream(self: *Environment, stream: *Stream) error{ RequestLeak, CanaryViolation, InvalidFree }!void {
        const backing = self.request.backing_allocator;
        defer {
            stream.tracker.deinit();
            backing.destroy(stream.tracker);
        }
        if (stream.tracker.live_count != 0) return error.RequestLeak;
        if (stream.tracker.canary_violations != 0) return error.CanaryViolation;
        if (stream.tracker.invalid_frees != 0) return error.InvalidFree;
        self.reportRequest(stream.tracker);
    }

    fn reportRequest(self: *Environment, tracker: *TrackingAllocator) void {
        // Optional instrumentation belongs to the completed request's tracker,
        // including requests whose heap moved to a fiber or stream.
        if (comptime @hasDecl(@import("root"), "recordAllocations")) {
            @import("root").recordAllocations(tracker, self.persistent.liveCount());
        } else {
            std.debug.print("roxum-contract-request-ok\n", .{});
        }
    }

    /// Frees a crashed request's values without the leak checks, which a
    /// request cut off mid-way cannot pass; it prints no marker.
    pub fn abandonRequest(self: *Environment) error{GenerationExhausted}!void {
        if (self.generation >= host.max_generation) return error.GenerationExhausted;
        const backing = self.request.backing_allocator;
        self.request.deinit();
        self.request = requestTracker(backing);
        self.request_detached = false;
        self.generation += 1;
    }

    pub fn abandonStream(self: *Environment, stream: *Stream) void {
        const backing = self.request.backing_allocator;
        stream.tracker.deinit();
        backing.destroy(stream.tracker);
    }

    pub fn resetRequest(self: *Environment) error{
        RequestLeak,
        PersistentLeak,
        PersistentBaselineMissing,
        CanaryViolation,
        InvalidFree,
        GenerationExhausted,
    }!void {
        if (self.request.live_count != 0) return error.RequestLeak;
        const baseline = self.persistent_baseline orelse
            return error.PersistentBaselineMissing;
        if (self.persistent.liveCount() != baseline) {
            return error.PersistentLeak;
        }
        if (self.request.canary_violations != 0 or
            self.persistent.canary_violations != 0)
        {
            return error.CanaryViolation;
        }
        if (self.request.invalid_frees != 0 or
            self.persistent.invalid_frees != 0)
        {
            return error.InvalidFree;
        }
        if (self.generation >= host.max_generation) {
            return error.GenerationExhausted;
        }

        self.generation += 1;
        // A detached request reports when its stream ends.
        if (self.request_detached) {
            self.request_detached = false;
            return;
        }
        self.reportRequest(&self.request);
    }
};

test "tracking environment rejects live request allocations" {
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    try environment.capturePersistentBaseline();

    var runtime_allocator = environment.hostAllocator();
    const alignment: usize = 8;
    const pointer = runtime_allocator.alloc(
        Domain.request,
        environment.generation,
        8,
        alignment,
    ) orelse return error.OutOfMemory;

    try std.testing.expectError(
        error.RequestLeak,
        environment.resetRequest(),
    );

    runtime_allocator.dealloc(pointer, alignment);
    try environment.resetRequest();
}

test "tracking environment enforces generation boundary" {
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    try environment.capturePersistentBaseline();

    environment.generation =
        host.max_generation - 1;
    try environment.resetRequest();
    try std.testing.expectEqual(
        host.max_generation,
        environment.generation,
    );

    try std.testing.expectError(
        error.GenerationExhausted,
        environment.resetRequest(),
    );

    environment.generation =
        host.max_generation + 1;
    try std.testing.expectError(
        error.GenerationExhausted,
        environment.resetRequest(),
    );
}

test "a request detached on one thread ends on another, with that thread's environment" {
    var first = Environment.init(std.testing.allocator);
    defer first.deinit();
    try first.capturePersistentBaseline();
    var second = first.workerClone();
    defer second.deinit();

    // The request starts on the first thread and waits: its values move to
    // a stream of their own.
    var started = first.hostAllocator();
    const alignment: usize = 8;
    const kept = started.alloc(Domain.request, first.generation, 16, alignment) orelse return error.OutOfMemory;
    var stream = try first.detachRequest();
    try first.resetRequest();

    // It resumes on the second thread, allocates more, frees everything,
    // and ends there.
    const Resumed = struct {
        fn run(environment: *Environment, detached: *Environment.Stream, value: *anyopaque) !void {
            environment.adoptStream(detached);
            var allocator = environment.streamHostAllocator(detached);
            const more = allocator.alloc(Domain.request, detached.generation, 32, alignment) orelse return error.OutOfMemory;
            allocator.dealloc(more, alignment);
            allocator.dealloc(value, alignment);
            try environment.releaseStream(detached);
        }

        fn spawned(environment: *Environment, detached: *Environment.Stream, value: *anyopaque, result: *?anyerror) void {
            run(environment, detached, value) catch |err| {
                result.* = err;
            };
        }
    };
    var failure: ?anyerror = null;
    const thread = try std.Thread.spawn(.{}, Resumed.spawned, .{ &second, &stream, kept, &failure });
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), failure);
}

test "the persistent tracker counts allocations from every thread" {
    var first = Environment.init(std.testing.allocator);
    defer first.deinit();
    try first.capturePersistentBaseline();
    var second = first.workerClone();
    defer second.deinit();

    const Churn = struct {
        fn run(environment: *Environment) void {
            var allocator = environment.hostAllocator();
            for (0..500) |_| {
                const value = allocator.alloc(Domain.persistent, 0, 24, 8) orelse continue;
                allocator.dealloc(value, 8);
            }
        }
    };
    const other = try std.Thread.spawn(.{}, Churn.run, .{&second});
    Churn.run(&first);
    other.join();
    try std.testing.expectEqual(first.persistent_baseline.?, first.persistent.liveCount());
}
