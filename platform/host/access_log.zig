//! The access log: one JSON line on stderr per response, including the
//! ones the host answers without running the app.
//!
//! The thread that finishes a response only copies its entry into a finite
//! queue; a thread of the worker's own formats and writes the lines, so a
//! slow stderr (a pipe to a container runtime) never holds a request. When the
//! queue is full the entry is dropped and counted (`dropped`). A draining
//! worker writes what is queued before it exits.
const std = @import("std");
const builtin = @import("builtin");
const request_id = @import("request_id.zig");
const stdio = @import("stdio.zig");
const sync = @import("sync.zig");
const wall_time = @import("effect/time.zig");
const metrics = @import("metrics.zig");

/// As `Server.AccessLog` says.
pub const Mode = enum {
    off,
    json_lines,
    json_lines_with_path,
};

/// Why the response is what it is. The status alone cannot tell a 503 for a
/// full queue from one for a request that waited too long, and the two call
/// for different fixes.
pub const Outcome = enum {
    /// The app answered, and the whole response was written.
    handled,
    /// The app's code crashed; the host answered 500.
    crashed,
    /// The host refused the request: malformed (400), a head or target too
    /// large (431, 414), an unknown method (501), an unsupported version
    /// (505), or an expectation it cannot meet (417).
    bad_request,
    /// The request's head or body did not arrive in time (408).
    timeout,
    /// The request's body was over the limit (413).
    too_large,
    /// The worker's queue was full (503).
    queue_full,
    /// The request waited in the queue past `queue_timeout_milliseconds` (503).
    queue_timeout,
    /// The worker already had `maximum_requests_in_progress` requests (503).
    in_progress_full,
    /// An overloaded worker answered a new connection without reading it
    /// (503): its queue, its requests in progress, or their memory was at the
    /// limit.
    overloaded,
    /// The bodies the worker was receiving already filled its buffer (503).
    body_budget,
    /// The worker already wrote `maximum_streams` streams (503).
    stream_limit,
    /// The app's reply could not be encoded, such as an invalid field (500).
    encode_failed,
    /// The connection closed or failed before the whole response was written.
    client_closed,
    /// The worker drained while the app wrote a body that may end then
    /// (`ResponseWriter.Options.ends_on_drain`): the body ended cleanly
    /// there and the connection closed.
    drained,
};

pub const maximum_method_bytes: usize = 16;
pub const maximum_path_bytes: usize = 512;
pub const maximum_route_bytes: usize = 256;

/// Entries the queue holds. Lines are written as fast as stderr takes them,
/// so the queue only fills while stderr is slower than the requests; this
/// many cover a burst of a second at about a thousand requests a second.
/// Measured and reconsidered with the other defaults.
pub const queue_capacity: usize = 1024;

/// A copied, length-limited text, cut at a UTF-8 character boundary.
pub fn Text(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *Self, value: []const u8) void {
            var end = @min(value.len, capacity);
            if (end < value.len) {
                while (end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
            }
            @memcpy(self.bytes[0..end], value[0..end]);
            self.len = end;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

/// What is known of a request by the time its response is done. Filled in by
/// whichever thread owns the connection as the request goes on.
pub const Entry = struct {
    method: Text(maximum_method_bytes) = .{},
    path: Text(maximum_path_bytes) = .{},
    route: Text(maximum_route_bytes) = .{},
    request_id: request_id.Id = .{},
    status: u16 = 0,
    outcome: Outcome = Outcome.handled,
    body_bytes: u64 = 0,
    /// Monotonic nanoseconds: when the request head was complete, or when
    /// the connection was accepted for one the host answered unread.
    started_at: u64 = 0,
    /// Nanoseconds the request waited for the Roc thread, when it ran.
    queue_nanoseconds: ?u64 = null,

    /// Reuse text storage; lengths hide the previous request's bytes.
    pub fn reset(self: *Entry) void {
        self.method.len = 0;
        self.path.len = 0;
        self.route.len = 0;
        self.request_id.len = 0;
        self.status = 0;
        self.outcome = Outcome.handled;
        self.body_bytes = 0;
        self.started_at = 0;
        self.queue_nanoseconds = null;
    }
};

/// An entry as queued: with when it finished.
const Line = struct {
    entry: Entry,
    time_unix_milliseconds: i64,
    duration_nanoseconds: u64,
};

const Queue = struct {
    mutex: sync.Mutex = .{},
    ready: sync.Condition = .{},
    lines: []Line,
    head: usize = 0,
    count: usize = 0,
    /// Set while the writer formats and writes a line it took.
    writing: bool = false,
    stopping: bool = false,
};

var mode: Mode = Mode.off;
var queue: ?*Queue = null;
var dropped_lines = std.atomic.Value(u64).init(0);

/// Starts the worker's writer thread. Called once per worker, after `init!`.
pub fn start(chosen: Mode) error{ OutOfMemory, ThreadSpawnFailed }!void {
    if (chosen == Mode.off) return;
    const created = try std.heap.page_allocator.create(Queue);
    errdefer std.heap.page_allocator.destroy(created);
    created.* = .{ .lines = try std.heap.page_allocator.alloc(Line, queue_capacity) };
    // Set before the writer starts, which reads the mode for each line.
    mode = chosen;
    queue = created;
    const thread = std.Thread.spawn(.{}, writeLines, .{created}) catch {
        mode = Mode.off;
        queue = null;
        return error.ThreadSpawnFailed;
    };
    thread.detach();
}

/// Whether responses are recorded: for the access log, the metrics
///, or both. Entries are filled in only then.
pub fn enabled() bool {
    return mode != Mode.off or metrics.enabled();
}

/// Lines dropped because the queue was full, for the metrics.
pub fn dropped() u64 {
    return dropped_lines.load(std.builtin.AtomicOrder.monotonic);
}

/// Counts a response that is done in the metrics and queues its line.
/// Never waits for stderr.
pub fn record(entry: *const Entry, finished_at: u64) void {
    metrics.observeRequest(entry, finished_at -| entry.started_at);
    const target = queue orelse return;
    const time = wall_time.nowUnixMilliseconds() orelse 0;
    target.mutex.lock();
    defer target.mutex.unlock();
    if (target.count == target.lines.len) {
        _ = dropped_lines.fetchAdd(1, std.builtin.AtomicOrder.monotonic);
        metrics.countAccessLogDropped();
        return;
    }
    const line = &target.lines[(target.head + target.count) % target.lines.len];
    line.* = .{
        .entry = entry.*,
        .time_unix_milliseconds = time,
        .duration_nanoseconds = finished_at -| entry.started_at,
    };
    target.count += 1;
    // The single writer only waits while the queue is empty, under this
    // same mutex. Further entries need no additional wake notification.
    if (target.count == 1) target.ready.signal();
}

/// Waits until every queued line is written or `deadline` (monotonic
/// nanoseconds) passes, for a worker about to exit.
pub fn finish(deadline: u64, now: *const fn () ?u64) void {
    const target = queue orelse return;
    {
        target.mutex.lock();
        defer target.mutex.unlock();
        target.stopping = true;
        target.ready.signal();
    }
    while (true) {
        {
            target.mutex.lock();
            defer target.mutex.unlock();
            if (target.count == 0 and !target.writing) return;
        }
        const current = now() orelse return;
        if (current >= deadline) return;
        const pause = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&pause, null);
    }
}

fn writeLines(target: *Queue) void {
    const pid = std.c.getpid();
    var buffer: [line_capacity]u8 = undefined;
    while (true) {
        var line: Line = undefined;
        {
            target.mutex.lock();
            defer target.mutex.unlock();
            while (target.count == 0) {
                if (target.stopping) return;
                target.ready.wait(&target.mutex);
            }
            line = target.lines[target.head];
            target.head = (target.head + 1) % target.lines.len;
            target.count -= 1;
            target.writing = true;
        }
        const text = format(&buffer, &line, mode == Mode.json_lines_with_path, pid);
        stdio.writeStderrLine(text);
        target.mutex.lock();
        target.writing = false;
        target.mutex.unlock();
    }
}

/// Room for the longest line: every text field at its limit, each byte
/// escaped as `\u00XX`, and the fixed fields.
const line_capacity: usize = 6 * (maximum_method_bytes + maximum_path_bytes + maximum_route_bytes + request_id.maximum_bytes) + 512;

fn format(buffer: []u8, line: *const Line, with_path: bool, pid: c_int) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writeLine(&writer, line, with_path, pid) catch unreachable;
    return writer.buffered();
}

fn writeLine(writer: *std.Io.Writer, line: *const Line, with_path: bool, pid: c_int) std.Io.Writer.Error!void {
    const entry = &line.entry;
    try writer.writeAll("{\"time\":\"");
    try writeTime(writer, line.time_unix_milliseconds);
    try writer.writeByte('"');
    if (entry.method.len > 0) try writeStringField(writer, "method", entry.method.slice());
    if (entry.route.len > 0) try writeStringField(writer, "route", entry.route.slice());
    if (with_path and entry.path.len > 0) try writeStringField(writer, "path", entry.path.slice());
    try writer.print(",\"status\":{d},\"outcome\":\"{s}\",\"body_bytes\":{d},\"duration_us\":{d}", .{
        entry.status,
        @tagName(entry.outcome),
        entry.body_bytes,
        line.duration_nanoseconds / std.time.ns_per_us,
    });
    if (entry.queue_nanoseconds) |nanoseconds| try writer.print(",\"queue_us\":{d}", .{nanoseconds / std.time.ns_per_us});
    try writer.print(",\"pid\":{d}", .{pid});
    try writeStringField(writer, "request_id", entry.request_id.slice());
    try writer.writeAll("}\n");
}

fn writeStringField(writer: *std.Io.Writer, name: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try writer.print(",\"{s}\":\"", .{name});
    try writeJsonText(writer, value);
    try writer.writeByte('"');
}

/// Writes `value` inside a JSON string. Quotes, backslashes, control bytes,
/// and DEL are escaped, so a request cannot end the string or the line. Text
/// that is not UTF-8 has its bytes from 0x80 escaped one by one, so the line
/// stays valid JSON.
fn writeJsonText(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    const utf8 = std.unicode.utf8ValidateSlice(value);
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0...0x1f, 0x7f => try writer.print("\\u{x:0>4}", .{byte}),
            else => if (byte >= 0x80 and !utf8)
                try writer.print("\\u{x:0>4}", .{byte})
            else
                try writer.writeByte(byte),
        }
    }
}

/// RFC 3339 in UTC to the millisecond, such as `2026-10-23T07:12:03.123Z`.
/// A time before 1970 is written as 1970.
fn writeTime(writer: *std.Io.Writer, unix_milliseconds: i64) std.Io.Writer.Error!void {
    const milliseconds: u64 = @intCast(@max(unix_milliseconds, 0));
    const seconds = milliseconds / std.time.ms_per_s;
    const days = seconds / std.time.s_per_day;
    const of_day = seconds % std.time.s_per_day;
    const date = civilFromDays(days);
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        date.year,
        date.month,
        date.day,
        of_day / 3600,
        of_day % 3600 / 60,
        of_day % 60,
        milliseconds % std.time.ms_per_s,
    });
}

const CivilDate = struct { year: u64, month: u64, day: u64 };

/// The proleptic Gregorian date `days` after 1970-01-01 (Howard Hinnant's
/// `civil_from_days`, for days on or after the epoch).
fn civilFromDays(days: u64) CivilDate {
    const shifted = days + 719_468;
    const era = shifted / 146_097;
    const day_of_era = shifted - era * 146_097;
    const year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    const day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    const month_index = (5 * day_of_year + 2) / 153;
    const day = day_of_year - (153 * month_index + 2) / 5 + 1;
    const month = if (month_index < 10) month_index + 3 else month_index - 9;
    const year = year_of_era + era * 400 + @intFromBool(month <= 2);
    return .{ .year = year, .month = month, .day = day };
}

const testing = std.testing;

fn formattedTime(unix_milliseconds: i64) ![]const u8 {
    const State = struct {
        var buffer: [32]u8 = undefined;
    };
    var writer = std.Io.Writer.fixed(&State.buffer);
    try writeTime(&writer, unix_milliseconds);
    return writer.buffered();
}

test "times are RFC 3339 in UTC around the epoch, a leap day, and a year's end" {
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", try formattedTime(0));
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", try formattedTime(-1));
    try testing.expectEqualStrings("1970-01-01T00:00:00.001Z", try formattedTime(1));
    try testing.expectEqualStrings("2000-02-28T23:59:59.999Z", try formattedTime(951_782_399_999));
    try testing.expectEqualStrings("2000-02-29T00:00:00.000Z", try formattedTime(951_782_400_000));
    try testing.expectEqualStrings("2000-03-01T00:00:00.000Z", try formattedTime(951_868_800_000));
    try testing.expectEqualStrings("2025-12-31T23:59:59.999Z", try formattedTime(1_767_225_599_999));
    try testing.expectEqualStrings("2026-01-01T00:00:00.000Z", try formattedTime(1_767_225_600_000));
    try testing.expectEqualStrings("2026-10-23T07:12:03.123Z", try formattedTime(1_792_739_523_123));
}

fn testLine() Line {
    var line = Line{ .entry = .{}, .time_unix_milliseconds = 1_792_739_523_123, .duration_nanoseconds = 1_830_999 };
    line.entry.method.set("GET");
    line.entry.route.set("/users/{id}");
    line.entry.path.set("/users/42");
    line.entry.request_id.bytes[0..3].* = "abc".*;
    line.entry.request_id.len = 3;
    line.entry.status = 200;
    line.entry.body_bytes = 1234;
    line.entry.queue_nanoseconds = 45_999;
    return line;
}

test "a line names the request and truncates durations to microseconds" {
    var buffer: [line_capacity]u8 = undefined;
    const line = testLine();
    try testing.expectEqualStrings(
        "{\"time\":\"2026-10-23T07:12:03.123Z\",\"method\":\"GET\",\"route\":\"/users/{id}\",\"status\":200,\"outcome\":\"handled\",\"body_bytes\":1234,\"duration_us\":1830,\"queue_us\":45,\"pid\":7,\"request_id\":\"abc\"}\n",
        format(&buffer, &line, false, 7),
    );
}

test "the path is written only when asked for, and absent fields are left out" {
    var buffer: [line_capacity]u8 = undefined;
    var line = testLine();
    try testing.expect(std.mem.indexOf(u8, format(&buffer, &line, true, 7), ",\"path\":\"/users/42\",") != null);

    line.entry.method.set("");
    line.entry.route.set("");
    line.entry.queue_nanoseconds = null;
    line.entry.status = 503;
    line.entry.outcome = Outcome.overloaded;
    line.entry.body_bytes = 0;
    try testing.expectEqualStrings(
        "{\"time\":\"2026-10-23T07:12:03.123Z\",\"path\":\"/users/42\",\"status\":503,\"outcome\":\"overloaded\",\"body_bytes\":0,\"duration_us\":1830,\"pid\":7,\"request_id\":\"abc\"}\n",
        format(&buffer, &line, true, 7),
    );
}

test "quotes, backslashes, control bytes, and DEL are escaped; UTF-8 is kept, other high bytes are escaped" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeJsonText(&writer, "a\"b\\c\x00\x1f\x7f é");
    try testing.expectEqualStrings("a\\\"b\\\\c\\u0000\\u001f\\u007f é", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try writeJsonText(&writer, "/\xff ");
    try testing.expectEqualStrings("/\\u00ff ", writer.buffered());
}

test "the longest line fits its buffer" {
    var buffer: [line_capacity]u8 = undefined;
    var line = Line{ .entry = .{}, .time_unix_milliseconds = std.math.maxInt(i64), .duration_nanoseconds = std.math.maxInt(u64) };
    line.entry.method.set(&@as([maximum_method_bytes]u8, @splat('\x01')));
    line.entry.path.set(&@as([maximum_path_bytes]u8, @splat('\x01')));
    line.entry.route.set(&@as([maximum_route_bytes]u8, @splat('\x01')));
    @memset(&line.entry.request_id.bytes, 0x01);
    line.entry.request_id.len = request_id.maximum_bytes;
    line.entry.status = std.math.maxInt(u16);
    line.entry.body_bytes = std.math.maxInt(u64);
    line.entry.queue_nanoseconds = std.math.maxInt(u64);
    _ = format(&buffer, &line, true, std.math.maxInt(c_int));
}

test "text is kept whole up to its limit and cut at a character boundary past it" {
    var text = Text(4){};
    text.set("abc");
    try testing.expectEqualStrings("abc", text.slice());
    text.set("abcd");
    try testing.expectEqualStrings("abcd", text.slice());
    text.set("abcde");
    try testing.expectEqualStrings("abcd", text.slice());
    text.set("abcé");
    try testing.expectEqualStrings("abc", text.slice());
}

test "a full queue drops and counts lines instead of waiting" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var lines: [2]Line = undefined;
    var full = Queue{ .lines = &lines };
    queue = &full;
    defer queue = null;
    const before = dropped();
    const entry = Entry{};
    record(&entry, 0);
    record(&entry, 0);
    try testing.expectEqual(before, dropped());
    record(&entry, 0);
    try testing.expectEqual(before + 1, dropped());
    try testing.expectEqual(@as(usize, 2), full.count);
}

test "a reused entry exposes none of the previous request's fields" {
    var entry = Entry{
        .status = 503,
        .outcome = Outcome.overloaded,
        .body_bytes = 123,
        .started_at = 456,
        .queue_nanoseconds = 789,
    };
    entry.method.set("POST");
    entry.path.set("/previous");
    entry.route.set("/{previous}");
    @memcpy(entry.request_id.bytes[0..3], "old");
    entry.request_id.len = 3;
    entry.reset();
    try testing.expectEqual(@as(u64, 0), entry.started_at);
    var actual: [line_capacity]u8 = undefined;
    var expected: [line_capacity]u8 = undefined;
    const reused = Line{ .entry = entry, .time_unix_milliseconds = 0, .duration_nanoseconds = 0 };
    const fresh = Line{ .entry = .{}, .time_unix_milliseconds = 0, .duration_nanoseconds = 0 };
    try testing.expectEqualStrings(format(&expected, &fresh, true, 1), format(&actual, &reused, true, 1));
}
