const std = @import("std");
const errno = @import("net/errno.zig");
const sync = @import("sync.zig");

const stdout_fd: c_int = 1;
const stderr_fd: c_int = 2;

extern "c" fn write(
    fd: c_int,
    buffer: *const anyopaque,
    length: usize,
) isize;

pub const Error = error{
    WriteFailed,
};

pub fn writeStdout(bytes: []const u8) Error!void {
    try writeAll(stdout_fd, bytes);
}

pub fn writeStdoutPort(port: u16) Error!void {
    var buffer: [6]u8 = undefined;
    try writeStdout(formatPort(port, &buffer));
}

/// The port line the supervisor publishes: the decimal port and a newline.
fn formatPort(port: u16, buffer: *[6]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}\n", .{port}) catch unreachable;
}

pub fn writeStderr(bytes: []const u8) Error!void {
    try writeAll(stderr_fd, bytes);
}

/// Orders this process's threads writing whole lines to stderr (the app's
/// `Log` and the access log), so a line written in parts is not split by
/// another. Worker processes share stderr too: a line written with one
/// write(2) of at most PIPE_BUF bytes (512 on macOS, 4096 on Linux) cannot
/// interleave with another process's output; longer lines may.
pub var stderr_lock = sync.Mutex{};

/// Writes one complete line under `stderr_lock`. A failed write is dropped:
/// there is nowhere else to report it.
pub fn writeStderrLine(line: []const u8) void {
    stderr_lock.lock();
    defer stderr_lock.unlock();
    writeStderr(line) catch {};
}

fn writeAll(fd: c_int, bytes: []const u8) Error!void {
    var written: usize = 0;

    while (written < bytes.len) {
        const result = write(
            fd,
            bytes[written..].ptr,
            bytes.len - written,
        );

        if (result > 0) {
            written += @intCast(result);
            continue;
        }
        if (result == -1 and errno.lastError() == std.c.E.INTR) continue;
        return error.WriteFailed;
    }
}

test "the port line fits the largest port" {
    var buffer: [6]u8 = undefined;
    try std.testing.expectEqualStrings("65534\n", formatPort(std.math.maxInt(u16) - 1, &buffer));
    try std.testing.expectEqualStrings("65535\n", formatPort(std.math.maxInt(u16), &buffer));
    try std.testing.expectEqualStrings("0\n", formatPort(0, &buffer));
}
