const std = @import("std");

pub const Prefix = struct {
    pub fn byteLength(alignment: usize) usize {
        return @max(alignment, 2 * @sizeOf(usize));
    }

    pub fn backingAlignment(alignment: usize) std.mem.Alignment {
        return std.mem.Alignment.fromByteUnits(
            @max(alignment, @alignOf(usize)),
        );
    }

    pub fn storedTotalSize(ptr: *const anyopaque) usize {
        const size_ptr: *const usize = @ptrFromInt(
            @intFromPtr(ptr) - @sizeOf(usize),
        );
        return size_ptr.*;
    }

    pub fn storedMeta(ptr: *const anyopaque) usize {
        const meta_ptr: *const usize = @ptrFromInt(
            @intFromPtr(ptr) - (2 * @sizeOf(usize)),
        );
        return meta_ptr.*;
    }

    pub fn basePtr(ptr: *anyopaque, alignment: usize) [*]u8 {
        return @ptrFromInt(
            @intFromPtr(ptr) - byteLength(alignment),
        );
    }

    pub fn write(
        base_ptr: [*]u8,
        alignment: usize,
        total_size: usize,
        meta: usize,
    ) *anyopaque {
        const prefix_length = byteLength(alignment);
        const user_address = @intFromPtr(base_ptr) + prefix_length;

        const meta_ptr: *usize = @ptrFromInt(
            user_address - 2 * @sizeOf(usize),
        );
        meta_ptr.* = meta;

        const size_ptr: *usize = @ptrFromInt(
            user_address - @sizeOf(usize),
        );
        size_ptr.* = total_size;

        return @ptrFromInt(user_address);
    }
};

test "Prefix.byteLength handles alignment boundaries" {
    try std.testing.expectEqual(
        @as(usize, 16),
        Prefix.byteLength(1),
    );
    try std.testing.expectEqual(
        @as(usize, 16),
        Prefix.byteLength(8),
    );
    try std.testing.expectEqual(
        @as(usize, 16),
        Prefix.byteLength(16),
    );
    try std.testing.expectEqual(
        @as(usize, 32),
        Prefix.byteLength(32),
    );
}

test "Prefix.backingAlignment handles usize alignment boundaries" {
    try std.testing.expectEqual(
        @as(usize, 8),
        Prefix.backingAlignment(1).toByteUnits(),
    );
    try std.testing.expectEqual(
        @as(usize, 8),
        Prefix.backingAlignment(4).toByteUnits(),
    );
    try std.testing.expectEqual(
        @as(usize, 8),
        Prefix.backingAlignment(8).toByteUnits(),
    );
    try std.testing.expectEqual(
        @as(usize, 16),
        Prefix.backingAlignment(16).toByteUnits(),
    );
}

test "Prefix.storedTotalSize reads the word immediately before user data" {
    const Fixture = extern struct {
        meta: usize,
        total_size: usize,
        user_data: [16]u8,
    };

    var fixture: Fixture = .{
        .meta = 0,
        .total_size = 104,
        .user_data = undefined,
    };

    const user_ptr: *const anyopaque = @ptrCast(
        &fixture.user_data,
    );

    try std.testing.expectEqual(
        @as(usize, 104),
        Prefix.storedTotalSize(user_ptr),
    );
}

test "Prefix.storedMeta reads the metadata word before user data" {
    const Fixture = extern struct {
        meta: usize,
        total_size: usize,
        user_data: [16]u8,
    };

    var fixture: Fixture = .{
        .meta = 11,
        .total_size = 104,
        .user_data = undefined,
    };

    const user_ptr: *const anyopaque = @ptrCast(
        &fixture.user_data,
    );

    try std.testing.expectEqual(
        @as(usize, 11),
        Prefix.storedMeta(user_ptr),
    );
}

test "Prefix.basePtr restores base across prefix alignment boundary" {
    var storage: [64]u8 align(32) = undefined;
    const base_address = @intFromPtr(&storage);

    for ([_]usize{ 8, 16, 32 }) |alignment| {
        const user_ptr: *anyopaque = @ptrFromInt(
            base_address + Prefix.byteLength(alignment),
        );

        const recovered_base = Prefix.basePtr(
            user_ptr,
            alignment,
        );

        try std.testing.expectEqual(
            base_address,
            @intFromPtr(recovered_base),
        );
    }
}

test "Prefix.write round trips layout across alignment boundary" {
    var storage: [64]u8 align(32) = undefined;
    const base = storage[0..].ptr;
    const base_address = @intFromPtr(base);

    for ([_]usize{ 8, 16, 32 }) |alignment| {
        const total_size = Prefix.byteLength(alignment) + 24;
        const test_meta: usize = 15;

        const user_ptr = Prefix.write(
            base,
            alignment,
            total_size,
            test_meta,
        );

        try std.testing.expectEqual(
            @as(usize, 0),
            @intFromPtr(user_ptr) % alignment,
        );
        try std.testing.expectEqual(
            total_size,
            Prefix.storedTotalSize(user_ptr),
        );

        try std.testing.expectEqual(
            test_meta,
            Prefix.storedMeta(user_ptr),
        );
        try std.testing.expectEqual(
            base_address,
            @intFromPtr(Prefix.basePtr(user_ptr, alignment)),
        );
    }
}
