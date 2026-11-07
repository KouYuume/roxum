//! Escaping for text that application code writes to the shared stderr log.
//!
//! Messages come from `Log.write!`, `dbg`, `expect`, and crashes, so they can
//! carry request data. A raw line break would let a client forge a log line,
//! and other control bytes can drive the reader's terminal.
const std = @import("std");
const stdio = @import("stdio.zig");

const escape_width: usize = 4;

/// C0 controls other than tab, and DEL. Bytes from 0x80 pass through so
/// UTF-8 text stays readable.
pub fn needsEscape(byte: u8) bool {
    return (byte < ' ' and byte != '\t') or byte == 0x7f;
}

pub const Escaped = struct {
    read: usize,
    written: usize,
};

/// Copies `message` into `output`, writing each byte that `needsEscape` as
/// `\xNN`. Stops when either runs out and never splits an escape.
pub fn escapeInto(output: []u8, message: []const u8) Escaped {
    const hex = "0123456789ABCDEF";
    var read: usize = 0;
    var written: usize = 0;
    for (message) |byte| {
        const escape = needsEscape(byte);
        const width: usize = if (escape) escape_width else 1;
        if (written + width > output.len) break;
        if (escape) {
            output[written..][0..escape_width].* = .{ '\\', 'x', hex[byte >> 4], hex[byte & 0x0f] };
        } else {
            output[written] = byte;
        }
        written += width;
        read += 1;
    }
    return .{ .read = read, .written = written };
}

/// Writes `message` escaped through a fixed-size writer.
pub fn writeEscaped(writer: *std.Io.Writer, message: []const u8) std.Io.Writer.Error!void {
    var rest = message;
    while (rest.len > 0) {
        const output = writer.unusedCapacitySlice();
        const escaped = escapeInto(output, rest);
        if (escaped.read == 0) return error.WriteFailed;
        writer.advance(escaped.written);
        rest = rest[escaped.read..];
    }
}

/// Writes `message` escaped to stderr, one `buffer` at a time. For messages
/// too long to form a single line.
pub fn writeStderrEscaped(buffer: []u8, message: []const u8) stdio.Error!void {
    std.debug.assert(buffer.len >= escape_width);
    var rest = message;
    while (rest.len > 0) {
        const escaped = escapeInto(buffer, rest);
        try stdio.writeStderr(buffer[0..escaped.written]);
        rest = rest[escaped.read..];
    }
}

test "line breaks, terminal controls, and DEL are escaped; tab and UTF-8 are kept" {
    var output: [64]u8 = undefined;
    const message = "a\nb\r\x1b[31m\t\x7f\x00\xe3\x81\x82";
    const escaped = escapeInto(&output, message);
    try std.testing.expectEqual(message.len, escaped.read);
    try std.testing.expectEqualStrings(
        "a\\x0Ab\\x0D\\x1B[31m\t\\x7F\\x00\xe3\x81\x82",
        output[0..escaped.written],
    );
}

test "the escape boundary sits at space and DEL" {
    try std.testing.expect(needsEscape(0x1f));
    try std.testing.expect(!needsEscape(' '));
    try std.testing.expect(!needsEscape(0x7e));
    try std.testing.expect(needsEscape(0x7f));
    try std.testing.expect(!needsEscape(0x80));
}

test "an escape is never split across the end of the output" {
    var output: [5]u8 = undefined;
    // "a" plus one 4-byte escape fill 5 bytes; the second escape does not fit.
    const escaped = escapeInto(&output, "a\n\n");
    try std.testing.expectEqual(@as(usize, 2), escaped.read);
    try std.testing.expectEqualStrings("a\\x0A", output[0..escaped.written]);

    const short = escapeInto(output[0..4], "a\n");
    try std.testing.expectEqual(@as(usize, 1), short.read);
    try std.testing.expectEqualStrings("a", output[0..short.written]);
}

test "the writer form fails when the escaped text does not fit" {
    var buffer: [8]u8 = undefined;
    var fits = std.Io.Writer.fixed(&buffer);
    try writeEscaped(&fits, "ab\ncd");
    try std.testing.expectEqualStrings("ab\\x0Acd", fits.buffered());

    var full = std.Io.Writer.fixed(buffer[0..7]);
    try std.testing.expectError(error.WriteFailed, writeEscaped(&full, "ab\ncd"));
}
