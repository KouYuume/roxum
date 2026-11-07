//! Request context for `dbg` and crash logs, and the `dbg` capture that debug
//! mode (`--debug`) attaches to responses as `X-Roxum-Dbg` fields.
//!
//! Everything here runs on the Roc thread: `roc_dbg` and `roc_crashed` are
//! called from inside `roc_handle` and streaming producers, so the context is
//! thread-local.
const std = @import("std");
const http1 = @import("http1/encoder.zig");
const log_text = @import("log_text.zig");
const fiber = @import("fiber.zig");

/// Set once from the command line before workers fork; workers inherit it.
pub var enabled: bool = false;

pub const maximum_entries: usize = 16;
pub const maximum_entry_bytes: usize = 1024;
/// Captured fields plus the truncation count.
pub const maximum_headers: usize = maximum_entries + 1;

const maximum_method_bytes: usize = 16;
const maximum_path_bytes: usize = 256;
const maximum_request_id_bytes: usize = 128;
const maximum_traceparent_bytes: usize = 64;

/// What logs name a request by. The query is dropped: it often carries
/// tokens or personal data.
pub const Label = struct {
    method: Field(maximum_method_bytes) = .{},
    path: Field(maximum_path_bytes) = .{},
    request_id: Field(maximum_request_id_bytes) = .{},
    traceparent: Field(maximum_traceparent_bytes) = .{},

    pub fn init(
        method: []const u8,
        target: []const u8,
        request_id: ?[]const u8,
        traceparent: ?[]const u8,
    ) Label {
        var result = Label{};
        result.set(method, target, request_id, traceparent);
        return result;
    }

    /// Writes every field in place: building a `Label` and copying it in
    /// would fill its bytes in a safe build first.
    pub fn set(
        self: *Label,
        method: []const u8,
        target: []const u8,
        request_id: ?[]const u8,
        traceparent: ?[]const u8,
    ) void {
        self.method.set(method);
        self.path.set(pathOf(target));
        self.request_id.set(request_id orelse "");
        self.traceparent.set(traceparent orelse "");
    }
};

/// A copied, printable, length-limited value. Bytes outside visible ASCII
/// become `?` so a request cannot forge log lines; a cut value ends in `...`.
fn Field(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        fn set(self: *Self, value: []const u8) void {
            const ellipsis = "...";
            const cut = value.len > capacity;
            const kept = if (cut) capacity - ellipsis.len else value.len;
            for (value[0..kept], self.bytes[0..kept]) |byte, *output| {
                output.* = if (byte > ' ' and byte < 0x7f) byte else '?';
            }
            if (cut) @memcpy(self.bytes[kept..capacity], ellipsis);
            self.len = if (cut) capacity else kept;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

fn pathOf(target: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..end];
}

const Capture = struct {
    entries: [maximum_entries][maximum_entry_bytes]u8 = undefined,
    lengths: [maximum_entries]usize = undefined,
    count: usize = 0,
    dropped: usize = 0,
    /// Cleared once the response head is encoded; later `dbg` output (from
    /// streaming producers) can only be logged.
    open: bool = false,

    /// Starts an empty capture. Only the counters are reset: the entry
    /// arrays are written before they are read, and re-initializing them
    /// would fill 16 KiB per request in safe builds.
    fn reset(self: *Capture, open: bool) void {
        self.count = 0;
        self.dropped = 0;
        self.open = open;
    }

    fn add(self: *Capture, message: []const u8) void {
        if (!self.open) return;
        if (self.count == maximum_entries) {
            self.dropped += 1;
            return;
        }
        self.lengths[self.count] = percentEncode(&self.entries[self.count], message);
        self.count += 1;
    }
};

/// A request's label and `dbg` capture. A request fiber keeps its own in
/// its `Locals` (`fiber.zig`), so they follow it to another thread; code off
/// a fiber (stream steps) uses this thread's.
pub const State = struct {
    /// Meaningful while `labeled`. Not an optional: setting a `?Label` to
    /// null fills its bytes in a safe build, on every request.
    label: Label = .{},
    labeled: bool = false,
    capture: Capture = .{},
    dropped_buffer: [20]u8 = undefined,

    pub fn reset(self: *State) void {
        self.labeled = false;
        self.capture.reset(false);
    }

    pub fn currentLabel(self: *const State) ?*const Label {
        return if (self.labeled) &self.label else null;
    }
};

threadlocal var thread_state: State = .{};

fn state() *State {
    if (fiber.currentLocals()) |locals| return &locals.debug;
    return &thread_state;
}

/// Names the request about to run and, in debug mode, starts collecting its
/// `dbg` output.
pub fn beginRequest(
    method: []const u8,
    target: []const u8,
    request_id: ?[]const u8,
    traceparent: ?[]const u8,
) void {
    const current = state();
    current.label.set(method, target, request_id, traceparent);
    current.labeled = true;
    current.capture.reset(enabled);
}

/// Names the request a streaming response belongs to while one of its
/// producer steps runs. Its head is already sent, so nothing is captured.
pub fn beginStreamStep(request: *const Label) void {
    const current = state();
    current.label = request.*;
    current.labeled = true;
    current.capture.reset(false);
}

pub fn endRequest() void {
    state().reset();
}

pub fn currentLabel() ?*const Label {
    return state().currentLabel();
}

pub fn recordDbg(message: []const u8) void {
    state().capture.add(message);
}

/// Head space left for the captured fields; see `bridge.responseExtraRoom`.
pub const Room = struct {
    bytes: usize,
    fields: usize,
};

const dbg_field_name = "X-Roxum-Dbg";
const truncated_field_name = "X-Roxum-Dbg-Truncated";
/// `X-Roxum-Dbg-Truncated: <up to 20 digits>\r\n`
const truncated_field_bytes = truncated_field_name.len + 2 + 20 + 2;

/// The fields to add to the response head, then stops collecting. Empty
/// outside debug mode or when the handler called no `dbg`. Entries that do
/// not fit in `room` are counted in `X-Roxum-Dbg-Truncated`, so debug mode
/// never turns a response that fits into a 500.
pub fn takeResponseHeaders(output: *[maximum_headers]http1.Header, room: Room) []const http1.Header {
    const current = state();
    const capture = &current.capture;
    defer capture.open = false;
    if (!capture.open) return output[0..0];
    var used: usize = 0;
    var count: usize = 0;
    for (0..capture.count) |index| {
        const value = capture.entries[index][0..capture.lengths[index]];
        const field_bytes = dbg_field_name.len + 2 + value.len + 2;
        // Leave room for the truncation field in case a later entry is cut.
        if (count + 2 > room.fields or used + field_bytes + truncated_field_bytes > room.bytes) break;
        output[count] = .{ .name = dbg_field_name, .value = value };
        used += field_bytes;
        count += 1;
    }
    const dropped = capture.dropped + (capture.count - count);
    if (dropped > 0 and count < room.fields and used + truncated_field_bytes <= room.bytes) {
        output[count] = .{
            .name = truncated_field_name,
            .value = std.fmt.bufPrint(&current.dropped_buffer, "{d}", .{dropped}) catch unreachable,
        };
        count += 1;
    }
    return output[0..count];
}

/// Writes `message` as a field value: `%`, controls, and non-ASCII bytes
/// become `%XX`. Output stops at a whole escape when the entry is full.
fn percentEncode(output: *[maximum_entry_bytes]u8, message: []const u8) usize {
    const hex = "0123456789ABCDEF";
    var length: usize = 0;
    for (message) |byte| {
        const plain = byte >= ' ' and byte < 0x7f and byte != '%';
        const width: usize = if (plain) 1 else 3;
        if (length + width > output.len) break;
        if (plain) {
            output[length] = byte;
        } else {
            output[length] = '%';
            output[length + 1] = hex[byte >> 4];
            output[length + 2] = hex[byte & 0x0f];
        }
        length += width;
    }
    return length;
}

/// `<prefix>pid=<pid>[ <method> <path>][ request_id=..][ traceparent=..]: <message>\n`
/// with control bytes in `message` escaped, or null when it does not fit in
/// `buffer`.
pub fn formatLine(
    buffer: []u8,
    prefix: []const u8,
    pid: c_int,
    request: ?*const Label,
    message: []const u8,
) ?[]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writeLine(&writer, prefix, pid, request, message) catch return null;
    return writer.buffered();
}

fn writeLine(
    writer: *std.Io.Writer,
    prefix: []const u8,
    pid: c_int,
    request: ?*const Label,
    message: []const u8,
) std.Io.Writer.Error!void {
    try writer.print("{s}pid={d}", .{ prefix, pid });
    if (request) |value| {
        try writer.print(" {s} {s}", .{ value.method.slice(), value.path.slice() });
        if (value.request_id.len > 0) try writer.print(" request_id={s}", .{value.request_id.slice()});
        if (value.traceparent.len > 0) try writer.print(" traceparent={s}", .{value.traceparent.slice()});
    }
    try writer.writeAll(": ");
    try log_text.writeEscaped(writer, message);
    try writer.writeByte('\n');
}

test "the label drops the query and neutralizes unprintable bytes" {
    const value = Label.init("GET", "/users/42?token=secret", "id\x01x", null);
    try std.testing.expectEqualStrings("/users/42", value.path.slice());
    try std.testing.expectEqualStrings("id?x", value.request_id.slice());
    try std.testing.expectEqual(@as(usize, 0), value.traceparent.len);
}

test "a long label value is cut with an ellipsis" {
    const long_path = "/" ++ "a" ** 300;
    const value = Label.init("GET", long_path, null, null);
    try std.testing.expectEqual(maximum_path_bytes, value.path.len);
    try std.testing.expect(std.mem.endsWith(u8, value.path.slice(), "..."));
}

test "log lines carry the request and fall back without one" {
    var buffer: [256]u8 = undefined;
    const value = Label.init("GET", "/users/42?x=1", "abc123", null);
    try std.testing.expectEqualStrings(
        "Roc crashed: pid=7 GET /users/42 request_id=abc123: boom\n",
        formatLine(&buffer, "Roc crashed: ", 7, &value, "boom").?,
    );
    try std.testing.expectEqualStrings(
        "[dbg] pid=7: \"x\"\n",
        formatLine(&buffer, "[dbg] ", 7, null, "\"x\"").?,
    );
    var small: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), formatLine(&small, "[dbg] ", 7, null, "x"));
}

test "a message cannot start a new log line" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "[dbg] pid=7: a\\x0A[dbg] pid=1: forged\n",
        formatLine(&buffer, "[dbg] ", 7, null, "a\n[dbg] pid=1: forged").?,
    );
}

test "percent encoding keeps field values printable and stops at whole escapes" {
    var output: [maximum_entry_bytes]u8 = undefined;
    const length = percentEncode(&output, "a b%\n\xe3");
    try std.testing.expectEqualStrings("a b%25%0A%E3", output[0..length]);

    const long = "\n" ** maximum_entry_bytes;
    const cut = percentEncode(&output, long);
    try std.testing.expectEqual(@as(usize, (maximum_entry_bytes / 3) * 3), cut);
}

const unlimited = Room{ .bytes = std.math.maxInt(usize), .fields = std.math.maxInt(usize) };

test "capture attaches only in debug mode and counts what it drops" {
    var headers: [maximum_headers]http1.Header = undefined;
    const saved = enabled;
    defer enabled = saved;

    enabled = false;
    beginRequest("GET", "/", null, null);
    recordDbg("hidden");
    try std.testing.expectEqual(@as(usize, 0), takeResponseHeaders(&headers, unlimited).len);
    endRequest();

    enabled = true;
    beginRequest("GET", "/", null, null);
    for (0..maximum_entries + 2) |_| recordDbg("\"x\"");
    const attached = takeResponseHeaders(&headers, unlimited);
    try std.testing.expectEqual(maximum_headers, attached.len);
    try std.testing.expectEqualStrings("\"x\"", attached[0].value);
    try std.testing.expectEqualStrings("X-Roxum-Dbg-Truncated", attached[maximum_entries].name);
    try std.testing.expectEqualStrings("2", attached[maximum_entries].value);

    // After the head is encoded, later output is no longer attached.
    recordDbg("late");
    try std.testing.expectEqual(@as(usize, 0), takeResponseHeaders(&headers, unlimited).len);
    endRequest();
}

test "captured fields stop where the head runs out of room" {
    var headers: [maximum_headers]http1.Header = undefined;
    const saved = enabled;
    defer enabled = saved;
    enabled = true;

    // Each entry is `X-Roxum-Dbg: "x"\r\n`, 18 bytes.
    const entry_bytes = dbg_field_name.len + 2 + 3 + 2;
    const fits_two = 2 * entry_bytes + truncated_field_bytes;
    const Case = struct { bytes: usize, kept: usize };
    for ([_]Case{
        .{ .bytes = fits_two - 1, .kept = 1 },
        .{ .bytes = fits_two, .kept = 2 },
        .{ .bytes = fits_two + 1, .kept = 2 },
    }) |case| {
        beginRequest("GET", "/", null, null);
        for (0..4) |_| recordDbg("\"x\"");
        const attached = takeResponseHeaders(&headers, .{ .bytes = case.bytes, .fields = 128 });
        try std.testing.expectEqual(case.kept + 1, attached.len);
        try std.testing.expectEqualStrings(truncated_field_name, attached[case.kept].name);
        var expected_dropped: [20]u8 = undefined;
        try std.testing.expectEqualStrings(
            std.fmt.bufPrint(&expected_dropped, "{d}", .{4 - case.kept}) catch unreachable,
            attached[case.kept].value,
        );
        endRequest();
    }

    // No room even for the truncation field: nothing is attached.
    beginRequest("GET", "/", null, null);
    recordDbg("\"x\"");
    try std.testing.expectEqual(@as(usize, 0), takeResponseHeaders(&headers, .{ .bytes = truncated_field_bytes - 1, .fields = 128 }).len);
    endRequest();

    // The field count limits too: two slots keep one entry and the marker.
    beginRequest("GET", "/", null, null);
    for (0..3) |_| recordDbg("\"x\"");
    const by_count = takeResponseHeaders(&headers, .{ .bytes = std.math.maxInt(usize), .fields = 2 });
    try std.testing.expectEqual(@as(usize, 2), by_count.len);
    try std.testing.expectEqualStrings("2", by_count[1].value);
    endRequest();
}
