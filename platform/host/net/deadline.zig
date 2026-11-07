const std = @import("std");

const nanoseconds_per_second: u64 = 1_000_000_000;
const nanoseconds_per_millisecond: u64 = 1_000_000;

pub const Error = error{
    ClockFailed,
};

pub const Deadline = struct {
    expires_at_nanoseconds: u64,

    pub fn afterMilliseconds(milliseconds: u64) Error!Deadline {
        return fromNow(try monotonicNanoseconds(), milliseconds);
    }

    /// `milliseconds` after `now_nanoseconds`, saturating. Lets a caller
    /// that read the clock once compute many deadlines without failing.
    pub fn fromNow(now_nanoseconds: u64, milliseconds: u64) Deadline {
        const duration = std.math.mul(
            u64,
            milliseconds,
            nanoseconds_per_millisecond,
        ) catch std.math.maxInt(u64);
        return .{
            .expires_at_nanoseconds = std.math.add(
                u64,
                now_nanoseconds,
                duration,
            ) catch std.math.maxInt(u64),
        };
    }

    /// True once `now_nanoseconds` reaches the deadline, matching
    /// `remainingPollMilliseconds` returning null.
    pub fn hasPassedAt(self: Deadline, now_nanoseconds: u64) bool {
        return now_nanoseconds >= self.expires_at_nanoseconds;
    }

    /// Returns a poll timeout rounded up so readiness is never rejected early.
    pub fn remainingPollMilliseconds(
        self: Deadline,
    ) Error!?c_int {
        return self.remainingPollMillisecondsAt(
            try monotonicNanoseconds(),
        );
    }

    fn remainingPollMillisecondsAt(
        self: Deadline,
        now_nanoseconds: u64,
    ) ?c_int {
        if (now_nanoseconds >= self.expires_at_nanoseconds) return null;

        const remaining = self.expires_at_nanoseconds - now_nanoseconds;
        const milliseconds = 1 +
            (remaining - 1) / nanoseconds_per_millisecond;
        return @intCast(@min(
            milliseconds,
            @as(u64, std.math.maxInt(c_int)),
        ));
    }
};

pub fn monotonicNanoseconds() Error!u64 {
    var time: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &time) != 0) return Error.ClockFailed;
    if (time.sec < 0 or time.nsec < 0 or
        time.nsec >= nanoseconds_per_second)
    {
        return Error.ClockFailed;
    }

    const seconds: u64 = @intCast(time.sec);
    const nanoseconds: u64 = @intCast(time.nsec);
    const base = std.math.mul(
        u64,
        seconds,
        nanoseconds_per_second,
    ) catch return Error.ClockFailed;
    return std.math.add(u64, base, nanoseconds) catch Error.ClockFailed;
}

test "poll timeout covers expiration boundaries and rounds up" {
    const deadline = Deadline{ .expires_at_nanoseconds = 2_000_000 };

    try std.testing.expectEqual(
        @as(?c_int, 2),
        deadline.remainingPollMillisecondsAt(0),
    );
    try std.testing.expectEqual(
        @as(?c_int, 1),
        deadline.remainingPollMillisecondsAt(1_000_000),
    );
    try std.testing.expectEqual(
        @as(?c_int, 1),
        deadline.remainingPollMillisecondsAt(1_999_999),
    );
    try std.testing.expectEqual(
        @as(?c_int, null),
        deadline.remainingPollMillisecondsAt(2_000_000),
    );
    try std.testing.expectEqual(
        @as(?c_int, null),
        deadline.remainingPollMillisecondsAt(2_000_001),
    );
}

test "poll timeout saturates at the c_int boundary" {
    const maximum_milliseconds: u64 = std.math.maxInt(c_int);
    const deadline = Deadline{
        .expires_at_nanoseconds = (maximum_milliseconds + 1) * nanoseconds_per_millisecond,
    };

    try std.testing.expectEqual(
        @as(?c_int, std.math.maxInt(c_int)),
        deadline.remainingPollMillisecondsAt(0),
    );
}

test "a deadline has passed from its expiry onward" {
    const deadline = Deadline{ .expires_at_nanoseconds = 2_000_000 };
    try std.testing.expect(!deadline.hasPassedAt(1_999_999));
    try std.testing.expect(deadline.hasPassedAt(2_000_000));
    try std.testing.expect(deadline.hasPassedAt(2_000_001));
}

test "a deadline from a clock reading saturates instead of overflowing" {
    const maximum = std.math.maxInt(u64);
    try std.testing.expectEqual(@as(u64, 1_000_000 + 7), Deadline.fromNow(7, 1).expires_at_nanoseconds);
    try std.testing.expectEqual(maximum, Deadline.fromNow(maximum - 1, 1).expires_at_nanoseconds);
    try std.testing.expectEqual(maximum, Deadline.fromNow(0, maximum).expires_at_nanoseconds);
}
