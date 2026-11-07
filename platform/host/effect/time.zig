const std = @import("std");
const diagnostics = @import("../diagnostics.zig");

const nanoseconds_per_second: isize = 1_000_000_000;
const nanoseconds_per_millisecond: isize = 1_000_000;
const milliseconds_per_second: i128 = 1_000;

pub fn hostedTimeNowUnixMilliseconds() callconv(std.builtin.CallingConvention.c) i64 {
    return nowUnixMilliseconds() orelse diagnostics.fatal("wall clock read failed or is out of range");
}

pub fn nowUnixMilliseconds() ?i64 {
    var time: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &time) != 0) return null;
    return timespecToUnixMilliseconds(time.sec, time.nsec);
}

fn timespecToUnixMilliseconds(
    seconds: isize,
    nanoseconds: isize,
) ?i64 {
    if (nanoseconds < 0 or
        nanoseconds >= nanoseconds_per_second)
    {
        return null;
    }

    const milliseconds =
        @as(i128, seconds) * milliseconds_per_second +
        @divTrunc(
            @as(i128, nanoseconds),
            nanoseconds_per_millisecond,
        );
    return std.math.cast(i64, milliseconds);
}

test "timespec conversion truncates at millisecond boundary" {
    try std.testing.expectEqual(
        @as(?i64, 0),
        timespecToUnixMilliseconds(0, 999_999),
    );
    try std.testing.expectEqual(
        @as(?i64, 1),
        timespecToUnixMilliseconds(0, 1_000_000),
    );
    try std.testing.expectEqual(
        @as(?i64, 1),
        timespecToUnixMilliseconds(0, 1_000_001),
    );
}

test "timespec conversion rejects nanosecond range boundaries" {
    try std.testing.expectEqual(
        @as(?i64, null),
        timespecToUnixMilliseconds(0, -1),
    );
    try std.testing.expectEqual(
        @as(?i64, 999),
        timespecToUnixMilliseconds(0, 999_999_999),
    );
    try std.testing.expectEqual(
        @as(?i64, null),
        timespecToUnixMilliseconds(0, 1_000_000_000),
    );
}

test "timespec conversion enforces the i64 maximum boundary" {
    const maximum_seconds =
        @divTrunc(std.math.maxInt(i64), 1_000);
    const boundary_milliseconds =
        @mod(std.math.maxInt(i64), 1_000);

    try std.testing.expectEqual(
        @as(?i64, std.math.maxInt(i64) - 1),
        timespecToUnixMilliseconds(
            maximum_seconds,
            (boundary_milliseconds - 1) *
                nanoseconds_per_millisecond,
        ),
    );
    try std.testing.expectEqual(
        @as(?i64, std.math.maxInt(i64)),
        timespecToUnixMilliseconds(
            maximum_seconds,
            boundary_milliseconds *
                nanoseconds_per_millisecond,
        ),
    );
    try std.testing.expectEqual(
        @as(?i64, null),
        timespecToUnixMilliseconds(
            maximum_seconds,
            (boundary_milliseconds + 1) *
                nanoseconds_per_millisecond,
        ),
    );
}

test "timespec conversion enforces the i64 minimum boundary" {
    const minimum_seconds =
        @divFloor(std.math.minInt(i64), 1_000);
    const boundary_milliseconds =
        std.math.minInt(i64) - minimum_seconds * 1_000;

    try std.testing.expectEqual(
        @as(?i64, null),
        timespecToUnixMilliseconds(
            minimum_seconds,
            (boundary_milliseconds - 1) *
                nanoseconds_per_millisecond,
        ),
    );
    try std.testing.expectEqual(
        @as(?i64, std.math.minInt(i64)),
        timespecToUnixMilliseconds(
            minimum_seconds,
            boundary_milliseconds *
                nanoseconds_per_millisecond,
        ),
    );
    try std.testing.expectEqual(
        @as(?i64, std.math.minInt(i64) + 1),
        timespecToUnixMilliseconds(
            minimum_seconds,
            (boundary_milliseconds + 1) *
                nanoseconds_per_millisecond,
        ),
    );
}
