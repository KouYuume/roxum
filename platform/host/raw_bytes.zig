//! Byte buffers from `std.heap.smp_allocator` without the fill of a safe
//! build. `Allocator.alloc`, `realloc`, and `free` write 0xAA over
//! every byte they hand out or take back when runtime safety is on, and the
//! host is built ReleaseSafe: for the buffers a request with a body of tens
//! of KiB grows and frees, that fill took over 40 % of its CPU time. These go
//! to the allocator's raw functions, which do not fill. Buffers of 64 KiB to
//! 1 MiB, which the allocator would map and unmap each time, are kept for
//! reuse; a buffer from here must be freed here, and only buffers from here.
const std = @import("std");
const sync = @import("sync.zig");

const backing = std.heap.smp_allocator;
const alignment = std.mem.Alignment.of(u8);

/// `smp_allocator` keeps freed slots up to this size; larger ones it maps
/// and unmaps each time, and a process's threads then contend for the
/// kernel's lock on its address space.
const largest_slot: usize = 32 * 1024;
/// Buffers from 64 KiB to this size are rounded up to a power of two and
/// kept when freed, up to `cache_limit` bytes in all, for the next one.
const largest_cached: usize = 1024 * 1024;
const cache_limit: usize = 16 * 1024 * 1024;
const first_cached_class = std.math.log2_int(usize, largest_slot) + 1;
const cached_classes = std.math.log2_int(usize, largest_cached) - first_cached_class + 1;

const Free = struct { next: ?*Free };

var cache_lock: sync.Mutex = .{};
var cached: [cached_classes]?*Free = @splat(null);
var cached_bytes: usize = 0;

/// What a buffer of `length` bytes takes: rounded up when it is cached.
fn capacityOf(length: usize) usize {
    if (length <= largest_slot or length > largest_cached) return length;
    return std.math.ceilPowerOfTwoAssert(usize, length);
}

fn classOf(capacity: usize) ?usize {
    if (capacity <= largest_slot or capacity > largest_cached) return null;
    return std.math.log2_int(usize, capacity) - first_cached_class;
}

pub fn alloc(length: usize) error{OutOfMemory}![]u8 {
    if (length == 0) return &.{};
    const capacity = capacityOf(length);
    if (classOf(capacity)) |class| {
        if (takeCached(class, capacity)) |memory| return memory[0..length];
    }
    const memory = backing.rawAlloc(capacity, alignment, @returnAddress()) orelse return error.OutOfMemory;
    return memory[0..length];
}

pub fn free(bytes: []u8) void {
    if (bytes.len == 0) return;
    const capacity = capacityOf(bytes.len);
    if (classOf(capacity)) |class| {
        if (keep(class, capacity, bytes.ptr)) return;
    }
    backing.rawFree(bytes.ptr[0..capacity], alignment, @returnAddress());
}

fn takeCached(class: usize, capacity: usize) ?[*]u8 {
    cache_lock.lock();
    defer cache_lock.unlock();
    const head = cached[class] orelse return null;
    cached[class] = head.next;
    cached_bytes -= capacity;
    return @ptrCast(head);
}

fn keep(class: usize, capacity: usize, memory: [*]u8) bool {
    cache_lock.lock();
    defer cache_lock.unlock();
    if (cached_bytes + capacity > cache_limit) return false;
    const node: *Free = @ptrCast(@alignCast(memory));
    node.* = .{ .next = cached[class] };
    cached[class] = node;
    cached_bytes += capacity;
    return true;
}

pub fn dupe(bytes: []const u8) error{OutOfMemory}![]u8 {
    const copy = try alloc(bytes.len);
    @memcpy(copy, bytes);
    return copy;
}

/// The bytes in a buffer of `length`: in place when the old one has room
/// or the allocator can grow it, else moved and the old one freed.
pub fn realloc(old: []u8, length: usize) error{OutOfMemory}![]u8 {
    if (old.len == 0) return alloc(length);
    if (length == 0) {
        free(old);
        return &.{};
    }
    const old_capacity = capacityOf(old.len);
    const new_capacity = capacityOf(length);
    if (old_capacity == new_capacity and classOf(old_capacity) != null) return old.ptr[0..length];
    if (classOf(old_capacity) == null and classOf(new_capacity) == null) {
        if (backing.rawRemap(old, alignment, length, @returnAddress())) |moved| return moved[0..length];
    }
    const grown = try alloc(length);
    const kept = @min(old.len, length);
    @memcpy(grown[0..kept], old[0..kept]);
    free(old);
    return grown;
}

test "a buffer keeps its bytes as it grows and shrinks" {
    var bytes = try alloc(4);
    @memcpy(bytes, "abcd");
    bytes = try realloc(bytes, 100_000);
    try std.testing.expectEqualStrings("abcd", bytes[0..4]);
    bytes = try realloc(bytes, 2);
    try std.testing.expectEqualStrings("ab", bytes);
    const copy = try dupe(bytes);
    defer free(copy);
    free(bytes);
    try std.testing.expectEqualStrings("ab", copy);
    try std.testing.expectEqual(@as(usize, 0), (try alloc(0)).len);
    try std.testing.expectEqual(@as(usize, 0), (try realloc(&.{}, 0)).len);
}

test "a buffer of tens of KiB is kept for the next one" {
    const first = try alloc(40 * 1024);
    const address = first.ptr;
    free(first);
    const second = try alloc(50 * 1024);
    defer free(second);
    try std.testing.expectEqual(address, second.ptr);
    // Growing within its rounded capacity stays in place.
    const grown = try realloc(second, 60 * 1024);
    try std.testing.expectEqual(address, grown.ptr);
}
