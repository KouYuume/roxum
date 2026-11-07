const std = @import("std");
const host_allocator_module = @import("host_allocator.zig");
const RequestHeap = @import("request_heap.zig").RequestHeap;
const Meta = @import("meta.zig").Meta;

const Domain = host_allocator_module.Domain;
const HostAllocator = host_allocator_module.HostAllocator;

pub const ArenaEnvironment = struct {
    persistent_allocator: std.mem.Allocator,
    request_heap: RequestHeap,
    generation: usize = 0,

    /// Shared production/benchmark allocator policy; tests may inject a backing allocator.
    pub fn production() ArenaEnvironment {
        return .{
            .persistent_allocator = std.heap.smp_allocator,
            .request_heap = RequestHeap.initCached(std.heap.page_allocator),
        };
    }

    pub fn init(
        backing_allocator: std.mem.Allocator,
    ) ArenaEnvironment {
        return .{
            .persistent_allocator = backing_allocator,
            .request_heap = RequestHeap.init(
                backing_allocator,
            ),
        };
    }

    pub fn deinit(self: *ArenaEnvironment) void {
        self.request_heap.deinit();
    }

    pub fn workerClone(self: *const ArenaEnvironment) ArenaEnvironment {
        if (self.request_heap.cache_enabled) {
            return .{
                .persistent_allocator = self.persistent_allocator,
                .request_heap = RequestHeap.initCached(self.request_heap.backing),
            };
        }
        return ArenaEnvironment.init(self.persistent_allocator);
    }

    pub fn hostAllocator(
        self: *ArenaEnvironment,
    ) HostAllocator {
        return .{
            .persistent_allocator = self.persistent_allocator,
            .request_allocator = self.request_heap.allocator(),
        };
    }

    pub fn capturePersistentBaseline(
        self: *ArenaEnvironment,
    ) error{}!void {
        _ = self;
    }

    /// A streaming response's values after its request ended: the heap that
    /// holds them and the generation they were allocated in.
    pub const Stream = struct {
        heap: *RequestHeap,
        generation: usize,
    };

    /// Moves the current request's live values into a stream that outlives
    /// the request. Call before `resetRequest`; the request heap then starts
    /// the next request empty.
    pub fn detachRequest(self: *ArenaEnvironment) error{OutOfMemory}!Stream {
        const heap = try std.heap.smp_allocator.create(RequestHeap);
        heap.* = self.request_heap.detachLive();
        return .{ .heap = heap, .generation = self.generation };
    }

    /// The stream's values go on on the thread running this environment:
    /// its heap takes pages from and returns them to this thread's cache.
    /// Call before the thread uses the stream's heap.
    pub fn adoptStream(self: *ArenaEnvironment, stream: *Stream) void {
        stream.heap.useCacheOf(&self.request_heap);
    }

    /// The allocator a stream's producer runs with, on this thread.
    pub fn streamHostAllocator(self: *ArenaEnvironment, stream: *Stream) HostAllocator {
        self.adoptStream(stream);
        return .{
            .persistent_allocator = self.persistent_allocator,
            .request_allocator = stream.heap.allocator(),
        };
    }

    /// Frees whatever the stream still holds once it has ended.
    pub fn releaseStream(self: *ArenaEnvironment, stream: *Stream) error{}!void {
        self.adoptStream(stream);
        stream.heap.deinit();
        std.heap.smp_allocator.destroy(stream.heap);
    }

    /// Frees a crashed request's values, whatever it still held.
    pub fn abandonRequest(self: *ArenaEnvironment) error{GenerationExhausted}!void {
        return self.resetRequest();
    }

    /// Frees a crashed request's detached values.
    pub fn abandonStream(self: *ArenaEnvironment, stream: *Stream) void {
        self.releaseStream(stream) catch unreachable;
    }

    pub fn resetRequest(
        self: *ArenaEnvironment,
    ) error{GenerationExhausted}!void {
        if (self.generation >= Meta.max_generation) return error.GenerationExhausted;
        self.request_heap.reset();
        self.generation += 1;
    }
};

test "request reset preserves persistent allocations" {
    var environment = ArenaEnvironment.init(
        std.testing.allocator,
    );
    defer environment.deinit();

    var host_allocator = environment.hostAllocator();

    const length: usize = 5;
    const alignment: usize = 8;

    const persistent_ptr = host_allocator.alloc(
        Domain.persistent,
        environment.generation,
        length,
        alignment,
    ) orelse return error.OutOfMemory;
    defer host_allocator.dealloc(
        persistent_ptr,
        alignment,
    );

    const persistent_bytes: [*]u8 =
        @ptrCast(persistent_ptr);
    @memcpy(
        persistent_bytes[0..length],
        "roxum",
    );

    _ = host_allocator.alloc(
        Domain.request,
        environment.generation,
        length,
        alignment,
    ) orelse return error.OutOfMemory;

    try environment.resetRequest();

    try std.testing.expectEqual(
        @as(usize, 1),
        environment.generation,
    );
    try std.testing.expectEqualStrings(
        "roxum",
        persistent_bytes[0..length],
    );
}

test "worker clone starts with an independent empty request cache" {
    var environment = ArenaEnvironment.init(std.testing.allocator);
    environment.request_heap = RequestHeap.initCached(std.testing.allocator);
    defer environment.deinit();
    var host = environment.hostAllocator();
    _ = host.alloc(Domain.request, 0, 1, 8) orelse return error.OutOfMemory;
    try environment.resetRequest();
    try std.testing.expect(environment.request_heap.cached_bytes > 0);
    var worker = environment.workerClone();
    defer worker.deinit();
    try std.testing.expect(worker.request_heap.cache_enabled);
    try std.testing.expectEqual(@as(usize, 0), worker.request_heap.cached_bytes);
    try std.testing.expectEqual(@as(usize, 0), worker.request_heap.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), worker.generation);
}

test "request reset enforces generation boundary" {
    var environment = ArenaEnvironment.init(
        std.testing.allocator,
    );
    defer environment.deinit();

    // Immediately below the generation limit: the final reset succeeds.
    environment.generation =
        Meta.max_generation - 1;

    try environment.resetRequest();

    try std.testing.expectEqual(
        Meta.max_generation,
        environment.generation,
    );

    // At the generation limit: reset is rejected.
    try std.testing.expectError(
        error.GenerationExhausted,
        environment.resetRequest(),
    );
    try std.testing.expectEqual(
        Meta.max_generation,
        environment.generation,
    );

    // Above the generation limit: reject the invalid state without resetting.
    environment.generation =
        Meta.max_generation + 1;

    try std.testing.expectError(
        error.GenerationExhausted,
        environment.resetRequest(),
    );
    try std.testing.expectEqual(
        Meta.max_generation + 1,
        environment.generation,
    );
}

// A stream keeps its next producer alive while freeing its previous chunk.
// Increasing total chunks must not increase peak storage for that live set.
test "interleaved request allocations are bounded by live values" {
    for ([_]bool{ false, true }) |cached| {
        for ([_]usize{ 0, 1, 2, 1000 }) |chunks| {
            var environment = ArenaEnvironment.init(std.testing.allocator);
            if (cached) environment.request_heap = RequestHeap.initCached(std.testing.allocator);
            defer environment.deinit();
            var host = environment.hostAllocator();
            var producer = host.alloc(Domain.request, 0, 32, 8) orelse return error.OutOfMemory;
            for (0..chunks) |_| {
                const chunk = host.alloc(Domain.request, 0, 65536, 8) orelse return error.OutOfMemory;
                const next = host.alloc(Domain.request, 0, 32, 8) orelse return error.OutOfMemory;
                host.dealloc(producer, 8);
                host.dealloc(chunk, 8);
                producer = next;
                try std.testing.expect(environment.request_heap.live_bytes < 256);
            }
            host.dealloc(producer, 8);
            try std.testing.expectEqual(@as(usize, 0), environment.request_heap.live_bytes);
            try std.testing.expect(environment.request_heap.peak_bytes < 66000);
            try environment.resetRequest();
        }
    }
}

// Exhaustive supported alignment contract, including both sides of the
// metadata/header alignment boundaries. Reset also releases abandoned values.
test "request heap allocator lifecycle preserves every contract alignment" {
    for ([_]bool{ false, true }) |cached| {
        var environment = ArenaEnvironment.init(std.testing.allocator);
        if (cached) environment.request_heap = RequestHeap.initCached(std.testing.allocator);
        defer environment.deinit();
        var host = environment.hostAllocator();
        for ([_]usize{ 1, 2, 4, 8, 16, 32 }) |alignment| {
            const first = host.alloc(Domain.request, 0, 17, alignment) orelse return error.OutOfMemory;
            @memset(@as([*]u8, @ptrCast(first))[0..17], 42);
            const second = host.alloc(Domain.request, 0, 1, alignment) orelse return error.OutOfMemory;
            const grown = host.realloc(first, 33, alignment) orelse return error.OutOfMemory;
            try std.testing.expectEqual(@as(usize, 0), @intFromPtr(grown) % alignment);
            for (@as([*]u8, @ptrCast(grown))[0..17]) |byte| try std.testing.expectEqual(@as(u8, 42), byte);
            host.dealloc(second, alignment);
            host.dealloc(grown, alignment);
            _ = host.alloc(Domain.request, 0, 1, alignment) orelse return error.OutOfMemory;
        }
        try environment.resetRequest();
        try std.testing.expectEqual(@as(usize, 0), environment.request_heap.live_bytes);
    }
}
