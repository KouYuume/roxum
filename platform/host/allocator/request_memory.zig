//! The bytes live request values hold across one worker: every
//! request heap, including those of requests waiting on a fiber and of
//! streams, adds what it allocates and subtracts what it frees. The Roc
//! thread changes it; the event loop reads it to tell whether the worker
//! is overloaded.
//!
//! Each Roc thread's request heaps count in a `Share` of their own;
//! a heap without one changes a count shared by all threads.
//!
//! Two stages: near the limit the worker stops admitting new
//! requests; over it, reads from outside (`Tcp.read!`) are refused.
const std = @import("std");

var live_bytes = std.atomic.Value(usize).init(0);
var limit_bytes: usize = std.math.maxInt(usize);

/// The share of the limit past which new requests are refused, in tenths
///.
const admission_tenths = 8;

pub fn grow(bytes: usize) void {
    _ = live_bytes.fetchAdd(bytes, std.builtin.AtomicOrder.monotonic);
}

pub fn shrink(bytes: usize) void {
    _ = live_bytes.fetchSub(bytes, std.builtin.AtomicOrder.monotonic);
}

/// One Roc thread's part of the live bytes. Only the thread that
/// holds it writes it, with a plain store: a read-modify-write on a count
/// every thread changes took a tenth of a busy worker's time. Values
/// allocated on one thread and freed on another make a part negative; the
/// sum is still the total.
pub const Share = struct {
    bytes: std.atomic.Value(isize) align(std.atomic.cache_line) = std.atomic.Value(isize).init(0),
    taken: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn grow(self: *Share, bytes: usize) void {
        const order = std.builtin.AtomicOrder.monotonic;
        self.bytes.store(self.bytes.load(order) +% @as(isize, @bitCast(bytes)), order);
    }

    pub fn shrink(self: *Share, bytes: usize) void {
        const order = std.builtin.AtomicOrder.monotonic;
        self.bytes.store(self.bytes.load(order) -% @as(isize, @bitCast(bytes)), order);
    }
};

/// More than the most Roc threads a worker runs (`Server.Threads`).
const maximum_shares = 512;
var shares: [maximum_shares]Share = @splat(.{});
/// The shares ever taken are the first this many; `current` sums them.
var shares_used = std.atomic.Value(usize).init(0);

/// A share for one thread's heap, or null when every one is held: the heap
/// then changes the shared count.
pub fn takeShare() ?*Share {
    for (&shares, 0..) |*share, index| {
        if (share.taken.cmpxchgStrong(false, true, std.builtin.AtomicOrder.acquire, std.builtin.AtomicOrder.monotonic) == null) {
            _ = shares_used.fetchMax(index + 1, std.builtin.AtomicOrder.release);
            return share;
        }
    }
    return null;
}

/// A share given back keeps its bytes, which values its thread allocated
/// and another thread still holds may account for; the next holder adds to
/// them.
pub fn giveShare(share: *Share) void {
    share.taken.store(false, std.builtin.AtomicOrder.release);
}

pub fn current() usize {
    var total: isize = @bitCast(live_bytes.load(std.builtin.AtomicOrder.monotonic));
    for (shares[0..shares_used.load(std.builtin.AtomicOrder.acquire)]) |*share| {
        total +%= share.bytes.load(std.builtin.AtomicOrder.monotonic);
    }
    return if (total < 0) 0 else @intCast(total);
}

/// Set once, before the worker serves requests.
pub fn setLimit(bytes: usize) void {
    limit_bytes = bytes;
}

pub fn limit() usize {
    return limit_bytes;
}

/// New requests are refused.
pub fn nearLimit() bool {
    return current() >= limit_bytes / 10 * admission_tenths;
}

/// Reads from outside are refused.
pub fn overLimit() bool {
    return current() >= limit_bytes;
}

test "the stages follow the live bytes" {
    const saved = limit_bytes;
    defer limit_bytes = saved;
    const start = current();
    defer {
        const now = current();
        if (now > start) shrink(now - start) else grow(start - now);
    }
    setLimit(start + 1000);
    try std.testing.expect(!overLimit());
    grow(1000);
    try std.testing.expect(nearLimit());
    try std.testing.expect(overLimit());
    shrink(1000);
    try std.testing.expect(!overLimit());
}

test "shares add up to the total, though a value freed on another thread makes one negative" {
    const start = current();
    const first = takeShare().?;
    defer giveShare(first);
    const second = takeShare().?;
    defer giveShare(second);
    try std.testing.expect(first != second);
    first.grow(1000);
    try std.testing.expectEqual(start + 1000, current());
    second.shrink(1000);
    try std.testing.expectEqual(start, current());
    first.shrink(1000);
    second.grow(1000);
    try std.testing.expectEqual(start, current());
}
