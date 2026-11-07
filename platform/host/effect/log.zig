const abi = @import("../roc_platform_abi.zig");
const allocator_context = @import("../allocator/context.zig");
const log_text = @import("../log_text.zig");
const runtime = @import("../runtime.zig");
const std = @import("std");
const stdio = @import("../stdio.zig");

pub fn hostedLogWrite(
    level: u8,
    message: abi.RocStr,
) callconv(std.builtin.CallingConvention.c) void {
    defer decrefOwned(message);

    var line_buffer: [single_write_line_bytes]u8 = undefined;
    const line = formatLine(&line_buffer, level, message.asSlice());

    // The lock only orders threads within this process (see
    // `stdio.stderr_lock`), and is held for the writes alone.
    stdio.stderr_lock.lock();
    defer stdio.stderr_lock.unlock();

    if (line) |bytes| {
        stdio.writeStderr(bytes) catch return;
        return;
    }
    stdio.writeStderr(levelPrefix(level)) catch return;
    log_text.writeStderrEscaped(&line_buffer, message.asSlice()) catch return;
    stdio.writeStderr("\n") catch return;
}

const single_write_line_bytes: usize = 4 * 1024;

/// Builds `prefix message\n` in `buffer` with control bytes escaped, or
/// returns `null` when the line does not fit and must be written in parts.
fn formatLine(buffer: []u8, level: u8, message: []const u8) ?[]const u8 {
    const prefix = levelPrefix(level);
    if (prefix.len + 1 > buffer.len) return null;
    @memcpy(buffer[0..prefix.len], prefix);
    const escaped = log_text.escapeInto(buffer[prefix.len .. buffer.len - 1], message);
    if (escaped.read < message.len) return null;
    const length = prefix.len + escaped.written + 1;
    buffer[length - 1] = '\n';
    return buffer[0..length];
}

fn decrefOwned(message: abi.RocStr) void {
    const context = allocator_context.current() orelse
        @panic("allocator context is not set");
    var roc_host = runtime.makeRocHost(
        @ptrCast(context.host_allocator),
    );
    message.decref(&roc_host);
}

fn levelPrefix(level: u8) []const u8 {
    return switch (level) {
        0 => "[DEBUG] ",
        1 => "[INFO] ",
        2 => "[WARN] ",
        3 => "[ERROR] ",
        else => "[UNKNOWN] ",
    };
}

test "a line is built in one buffer up to its capacity" {
    var buffer: [16]u8 = undefined;
    // "[INFO] " is 7 bytes, so 8 message bytes plus the newline fill 16.
    try std.testing.expectEqualStrings(
        "[INFO] 12345678\n",
        formatLine(&buffer, 1, "12345678").?,
    );
    try std.testing.expectEqualStrings(
        "[INFO] 1234567\n",
        formatLine(&buffer, 1, "1234567").?,
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        formatLine(&buffer, 1, "123456789"),
    );
}

test "escaped bytes count toward the line capacity" {
    var buffer: [16]u8 = undefined;
    // "[INFO] " (7) + "1234" (4) + "\x0A" (4) + "\n" (1) is exactly 16.
    try std.testing.expectEqualStrings(
        "[INFO] 1234\\x0A\n",
        formatLine(&buffer, 1, "1234\n").?,
    );
    try std.testing.expectEqualStrings(
        "[INFO] 123\\x0A\n",
        formatLine(&buffer, 1, "123\n").?,
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        formatLine(&buffer, 1, "12345\n"),
    );
}

test "level prefixes cover the public codes" {
    try std.testing.expectEqualStrings(
        "[DEBUG] ",
        levelPrefix(0),
    );
    try std.testing.expectEqualStrings(
        "[INFO] ",
        levelPrefix(1),
    );
    try std.testing.expectEqualStrings(
        "[WARN] ",
        levelPrefix(2),
    );
    try std.testing.expectEqualStrings(
        "[ERROR] ",
        levelPrefix(3),
    );
    try std.testing.expectEqualStrings(
        "[UNKNOWN] ",
        levelPrefix(4),
    );
}
