const std = @import("std");
const host = @import("host");
extern "c" fn pause() c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

/// Appends this worker's process ID to the file named by
/// ROXUM_TEST_START_LOG, so the test counts every start, however short.
fn logStart() void {
    const path = std.c.getenv("ROXUM_TEST_START_LOG") orelse return;
    const file = std.c.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true }, @as(std.c.mode_t, 0o600));
    if (file < 0) return;
    defer _ = std.c.close(file);
    var buffer: [24]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{d}\n", .{std.c.getpid()}) catch return;
    _ = std.c.write(file, line.ptr, line.len);
}

fn worker(_: ?u16) c_int {
    logStart();
    const startup_stall = std.c.getenv("ROXUM_TEST_STARTUP_STALL") != null and
        host.supervisor.inherited_listener != null;
    const restart_stall = if (std.c.getenv("ROXUM_TEST_STALL_FILE")) |path| access(path, 0) == 0 else false;
    if (startup_stall or restart_stall) {
        while (true) {
            _ = pause();
        }
    }
    const listener = host.supervisor.inherited_listener orelse
        (host.net.listenIpv4(.{ 127, 0, 0, 1 }, 0) catch return 1);
    _ = host.supervisor.notifyReady(listener, 2, 20_000, null) catch return 1;
    while (true) {
        _ = pause();
    }
}

pub fn main() !void {
    try host.supervisor.run(worker, .{
        .readiness_timeout_milliseconds = 200,
    });
}
