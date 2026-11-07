//! `Sleep.millis!` and `Sleep.until!`. On a request fiber the fiber
//! waits for the deadline alone (no socket) and the Roc thread serves other
//! requests; off a fiber (`init!`) the thread sleeps.
const std = @import("std");
const diagnostics = @import("../diagnostics.zig");
const fiber_wait = @import("../fiber_wait.zig");
const instant = @import("instant.zig");

pub fn hostedSleepMilliseconds(milliseconds: u64) callconv(std.builtin.CallingConvention.c) void {
    sleepUntil(now() +| milliseconds *| std.time.ns_per_ms);
    fiber_wait.stopIfStreamEnds();
}

/// `deadline` is a monotonic clock reading, as `Instant` holds.
pub fn hostedSleepUntil(deadline: u64) callconv(std.builtin.CallingConvention.c) void {
    sleepUntil(deadline);
    fiber_wait.stopIfStreamEnds();
}

fn now() u64 {
    return instant.nowNanoseconds() orelse diagnostics.fatal("monotonic clock read failed or is out of range");
}

fn sleepUntil(deadline: u64) void {
    while (true) {
        const current = now();
        if (current >= deadline) return;
        // A wait may end early, as when the scheduler wakes it; the loop
        // waits again for what is left.
        if (fiber_wait.waitSocket(-1, 0, deadline) == null) sleepThread(deadline - current);
        // The request's client went, or the worker drains: a
        // sleep holds nothing.
        fiber_wait.stopIfStreamEnds();
    }
}

fn sleepThread(nanoseconds: u64) void {
    const pause = std.c.timespec{
        .sec = @intCast(@min(nanoseconds / std.time.ns_per_s, std.math.maxInt(i32))),
        .nsec = @intCast(nanoseconds % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&pause, null);
}

test "off a fiber the thread sleeps until the deadline" {
    const started = now();
    hostedSleepMilliseconds(20);
    try std.testing.expect(now() - started >= 20 * std.time.ns_per_ms);
}

test "a deadline already passed returns at once" {
    const started = now();
    hostedSleepUntil(started - 1);
    hostedSleepUntil(0);
    try std.testing.expect(now() - started < 10 * std.time.ns_per_ms);
}
