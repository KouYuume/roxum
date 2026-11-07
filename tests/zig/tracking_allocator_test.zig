const std = @import("std");
const host_allocator = @import("host_allocator");
const tracking_allocator = @import("tracking_allocator");

const Domain = host_allocator.Domain;
const HostAllocator = host_allocator.HostAllocator;
const TrackingAllocator = tracking_allocator.TrackingAllocator;

test "HostAllocator uses tracking allocators through the common interface" {
    var persistent_tracking = TrackingAllocator.init(
        std.testing.allocator,
    );
    defer persistent_tracking.deinit();

    var request_tracking = TrackingAllocator.init(
        std.testing.allocator,
    );
    defer request_tracking.deinit();

    var host = HostAllocator{
        .persistent_allocator = persistent_tracking.allocator(),
        .request_allocator = request_tracking.allocator(),
    };

    const old_length: usize = 8;
    const new_length: usize = old_length + 1;
    const alignment: usize = 16;

    const old_ptr = host.alloc(
        Domain.request,
        7,
        old_length,
        alignment,
    ) orelse return error.OutOfMemory;

    try std.testing.expectEqual(
        @as(usize, 0),
        persistent_tracking.live_count,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        request_tracking.live_count,
    );

    const new_ptr = host.realloc(
        old_ptr,
        new_length,
        alignment,
    ) orelse {
        host.dealloc(old_ptr, alignment);
        return error.OutOfMemory;
    };

    try std.testing.expectEqual(
        @as(usize, 1),
        request_tracking.live_count,
    );

    host.dealloc(new_ptr, alignment);

    try std.testing.expectEqual(
        @as(usize, 0),
        request_tracking.live_count,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        request_tracking.allocation_count,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        request_tracking.deallocation_count,
    );
}
