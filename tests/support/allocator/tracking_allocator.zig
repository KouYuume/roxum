//! Test-only allocator instrumentation for ownership contract checks.

const std = @import("std");

const canary_size: usize = 16;
const canary_byte: u8 = 0xA5;
const poison_byte: u8 = 0xCC;

const Allocation = struct {
    raw: [*]u8,
    total_length: usize,
    user_length: usize,
    alignment: std.mem.Alignment,
};

pub const TrackingAllocator = struct {
    backing_allocator: std.mem.Allocator,
    allocations: std.AutoHashMap(usize, Allocation),

    allocation_count: usize = 0,
    requested_bytes: usize = 0,
    deallocation_count: usize = 0,
    live_count: usize = 0,

    canary_violations: usize = 0,
    invalid_frees: usize = 0,
    /// For a tracker of request values: reports each change of live bytes,
    /// so the worker's total (`host.request_memory`) follows it as it
    /// follows the production request heap.
    live_change: ?*const fn (grew: bool, bytes: usize) void = null,
    /// The persistent tracker is shared by every thread of the process
    ///, so each tracker takes a lock for its own bookkeeping.
    lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn init(
        backing_allocator: std.mem.Allocator,
    ) TrackingAllocator {
        return .{
            .backing_allocator = backing_allocator,
            .allocations = std.AutoHashMap(
                usize,
                Allocation,
            ).init(backing_allocator),
        };
    }

    /// Live allocations, read under the lock.
    pub fn liveCount(self: *TrackingAllocator) usize {
        _ = std.c.pthread_mutex_lock(&self.lock);
        defer _ = std.c.pthread_mutex_unlock(&self.lock);
        return self.live_count;
    }

    pub fn deinit(self: *TrackingAllocator) void {
        _ = std.c.pthread_mutex_lock(&self.lock);
        defer _ = std.c.pthread_mutex_unlock(&self.lock);
        var allocations = self.allocations.iterator();
        while (allocations.next()) |entry| {
            const allocation = entry.value_ptr.*;
            if (self.live_change) |change| change(false, allocation.user_length);
            self.backing_allocator.rawFree(
                allocation.raw[0..allocation.total_length],
                allocation.alignment,
                @returnAddress(),
            );
        }

        self.allocations.deinit();
    }

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocateMemory,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = freeMemory,
            },
        };
    }

    fn allocateMemory(
        context: *anyopaque,
        user_length: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(
            @alignCast(context),
        );
        _ = std.c.pthread_mutex_lock(&self.lock);
        defer _ = std.c.pthread_mutex_unlock(&self.lock);
        const total_length = checkedTotalLength(
            user_length,
            alignment,
        ) orelse return null;

        const raw = self.backing_allocator.rawAlloc(
            total_length,
            alignment,
            return_address,
        ) orelse return null;

        const user_address = std.mem.alignForward(
            usize,
            @intFromPtr(raw) + canary_size,
            alignment.toByteUnits(),
        );
        const user: [*]u8 = @ptrFromInt(user_address);

        self.allocations.put(
            user_address,
            .{
                .raw = raw,
                .total_length = total_length,
                .user_length = user_length,
                .alignment = alignment,
            },
        ) catch {
            self.backing_allocator.rawFree(
                raw[0..total_length],
                alignment,
                return_address,
            );
            return null;
        };

        @memset(
            (user - canary_size)[0..canary_size],
            canary_byte,
        );
        @memset(user[0..user_length], poison_byte);
        @memset(
            (user + user_length)[0..canary_size],
            canary_byte,
        );

        self.allocation_count += 1;
        self.requested_bytes += user_length;
        self.live_count += 1;
        if (self.live_change) |change| change(true, user_length);
        return user;
    }

    fn freeMemory(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *TrackingAllocator = @ptrCast(
            @alignCast(context),
        );
        _ = std.c.pthread_mutex_lock(&self.lock);
        defer _ = std.c.pthread_mutex_unlock(&self.lock);
        const removed = self.allocations.fetchRemove(
            @intFromPtr(memory.ptr),
        ) orelse {
            self.invalid_frees += 1;
            return;
        };
        const allocation = removed.value;

        if (memory.len != allocation.user_length or
            alignment != allocation.alignment)
        {
            self.invalid_frees += 1;
        }

        if (!canariesAreIntact(
            memory.ptr,
            allocation.user_length,
        )) {
            self.canary_violations += 1;
        }

        @memset(
            memory.ptr[0..allocation.user_length],
            poison_byte,
        );
        self.backing_allocator.rawFree(
            allocation.raw[0..allocation.total_length],
            allocation.alignment,
            return_address,
        );

        self.deallocation_count += 1;
        self.live_count -= 1;
        if (self.live_change) |change| change(false, allocation.user_length);
    }

    fn checkedTotalLength(
        user_length: usize,
        alignment: std.mem.Alignment,
    ) ?usize {
        const alignment_padding = alignment.toByteUnits() - 1;
        const canaries_length = 2 * canary_size;
        const overhead = std.math.add(
            usize,
            canaries_length,
            alignment_padding,
        ) catch return null;
        return std.math.add(
            usize,
            user_length,
            overhead,
        ) catch null;
    }

    fn canariesAreIntact(
        user: [*]const u8,
        user_length: usize,
    ) bool {
        for ((user - canary_size)[0..canary_size]) |byte| {
            if (byte != canary_byte) return false;
        }
        for ((user + user_length)[0..canary_size]) |byte| {
            if (byte != canary_byte) return false;
        }
        return true;
    }
};

test "tracking allocator lifecycle supports required alignments" {
    var tracking = TrackingAllocator.init(std.testing.allocator);
    defer tracking.deinit();

    const tracked_allocator = tracking.allocator();
    const alignments = [_]usize{ 1, 2, 4, 8, 16, 32 };

    for (alignments) |alignment_bytes| {
        const alignment = std.mem.Alignment.fromByteUnits(
            alignment_bytes,
        );
        const length: usize = 8;
        const memory = tracked_allocator.rawAlloc(
            length,
            alignment,
            @returnAddress(),
        ) orelse return error.OutOfMemory;

        try std.testing.expectEqual(
            @as(usize, 0),
            @intFromPtr(memory) % alignment_bytes,
        );
        for (memory[0..length]) |byte| {
            try std.testing.expectEqual(
                poison_byte,
                byte,
            );
        }

        tracked_allocator.rawFree(
            memory[0..length],
            alignment,
            @returnAddress(),
        );
    }

    try std.testing.expectEqual(
        alignments.len,
        tracking.allocation_count,
    );
    try std.testing.expectEqual(
        alignments.len,
        tracking.deallocation_count,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        tracking.live_count,
    );
}

test "tracking allocator detects both canary boundaries" {
    var tracking = TrackingAllocator.init(std.testing.allocator);
    defer tracking.deinit();

    const tracked_allocator = tracking.allocator();
    const alignment = std.mem.Alignment.fromByteUnits(16);
    const length: usize = 8;

    const prefix_corrupted = tracked_allocator.rawAlloc(
        length,
        alignment,
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    (prefix_corrupted - 1)[0] = 0;
    tracked_allocator.rawFree(
        prefix_corrupted[0..length],
        alignment,
        @returnAddress(),
    );

    const suffix_corrupted = tracked_allocator.rawAlloc(
        length,
        alignment,
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    suffix_corrupted[length] = 0;
    tracked_allocator.rawFree(
        suffix_corrupted[0..length],
        alignment,
        @returnAddress(),
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        tracking.canary_violations,
    );
}

test "tracking allocator rejects a double free without touching freed memory" {
    var tracking = TrackingAllocator.init(std.testing.allocator);
    defer tracking.deinit();

    const tracked_allocator = tracking.allocator();
    const alignment = std.mem.Alignment.fromByteUnits(8);
    const length: usize = 8;
    const memory = tracked_allocator.rawAlloc(
        length,
        alignment,
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    const allocation = memory[0..length];

    tracked_allocator.rawFree(
        allocation,
        alignment,
        @returnAddress(),
    );
    tracked_allocator.rawFree(
        allocation,
        alignment,
        @returnAddress(),
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        tracking.invalid_frees,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        tracking.live_count,
    );
}

test "tracking allocator exposes live allocations" {
    var tracking = TrackingAllocator.init(std.testing.allocator);
    defer tracking.deinit();

    const tracked_allocator = tracking.allocator();
    const alignment = std.mem.Alignment.fromByteUnits(8);

    _ = tracked_allocator.rawAlloc(
        8,
        alignment,
        @returnAddress(),
    ) orelse return error.OutOfMemory;

    try std.testing.expectEqual(
        @as(usize, 1),
        tracking.live_count,
    );
}

test "checkedTotalLength handles overflow boundary" {
    const alignment = std.mem.Alignment.fromByteUnits(16);
    const overhead = 2 * canary_size + 15;
    const maximum_user_length =
        std.math.maxInt(usize) - overhead;

    try std.testing.expectEqual(
        @as(?usize, std.math.maxInt(usize) - 1),
        TrackingAllocator.checkedTotalLength(
            maximum_user_length - 1,
            alignment,
        ),
    );
    try std.testing.expectEqual(
        @as(?usize, std.math.maxInt(usize)),
        TrackingAllocator.checkedTotalLength(
            maximum_user_length,
            alignment,
        ),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        TrackingAllocator.checkedTotalLength(
            maximum_user_length + 1,
            alignment,
        ),
    );
}
