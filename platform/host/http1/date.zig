const std = @import("std");
pub const Buffer = [29]u8;

/// IMF-fixdate for the supported Unix epoch through four-digit year range.
pub fn format(seconds: i64, buffer: *Buffer) ?[]const u8 {
    if (seconds < 0 or seconds > 253402300799) return null;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(buffer, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekdays[day.day % 7],                 @as(u8, month_day.day_index) + 1,
        months[month_day.month.numeric() - 1], year_day.year,
        time.getHoursIntoDay(),                time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// The last formatted date. Responses within one second share it, so the
/// date is formatted once per second rather than once per response.
pub const Cache = struct {
    seconds: i64 = -1,
    buffer: Buffer = undefined,
    length: usize = 0,

    pub fn format(self: *Cache, seconds: i64) ?[]const u8 {
        if (seconds != self.seconds) {
            const formatted = date_format(seconds, &self.buffer) orelse return null;
            self.seconds = seconds;
            self.length = formatted.len;
        }
        return self.buffer[0..self.length];
    }
};

const date_format = format;

test "the cache formats once per second and follows the clock" {
    var cache = Cache{};
    var expected: Buffer = undefined;
    for ([_]i64{ 86399, 86399, 86400, 86401, 86400 }) |seconds| {
        try std.testing.expectEqualStrings(format(seconds, &expected).?, cache.format(seconds).?);
    }
    try std.testing.expect(cache.format(-1) == null);
    // A failed format keeps the last good value for its own second.
    try std.testing.expectEqualStrings(format(86400, &expected).?, cache.format(86400).?);
}

test "HTTP date epoch, day and leap-day boundaries" {
    const cases = [_]struct { seconds: i64, expected: []const u8 }{
        .{ .seconds = 0, .expected = "Thu, 01 Jan 1970 00:00:00 GMT" },
        .{ .seconds = 1, .expected = "Thu, 01 Jan 1970 00:00:01 GMT" },
        .{ .seconds = 86399, .expected = "Thu, 01 Jan 1970 23:59:59 GMT" },
        .{ .seconds = 86400, .expected = "Fri, 02 Jan 1970 00:00:00 GMT" },
        .{ .seconds = 86401, .expected = "Fri, 02 Jan 1970 00:00:01 GMT" },
        .{ .seconds = 951782399, .expected = "Mon, 28 Feb 2000 23:59:59 GMT" },
        .{ .seconds = 951782400, .expected = "Tue, 29 Feb 2000 00:00:00 GMT" },
        .{ .seconds = 951782401, .expected = "Tue, 29 Feb 2000 00:00:01 GMT" },
        .{ .seconds = 253402300798, .expected = "Fri, 31 Dec 9999 23:59:58 GMT" },
        .{ .seconds = 253402300799, .expected = "Fri, 31 Dec 9999 23:59:59 GMT" },
    };
    var buffer: Buffer = undefined;
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, format(case.seconds, &buffer).?);
    try std.testing.expect(format(-1, &buffer) == null);
    try std.testing.expect(format(253402300800, &buffer) == null);
}
