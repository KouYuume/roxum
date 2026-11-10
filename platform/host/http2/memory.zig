//! A bounded connection allocation domain for the engine's C allocator hooks.
//! Prefixes account for sizes and alignment; request arenas are never borrowed.
const std = @import("std");
const alignment = std.mem.Alignment.fromByteUnits(16);
const prefix_size = 16;

pub const Memory = struct {
    backing: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    peak: usize = 0,

    pub fn allocate(self: *Memory, size: usize) ?*anyopaque {
        const total = std.math.add(usize, size, prefix_size) catch return null;
        if (total > self.limit - self.used) return null;
        const allocation = self.backing.rawAlloc(total, alignment, @returnAddress()) orelse return null;
        const stored: *usize = @ptrCast(@alignCast(allocation));
        stored.* = total;
        self.used += total;
        self.peak = @max(self.peak, self.used);
        return allocation + prefix_size;
    }

    pub fn release(self: *Memory, ptr: ?*anyopaque) void {
        const data: [*]u8 = @ptrCast(ptr orelse return);
        const allocation = data - prefix_size;
        const stored: *const usize = @ptrCast(@alignCast(allocation));
        const total = stored.*;
        self.used -= total;
        self.backing.rawFree(allocation[0..total], alignment, @returnAddress());
    }

    pub fn resize(self: *Memory, ptr: ?*anyopaque, size: usize) ?*anyopaque {
        if (ptr == null) return self.allocate(size);
        if (size == 0) {
            self.release(ptr);
            return null;
        }
        const old: [*]u8 = @ptrCast(ptr.?);
        const total: *const usize = @ptrCast(@alignCast(old - prefix_size));
        const old_size = total.* - prefix_size;
        // Both allocations count while copying. Failure leaves the old one intact.
        const replacement = self.allocate(size) orelse return null;
        @memcpy(@as([*]u8, @ptrCast(replacement))[0..@min(size, old_size)], old[0..@min(size, old_size)]);
        self.release(ptr);
        return replacement;
    }
};

test "allocation ceiling includes the prefix: below, at, and above" {
    for ([_]usize{ 31, 32, 33 }) |limit| {
        var memory = Memory{ .backing = std.testing.allocator, .limit = limit };
        const ptr = memory.allocate(16);
        try std.testing.expectEqual(limit >= 32, ptr != null);
        if (ptr) |p| {
            try std.testing.expectEqual(@as(usize, 0), @intFromPtr(p) % 16);
            try std.testing.expectEqual(@as(usize, 32), memory.used);
        }
        memory.release(ptr);
        try std.testing.expectEqual(@as(usize, 0), memory.used);
    }
}

test "failed growth preserves allocation and bytes; resize to zero frees" {
    var memory = Memory{ .backing = std.testing.allocator, .limit = 65 };
    const ptr = memory.allocate(16).?;
    @memset(@as([*]u8, @ptrCast(ptr))[0..16], 42);
    try std.testing.expect(memory.resize(ptr, 18) == null);
    try std.testing.expectEqual(@as(usize, 32), memory.used);
    const moved = memory.resize(ptr, 17).?;
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(42)), @as([*]u8, @ptrCast(moved))[0..16]);
    try std.testing.expectEqual(@as(usize, 65), memory.peak);
    try std.testing.expect(memory.resize(moved, 0) == null);
    try std.testing.expectEqual(@as(usize, 0), memory.used);
    try std.testing.expect(memory.allocate(std.math.maxInt(usize)) == null);
}
