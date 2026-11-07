const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const diagnostics = @import("diagnostics.zig");
const host_allocator = @import("allocator/host_allocator.zig");
const allocator_context = @import("allocator/context.zig");
const fiber_wait = @import("fiber_wait.zig");

/// Roc writes through the result without checking it, so running out of
/// memory stops the worker the same way `roc_crashed` does.
pub fn rocAlloc(
    length: usize,
    alignment: usize,
) callconv(std.builtin.CallingConvention.c) *anyopaque {
    return tryAlloc(length, alignment) orelse outOfMemory();
}

/// The allocator behind `rocAlloc`, without stopping on failure. The host
/// uses it for the Roc values it builds, so it can answer with an error.
pub fn tryAlloc(
    length: usize,
    alignment: usize,
) ?*anyopaque {
    const context = currentAllocatorContext();
    return context.host_allocator.alloc(
        context.domain,
        context.generation,
        length,
        alignment,
    );
}

pub fn rocDealloc(
    ptr: *anyopaque,
    alignment: usize,
) callconv(std.builtin.CallingConvention.c) void {
    const context = currentAllocatorContext();
    assertLiveGeneration(ptr, context.generation);
    context.host_allocator.dealloc(
        ptr,
        alignment,
    );
}

pub fn rocRealloc(
    ptr: *anyopaque,
    new_length: usize,
    alignment: usize,
) callconv(std.builtin.CallingConvention.c) *anyopaque {
    const context = currentAllocatorContext();
    assertLiveGeneration(ptr, context.generation);
    return context.host_allocator.realloc(
        ptr,
        new_length,
        alignment,
    ) orelse outOfMemory();
}

fn outOfMemory() noreturn {
    const message = "out of memory";
    rocCrashed(message.ptr, message.len);
}

/// A request-domain block is only valid in the request that allocated it:
/// `resetRequest` hands its memory to the next request. Freeing it later
/// would corrupt the request heap, so stop instead (ReleaseSafe keeps
/// assertions). Persistent blocks may be freed in any request.
fn assertLiveGeneration(ptr: *anyopaque, generation: usize) void {
    const metadata = host_allocator.allocationMetadata(ptr);
    std.debug.assert(metadata.domain != host_allocator.Domain.request or
        metadata.generation == generation);
}

pub fn rocDebug(
    bytes: [*]const u8,
    len: usize,
) callconv(std.builtin.CallingConvention.c) void {
    diagnostics.debug(bytes, len);
}

pub fn rocExpectFailed(
    bytes: [*]const u8,
    len: usize,
) callconv(std.builtin.CallingConvention.c) void {
    diagnostics.expectFailed(bytes, len);
}

/// A crash in a request's Roc code stops only that request: its fiber ends
/// here, and the scheduler answers 500. Anywhere else, as in `init!`,
/// it stops the worker.
pub fn rocCrashed(
    bytes: [*]const u8,
    len: usize,
) callconv(std.builtin.CallingConvention.c) noreturn {
    if (fiber_wait.onFiber()) {
        diagnostics.requestCrashed(bytes, len);
        fiber_wait.abandonCurrent();
    }
    diagnostics.crashed(bytes, len);
}

pub fn makeRocHost(environment: *anyopaque) abi.RocHost {
    return .{
        .env = environment,
        .roc_alloc = rocAllocWithHost,
        .roc_dealloc = rocDeallocWithHost,
        .roc_realloc = rocReallocWithHost,
        .roc_dbg = rocDebugWithHost,
        .roc_expect_failed = rocExpectFailedWithHost,
        .roc_crashed = rocCrashedWithHost,
    };
}

fn rocAllocWithHost(
    roc_host: *abi.RocHost,
    length: usize,
    alignment: usize,
) callconv(std.builtin.CallingConvention.c) *anyopaque {
    _ = roc_host;
    return rocAlloc(length, alignment);
}

/// `bridge.RequestHost.try_alloc` for a host made by `makeRocHost`.
pub fn tryAllocWithHost(
    roc_host: *abi.RocHost,
    length: usize,
    alignment: usize,
) ?*anyopaque {
    _ = roc_host;
    return tryAlloc(length, alignment);
}

fn rocDeallocWithHost(
    roc_host: *abi.RocHost,
    pointer: *anyopaque,
    alignment: usize,
) callconv(std.builtin.CallingConvention.c) void {
    _ = roc_host;
    rocDealloc(pointer, alignment);
}

fn rocReallocWithHost(
    roc_host: *abi.RocHost,
    pointer: *anyopaque,
    new_length: usize,
    alignment: usize,
) callconv(std.builtin.CallingConvention.c) *anyopaque {
    _ = roc_host;
    return rocRealloc(pointer, new_length, alignment);
}

fn rocDebugWithHost(
    roc_host: *abi.RocHost,
    bytes: [*]const u8,
    length: usize,
) callconv(std.builtin.CallingConvention.c) void {
    _ = roc_host;
    rocDebug(bytes, length);
}

fn rocExpectFailedWithHost(
    roc_host: *abi.RocHost,
    bytes: [*]const u8,
    length: usize,
) callconv(std.builtin.CallingConvention.c) void {
    _ = roc_host;
    rocExpectFailed(bytes, length);
}

fn rocCrashedWithHost(
    roc_host: *abi.RocHost,
    bytes: [*]const u8,
    length: usize,
) callconv(std.builtin.CallingConvention.c) void {
    _ = roc_host;
    rocCrashed(bytes, length);
}

fn currentAllocatorContext() allocator_context.Context {
    return allocator_context.current() orelse
        @panic("allocator context is not set");
}

test "roc allocator callbacks use current TLS context" {
    var persistent_storage: [128]u8 align(32) =
        undefined;
    var request_storage: [128]u8 align(32) =
        undefined;

    var persistent_fba =
        std.heap.FixedBufferAllocator.init(
            persistent_storage[0..],
        );
    var request_fba =
        std.heap.FixedBufferAllocator.init(
            request_storage[0..],
        );

    var runtime_allocator = host_allocator.HostAllocator{
        .persistent_allocator = persistent_fba.allocator(),
        .request_allocator = request_fba.allocator(),
    };

    allocator_context.setCurrent(.{
        .host_allocator = &runtime_allocator,
        .domain = host_allocator.Domain.request,
        .generation = 7,
    });
    defer allocator_context.clearCurrent();

    const alignment: usize = 16;
    const ptr = rocAlloc(
        8,
        alignment,
    );

    try std.testing.expect(
        request_fba.end_index > 0,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        persistent_fba.end_index,
    );

    rocDealloc(ptr, alignment);

    try std.testing.expectEqual(
        @as(usize, 0),
        request_fba.end_index,
    );
}
