const std = @import("std");
const host_allocator = @import("host_allocator");

const Domain = host_allocator.Domain;
const HostAllocator = host_allocator.HostAllocator;

test "HostAllocator.alloc rejects invalid inputs" {
    var host = HostAllocator{
        .persistent_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
    };

    try std.testing.expectEqual(
        @as(?*anyopaque, null),
        host.alloc(Domain.persistent, 0, 1, 0),
    );
    try std.testing.expectEqual(
        @as(?*anyopaque, null),
        host.alloc(Domain.persistent, 0, 1, 3),
    );

    const alignment = 2 * @sizeOf(usize);
    const overflow_length =
        std.math.maxInt(usize) - alignment + 1;

    try std.testing.expectEqual(
        @as(?*anyopaque, null),
        host.alloc(
            Domain.persistent,
            0,
            overflow_length,
            alignment,
        ),
    );
}

test "HostAllocator.dealloc uses stored domain" {
    var persistent_storage: [128]u8 align(32) = undefined;
    var request_storage: [128]u8 align(32) = undefined;

    var persistent_fba = std.heap.FixedBufferAllocator.init(
        persistent_storage[0..],
    );
    var request_fba = std.heap.FixedBufferAllocator.init(
        request_storage[0..],
    );

    var host = HostAllocator{
        .persistent_allocator = persistent_fba.allocator(),
        .request_allocator = request_fba.allocator(),
    };

    const length: usize = 24;
    const alignment: usize = 16;

    const ptr = host.alloc(
        Domain.request,
        0,
        length,
        alignment,
    ) orelse return error.OutOfMemory;

    try std.testing.expect(
        request_fba.end_index > 0,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        persistent_fba.end_index,
    );

    host.dealloc(ptr, alignment);

    try std.testing.expectEqual(
        @as(usize, 0),
        request_fba.end_index,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        persistent_fba.end_index,
    );
}

test "HostAllocator.realloc grows and preserves stored domain" {
    var persistent_storage: [128]u8 align(32) = undefined;
    var persistent_fba = std.heap.FixedBufferAllocator.init(
        persistent_storage[0..],
    );

    var host = HostAllocator{
        .persistent_allocator = persistent_fba.allocator(),
        .request_allocator = std.testing.allocator,
    };

    const old_length: usize = 8;
    const new_length: usize = old_length + 1;
    const alignment: usize = 16;

    const old_ptr = host.alloc(
        Domain.request,
        9,
        old_length,
        alignment,
    ) orelse return error.OutOfMemory;

    const old_bytes: [*]u8 = @ptrCast(old_ptr);
    @memcpy(old_bytes[0..old_length], "roxum123");

    const new_ptr = host.realloc(
        old_ptr,
        new_length,
        alignment,
    ) orelse {
        host.dealloc(old_ptr, alignment);
        return error.OutOfMemory;
    };
    defer host.dealloc(new_ptr, alignment);

    const new_bytes: [*]const u8 = @ptrCast(new_ptr);

    try std.testing.expectEqualStrings(
        "roxum123",
        new_bytes[0..old_length],
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        persistent_fba.end_index,
    );
}

test "HostAllocator.realloc shrinks and preserves stored domain" {
    var request_storage: [128]u8 align(32) = undefined;
    var request_fba = std.heap.FixedBufferAllocator.init(
        request_storage[0..],
    );

    var host = HostAllocator{
        .persistent_allocator = std.testing.allocator,
        .request_allocator = request_fba.allocator(),
    };

    const old_length: usize = 9;
    const new_length: usize = old_length - 1;
    const alignment: usize = 16;

    const old_ptr = host.alloc(
        Domain.persistent,
        4,
        old_length,
        alignment,
    ) orelse return error.OutOfMemory;

    const old_bytes: [*]u8 = @ptrCast(old_ptr);
    @memcpy(old_bytes[0..old_length], "roxum1234");

    const new_ptr = host.realloc(
        old_ptr,
        new_length,
        alignment,
    ) orelse {
        host.dealloc(old_ptr, alignment);
        return error.OutOfMemory;
    };
    defer host.dealloc(new_ptr, alignment);

    const new_bytes: [*]const u8 = @ptrCast(new_ptr);

    try std.testing.expectEqualStrings(
        "roxum123",
        new_bytes[0..new_length],
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        request_fba.end_index,
    );
}

test "HostAllocator.realloc preserves data at equal-size boundary" {
    var host = HostAllocator{
        .persistent_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
    };

    const length: usize = 8;
    const alignment: usize = 16;

    const old_ptr = host.alloc(
        Domain.request,
        3,
        length,
        alignment,
    ) orelse return error.OutOfMemory;

    const old_bytes: [*]u8 = @ptrCast(old_ptr);
    @memcpy(old_bytes[0..length], "roxum123");

    const new_ptr = host.realloc(
        old_ptr,
        length,
        alignment,
    ) orelse {
        host.dealloc(old_ptr, alignment);
        return error.OutOfMemory;
    };
    defer host.dealloc(new_ptr, alignment);

    const new_bytes: [*]const u8 = @ptrCast(new_ptr);

    try std.testing.expectEqualStrings(
        "roxum123",
        new_bytes[0..length],
    );
}

test "HostAllocator.realloc keeps old allocation on OOM" {
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{
            .fail_index = 1,
        },
    );

    var host = HostAllocator{
        .persistent_allocator = std.testing.allocator,
        .request_allocator = failing_allocator.allocator(),
    };

    const old_length: usize = 8;
    // Far past the old block's size class, so it cannot grow in place and
    // the failing allocation is reached.
    const new_length: usize = 64 * 1024;
    const alignment: usize = 16;

    const old_ptr = host.alloc(
        Domain.request,
        6,
        old_length,
        alignment,
    ) orelse return error.UnexpectedOutOfMemory;
    defer host.dealloc(old_ptr, alignment);

    const old_bytes: [*]u8 = @ptrCast(old_ptr);
    @memcpy(old_bytes[0..old_length], "roxum123");

    const result = host.realloc(
        old_ptr,
        new_length,
        alignment,
    );

    try std.testing.expectEqual(
        @as(?*anyopaque, null),
        result,
    );
    try std.testing.expect(
        failing_allocator.has_induced_failure,
    );
    try std.testing.expectEqualStrings(
        "roxum123",
        old_bytes[0..old_length],
    );
}

test "HostAllocator lifecycle supports required alignments" {
    var host = HostAllocator{
        .persistent_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
    };

    const alignments = [_]usize{
        1,
        2,
        4,
        8,
        16,
        32,
    };

    for (alignments) |alignment| {
        const old_length: usize = 8;
        const new_length: usize = old_length + 1;

        const old_ptr = host.alloc(
            Domain.request,
            11,
            old_length,
            alignment,
        ) orelse return error.OutOfMemory;

        const old_bytes: [*]u8 = @ptrCast(old_ptr);
        @memset(old_bytes[0..old_length], 0xA5);

        const new_ptr = host.realloc(
            old_ptr,
            new_length,
            alignment,
        ) orelse {
            host.dealloc(old_ptr, alignment);
            return error.OutOfMemory;
        };
        defer host.dealloc(new_ptr, alignment);

        try std.testing.expectEqual(
            @as(usize, 0),
            @intFromPtr(new_ptr) % alignment,
        );
        const new_bytes: [*]const u8 = @ptrCast(new_ptr);

        for (new_bytes[0..old_length]) |byte| {
            try std.testing.expectEqual(
                @as(u8, 0xA5),
                byte,
            );
        }
    }
}

test "HostAllocator.realloc grows in place when the backing block has room" {
    var host = HostAllocator{
        .persistent_allocator = std.testing.allocator,
        .request_allocator = std.heap.page_allocator,
    };
    const alignment: usize = 16;
    const old_ptr = host.alloc(Domain.request, 1, 8, alignment) orelse return error.UnexpectedOutOfMemory;
    const old_bytes: [*]u8 = @ptrCast(old_ptr);
    @memcpy(old_bytes[0..8], "roxum123");

    // A page allocation spans a whole page, so 9 and 1024 bytes fit where it is.
    for ([_]usize{ 9, 1024 }) |length| {
        const grown = host.realloc(old_ptr, length, alignment) orelse return error.UnexpectedOutOfMemory;
        try std.testing.expectEqual(old_ptr, grown);
        try std.testing.expectEqualStrings("roxum123", old_bytes[0..8]);
    }
    host.dealloc(old_ptr, alignment);
}
