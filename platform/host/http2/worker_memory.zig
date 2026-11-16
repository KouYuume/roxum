//! Shared ceiling for HTTP/2 transport storage across a worker's connections.
const std = @import("std");

pub const Budget = struct {
    backing: std.mem.Allocator = std.heap.smp_allocator,
    limit: usize = 128 * 1024 * 1024,
    used: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = release } };
    }

    fn allocate(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        var current = self.used.load(std.builtin.AtomicOrder.monotonic);
        while (true) {
            if (len > self.limit - current) return null;
            if (self.used.cmpxchgWeak(current, current + len, std.builtin.AtomicOrder.monotonic, std.builtin.AtomicOrder.monotonic)) |changed| {
                current = changed;
            } else break;
        }
        return self.backing.rawAlloc(len, alignment, address) orelse {
            _ = self.used.fetchSub(len, std.builtin.AtomicOrder.monotonic);
            return null;
        };
    }

    fn release(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.backing.rawFree(bytes, alignment, address);
        _ = self.used.fetchSub(bytes.len, std.builtin.AtomicOrder.monotonic);
    }
};

test "worker transport ceiling admits below and at the limit, rejects above, and returns capacity" {
    var budget = Budget{ .backing = std.testing.allocator, .limit = 16 };
    const allocator = budget.allocator();
    const below = try allocator.alloc(u8, 15);
    const at = try allocator.alloc(u8, 1);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    allocator.free(below);
    allocator.free(at);
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(std.builtin.AtomicOrder.monotonic));
    const whole = try allocator.alloc(u8, 16);
    allocator.free(whole);
}

test "backing allocation failure restores the worker budget" {
    var storage: [0]u8 = .{};
    var backing = std.heap.FixedBufferAllocator.init(&storage);
    var budget = Budget{ .backing = backing.allocator(), .limit = 16 };
    try std.testing.expectError(error.OutOfMemory, budget.allocator().alloc(u8, 1));
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(std.builtin.AtomicOrder.monotonic));
}
