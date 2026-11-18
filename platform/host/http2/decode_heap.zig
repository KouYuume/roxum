//! One message owns its heap until its last decoded value is released or the
//! request is abandoned. The worker budget outlives every message.
const std = @import("std");
const worker_memory = @import("worker_memory.zig");
const RequestHeap = @import("../allocator/request_heap.zig").RequestHeap;

pub const DecodeHeap = struct {
    const message_limit = 8 * 1024 * 1024;
    budget: worker_memory.Budget,
    heap: RequestHeap,

    pub fn create() !*DecodeHeap {
        return createWithBudget(&worker_memory.shared, message_limit);
    }

    fn createWithBudget(worker: *worker_memory.Budget, limit: usize) !*DecodeHeap {
        const backing = worker.allocator();
        const self = try backing.create(DecodeHeap);
        self.budget = .{ .backing = backing, .limit = limit };
        // The uncached heap returns its full allocation, including metadata,
        // to both budgets on free. No cached pages can cross budget domains.
        self.heap = RequestHeap.init(self.budget.allocator());
        return self;
    }

    pub fn allocator(self: *DecodeHeap) std.mem.Allocator {
        return self.heap.allocator();
    }

    pub fn destroy(self: *DecodeHeap) void {
        const backing = self.budget.backing;
        self.heap.deinit();
        std.debug.assert(self.budget.used.load(std.builtin.AtomicOrder.monotonic) == 0);
        backing.destroy(self);
    }
};

test "retained decoded values and transport allocations compete for one worker budget" {
    var worker = worker_memory.Budget{ .backing = std.testing.allocator, .limit = 4096 };
    const first = try DecodeHeap.createWithBudget(&worker, 512);
    defer first.destroy();
    const before_second = worker.used.load(std.builtin.AtomicOrder.monotonic);
    const second = try DecodeHeap.createWithBudget(&worker, 512);
    var second_live = true;
    defer if (second_live) second.destroy();
    const retained = try first.allocator().alloc(u8, 64);
    const charge = first.budget.used.load(std.builtin.AtomicOrder.monotonic);
    const remaining = worker.limit - worker.used.load(std.builtin.AtomicOrder.monotonic);
    const transport = try worker.allocator().alloc(u8, remaining);
    defer worker.allocator().free(transport);
    try std.testing.expectError(error.OutOfMemory, second.allocator().alloc(u8, 64));
    try std.testing.expectEqual(@as(usize, 0), second.budget.used.load(std.builtin.AtomicOrder.monotonic));
    first.allocator().free(retained);
    _ = try second.allocator().alloc(u8, 64);
    try std.testing.expectEqual(charge, second.budget.used.load(std.builtin.AtomicOrder.monotonic));
    // Destroy with a live value while transport still owns its entire allocation.
    second.destroy();
    second_live = false;
    try std.testing.expectEqual(before_second + remaining, worker.used.load(std.builtin.AtomicOrder.monotonic));
    const recovered = try worker.allocator().alloc(u8, worker.limit - before_second - remaining);
    defer worker.allocator().free(recovered);
    try std.testing.expectError(error.OutOfMemory, worker.allocator().alloc(u8, 1));
}

test "Roc realloc charges both buffers and preserves the old value on refusal" {
    const host = @import("../allocator/host_allocator.zig");
    var worker = worker_memory.Budget{ .backing = std.testing.allocator, .limit = 4096 };
    // Measure the heap and ABI headers using the same layout as the runtime.
    const probe = try DecodeHeap.createWithBudget(&worker, 512);
    var probe_host = host.HostAllocator{ .persistent_allocator = std.testing.allocator, .request_allocator = probe.allocator() };
    _ = probe_host.alloc(host.Domain.request, 0, 16, 8) orelse return error.OutOfMemory;
    _ = probe_host.alloc(host.Domain.request, 0, 32, 8) orelse return error.OutOfMemory;
    const peak = probe.budget.used.load(std.builtin.AtomicOrder.monotonic);
    probe.destroy();

    for ([_]usize{ peak - 1, peak, peak + 1 }) |limit| {
        const message = try DecodeHeap.createWithBudget(&worker, limit);
        defer message.destroy();
        var allocator = host.HostAllocator{ .persistent_allocator = std.testing.allocator, .request_allocator = message.allocator() };
        const ptr = allocator.alloc(host.Domain.request, 0, 16, 8) orelse return error.OutOfMemory;
        @memset(@as([*]u8, @ptrCast(ptr))[0..16], 42);
        const moved = allocator.realloc(ptr, 32, 8);
        try std.testing.expectEqual(limit >= peak, moved != null);
        try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(42)), @as([*]u8, @ptrCast(moved orelse ptr))[0..16]);
    }
    try std.testing.expectEqual(@as(usize, 0), worker.used.load(std.builtin.AtomicOrder.monotonic));
}

test "default message ceiling includes heap bookkeeping at the 8 MiB boundary" {
    const message = try DecodeHeap.create();
    defer message.destroy();
    const allocator = message.allocator();
    const probe = try allocator.alloc(u8, 1);
    const overhead = message.budget.used.load(std.builtin.AtomicOrder.monotonic) - 1;
    allocator.free(probe);

    const maximum_payload = 8 * 1024 * 1024 - overhead;
    for ([_]usize{ maximum_payload - 1, maximum_payload }) |size| {
        const bytes = try allocator.alloc(u8, size);
        allocator.free(bytes);
    }
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, maximum_payload + 1));
}
