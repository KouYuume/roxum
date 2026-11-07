const std = @import("std");
const host_allocator_module = @import("host_allocator.zig");
const fiber = @import("../fiber.zig");

const Domain = host_allocator_module.Domain;
const HostAllocator = host_allocator_module.HostAllocator;

pub const Context = struct {
    host_allocator: *HostAllocator,
    domain: Domain,
    generation: usize,
};

/// The context of code off a fiber (`init!`, stream steps), which never
/// moves to another thread. A request fiber keeps its own in its `Locals`.
threadlocal var thread_context: ?Context = null;

/// Where the running code's context lives: its fiber's, or this thread's.
fn slot() *?Context {
    if (fiber.currentLocals()) |locals| return &locals.allocator;
    return &thread_context;
}

pub fn setCurrent(context: Context) void {
    const place = slot();
    std.debug.assert(place.* == null);
    place.* = context;
}

pub fn clearCurrent() void {
    const place = slot();
    std.debug.assert(place.* != null);
    place.* = null;
}

pub fn current() ?Context {
    return slot().*;
}

test "allocator context follows scope lifecycle" {
    try std.testing.expectEqual(
        @as(?Context, null),
        current(),
    );

    var host_allocator = HostAllocator{
        .persistent_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
    };

    setCurrent(.{
        .host_allocator = &host_allocator,
        .domain = Domain.request,
        .generation = 7,
    });
    defer if (current() != null) clearCurrent();

    const active = current() orelse
        return error.ContextMissing;

    try std.testing.expectEqual(
        &host_allocator,
        active.host_allocator,
    );
    try std.testing.expectEqual(
        Domain.request,
        active.domain,
    );
    try std.testing.expectEqual(
        @as(usize, 7),
        active.generation,
    );

    clearCurrent();

    try std.testing.expectEqual(
        @as(?Context, null),
        current(),
    );
}
