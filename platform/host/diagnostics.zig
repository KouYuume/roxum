const std = @import("std");
const log_text = @import("log_text.zig");
const request_debug = @import("request_debug.zig");
const stdio = @import("stdio.zig");

// `_exit` skips atexit handlers and stdio flushing, which would otherwise run
// while the process's other threads keep going. stderr is unbuffered.
extern "c" fn _exit(
    status: c_int,
) noreturn;

fn writeStderr(bytes: []const u8) void {
    stdio.writeStderr(bytes) catch return;
}

/// Writes text that came from the application, with control bytes escaped.
fn writeApplicationText(bytes: []const u8) void {
    var buffer: [1024]u8 = undefined;
    log_text.writeStderrEscaped(&buffer, bytes) catch return;
}

/// Logs `dbg` output with the request it came from, and hands it to debug
/// mode's response capture.
pub fn debug(
    bytes: [*]const u8,
    len: usize,
) void {
    const message = bytes[0..len];
    request_debug.recordDbg(message);
    writeRequestLine("[dbg] ", message);
}

pub fn expectFailed(
    bytes: [*]const u8,
    len: usize,
) void {
    stdio.stderr_lock.lock();
    defer stdio.stderr_lock.unlock();
    writeStderr("Roc expectation failed: ");
    writeApplicationText(bytes[0..len]);
    writeStderr("\n");
}

pub fn crashed(
    bytes: [*]const u8,
    len: usize,
) noreturn {
    requestCrashed(bytes, len);
    _exit(1);
}

/// The crash line alone, for a crash that stops only its request.
pub fn requestCrashed(
    bytes: [*]const u8,
    len: usize,
) void {
    writeRequestLine("Roc crashed: ", bytes[0..len]);
}

/// Worker processes share stderr, so a line that fits is written at once
/// and cannot interleave with another process's output.
fn writeRequestLine(prefix: []const u8, message: []const u8) void {
    stdio.stderr_lock.lock();
    defer stdio.stderr_lock.unlock();
    var buffer: [4 * 1024]u8 = undefined;
    const pid = std.c.getpid();
    const request = request_debug.currentLabel();
    if (request_debug.formatLine(&buffer, prefix, pid, request, message)) |line| {
        writeStderr(line);
        return;
    }
    // The message alone is too long; the label still fits (it is bounded).
    const label_line = request_debug.formatLine(&buffer, prefix, pid, request, "").?;
    writeStderr(label_line[0 .. label_line.len - 1]);
    log_text.writeStderrEscaped(&buffer, message) catch return;
    writeStderr("\n");
}

pub fn hostFailed(err: anyerror) void {
    stdio.stderr_lock.lock();
    defer stdio.stderr_lock.unlock();
    writeStderr("roxum host failed: ");
    writeStderr(@errorName(err));
    writeStderr("\n");
}

pub fn startupFailed(message: []const u8) void {
    stdio.stderr_lock.lock();
    defer stdio.stderr_lock.unlock();
    writeStderr("roxum application startup failed: ");
    writeApplicationText(message);
    writeStderr("\n");
}

/// A host warning about the request the Roc thread is running.
pub fn requestWarning(message: []const u8) void {
    writeRequestLine("roxum warning: ", message);
}

pub fn warning(message: []const u8) void {
    stdio.stderr_lock.lock();
    defer stdio.stderr_lock.unlock();
    writeStderr("roxum warning: ");
    writeStderr(message);
    writeStderr("\n");
}

pub fn fatal(message: []const u8) noreturn {
    stdio.stderr_lock.lock();
    defer stdio.stderr_lock.unlock();
    writeStderr("roxum host fatal: ");
    writeStderr(message);
    writeStderr("\n");
    _exit(1);
}
