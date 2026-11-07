//! Delivers the supervisor's drain and stop requests to a worker's event
//! loop. The worker ignores SIGTERM and SIGINT, which a process
//! manager may send to every process of the group at once; the supervisor
//! alone turns them into SIGUSR1 (drain) and, for a second one, SIGUSR2
//! (stop now). The handlers only write a byte to a pipe the loop watches,
//! which is safe in a signal handler.
const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const errno = @import("net/errno.zig");

extern "c" fn usleep(microseconds: c_uint) c_int;

pub const drain_signal = std.posix.SIG.USR1;
pub const stop_signal = std.posix.SIG.USR2;

var pipe_fds: [2]c_int = .{ -1, -1 };

/// Creates the pipe; the loop watches `readEnd()`.
pub fn init() error{PipeFailed}!void {
    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    for (fds) |fd| {
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }))) < 0) return error.PipeFailed;
        if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.PipeFailed;
    }
    // The write end last: the handlers check it to tell whether the loop
    // watches yet.
    pipe_fds[0] = fds[0];
    @atomicStore(c_int, &pipe_fds[1], fds[1], std.builtin.AtomicOrder.release);
}

pub fn readEnd() c_int {
    return pipe_fds[0];
}

pub const Requests = struct { drain: bool = false, stop: bool = false };

/// Empties the pipe after the loop saw it readable.
pub fn consume() Requests {
    var requests = Requests{};
    var buffer: [16]u8 = undefined;
    while (true) {
        const read = std.c.read(pipe_fds[0], &buffer, buffer.len);
        if (read <= 0) return requests;
        for (buffer[0..@intCast(read)]) |byte| {
            if (byte == 's') requests.stop = true else requests.drain = true;
        }
    }
}

pub fn handleDrain(_: std.posix.SIG) callconv(std.builtin.CallingConvention.c) void {
    notify("d");
}

pub fn handleStop(_: std.posix.SIG) callconv(std.builtin.CallingConvention.c) void {
    notify("s");
}

/// Asks for a drain when the supervisor is gone, however it ended. A thread waits
/// on a pipe whose write end only the supervisor holds, so the end of the
/// supervisor, even by SIGKILL, ends the pipe. Without this a worker would go on
/// serving with nothing to restart it, and it ignores SIGTERM.
pub fn watchSupervisor(read_end: c_int) void {
    const thread = std.Thread.spawn(.{}, waitForSupervisorEnd, .{read_end}) catch {
        diagnostics.warning("a process could not watch its supervisor; it will outlive a supervisor that is killed");
        return;
    };
    thread.detach();
}

fn waitForSupervisorEnd(read_end: c_int) void {
    var byte: [1]u8 = undefined;
    while (std.c.read(read_end, &byte, 1) != 0) {
        // The supervisor never writes. The drain and stop signals may land here.
        if (errno.lastError() != std.c.E.INTR) break;
    }
    diagnostics.warning("the supervisor is gone; this process is draining and will exit");
    notify("d");
}

/// Before the loop watches the pipe the worker has no connections (it is
/// still starting), so it ends at once.
fn notify(byte: *const [1]u8) void {
    const write_end = @atomicLoad(c_int, &pipe_fds[1], std.builtin.AtomicOrder.acquire);
    if (write_end < 0) std.c._exit(0);
    _ = std.c.write(write_end, byte, 1);
}

test "the pipe tells a drain from a stop" {
    try init();
    defer {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
        pipe_fds = .{ -1, -1 };
    }
    try std.testing.expectEqual(Requests{}, consume());
    handleDrain(drain_signal);
    try std.testing.expectEqual(Requests{ .drain = true }, consume());
    handleDrain(drain_signal);
    handleStop(stop_signal);
    try std.testing.expectEqual(Requests{ .drain = true, .stop = true }, consume());
    try std.testing.expectEqual(Requests{}, consume());
}

test "the end of the supervisor's pipe asks for a drain" {
    try init();
    defer {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
        pipe_fds = .{ -1, -1 };
    }
    var supervisor: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&supervisor));
    defer _ = std.c.close(supervisor[0]);
    watchSupervisor(supervisor[0]);
    try std.testing.expectEqual(Requests{}, consume());
    _ = std.c.close(supervisor[1]);
    var requests = Requests{};
    var waited: usize = 0;
    while (!requests.drain and waited < 500) : (waited += 1) {
        _ = usleep(10_000);
        requests = consume();
    }
    try std.testing.expectEqual(Requests{ .drain = true }, requests);
}
