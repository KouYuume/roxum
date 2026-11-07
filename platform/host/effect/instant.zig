const std = @import("std");
const diagnostics = @import("../diagnostics.zig");

const nanoseconds_per_second: u64 = 1_000_000_000;

pub fn hostedInstantNowNanoseconds() callconv(std.builtin.CallingConvention.c) u64 {
    return nowNanoseconds() orelse diagnostics.fatal("monotonic clock read failed or is out of range");
}

pub fn nowNanoseconds() ?u64 {
    var time: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &time) != 0) return null;
    return timespecToNanoseconds(time.sec, time.nsec);
}

fn timespecToNanoseconds(
    seconds: isize,
    nanoseconds: isize,
) ?u64 {
    if (seconds < 0) return null;
    if (nanoseconds < 0 or
        nanoseconds >= nanoseconds_per_second)
    {
        return null;
    }

    const whole = std.math.mul(
        u64,
        @intCast(seconds),
        nanoseconds_per_second,
    ) catch return null;
    return std.math.add(u64, whole, @intCast(nanoseconds)) catch null;
}

test "monotonic clock does not move backwards between reads" {
    const first = nowNanoseconds() orelse return error.ClockUnavailable;
    const second = nowNanoseconds() orelse return error.ClockUnavailable;
    try std.testing.expect(second >= first);
}

test "timespec conversion rejects the negative second boundary" {
    try std.testing.expectEqual(
        @as(?u64, null),
        timespecToNanoseconds(-1, 0),
    );
    try std.testing.expectEqual(
        @as(?u64, 0),
        timespecToNanoseconds(0, 0),
    );
    try std.testing.expectEqual(
        @as(?u64, nanoseconds_per_second),
        timespecToNanoseconds(1, 0),
    );
}

test "timespec conversion rejects nanosecond range boundaries" {
    try std.testing.expectEqual(
        @as(?u64, null),
        timespecToNanoseconds(0, -1),
    );
    try std.testing.expectEqual(
        @as(?u64, 999_999_999),
        timespecToNanoseconds(0, 999_999_999),
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        timespecToNanoseconds(0, 1_000_000_000),
    );
}

test "timespec conversion enforces the u64 maximum boundary" {
    const maximum_seconds: isize = @intCast(
        @divTrunc(std.math.maxInt(u64), nanoseconds_per_second),
    );
    const boundary_nanoseconds: isize = @intCast(
        @mod(std.math.maxInt(u64), nanoseconds_per_second),
    );

    try std.testing.expectEqual(
        @as(?u64, std.math.maxInt(u64) - 1),
        timespecToNanoseconds(maximum_seconds, boundary_nanoseconds - 1),
    );
    try std.testing.expectEqual(
        @as(?u64, std.math.maxInt(u64)),
        timespecToNanoseconds(maximum_seconds, boundary_nanoseconds),
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        timespecToNanoseconds(maximum_seconds, boundary_nanoseconds + 1),
    );
}
