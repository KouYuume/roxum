//! How many threads `Server.Threads.Auto` runs, and the bounds on threads
//! and processes.
const std = @import("std");
const builtin = @import("builtin");

/// The most processes one server runs.
pub const maximum = 64;
/// The most threads one process runs.
pub const maximum_threads = 256;

/// One thread per CPU the process may use, from 1 to `maximum_threads`. On
/// Linux a cgroup v2 CPU limit (`cpu.max`) lowers the count, so a container
/// given two CPUs on a larger machine runs two threads.
pub fn automatic() usize {
    return countFor(std.Thread.getCpuCount() catch 1, cgroupCpuLimit());
}

pub fn countFor(detected: usize, cgroup_limit: ?usize) usize {
    const usable = if (cgroup_limit) |limit| @min(detected, limit) else detected;
    return std.math.clamp(usable, 1, maximum_threads);
}

/// The CPU limit of the process's cgroup, rounded up to whole CPUs. The
/// path is the cgroup namespace's root, which is the container's own cgroup
/// under Docker and Kubernetes with cgroup v2.
fn cgroupCpuLimit() ?usize {
    if (builtin.os.tag != .linux) return null;
    const descriptor = std.c.open("/sys/fs/cgroup/cpu.max", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (descriptor < 0) return null;
    defer _ = std.c.close(descriptor);
    var buffer: [64]u8 = undefined;
    const count = std.c.read(descriptor, &buffer, buffer.len);
    if (count <= 0) return null;
    return parseCpuMax(buffer[0..@intCast(count)]);
}

/// `cpu.max` holds `<quota> <period>` in microseconds, or `max <period>`
/// without a limit.
pub fn parseCpuMax(text: []const u8) ?usize {
    const line = std.mem.trimEnd(u8, text, "\n");
    var fields = std.mem.splitScalar(u8, line, ' ');
    const quota_text = fields.next() orelse return null;
    const period_text = fields.next() orelse return null;
    if (fields.next() != null) return null;
    if (std.mem.eql(u8, quota_text, "max")) return null;
    const quota = std.fmt.parseInt(u64, quota_text, 10) catch return null;
    const period = std.fmt.parseInt(u64, period_text, 10) catch return null;
    if (quota == 0 or period == 0) return null;
    return std.math.cast(usize, std.math.divCeil(u64, quota, period) catch return null);
}

test "the thread count clamps logical CPU boundaries" {
    try std.testing.expectEqual(@as(usize, 1), countFor(0, null));
    try std.testing.expectEqual(@as(usize, 1), countFor(1, null));
    try std.testing.expectEqual(@as(usize, 2), countFor(2, null));
    try std.testing.expectEqual(@as(usize, 255), countFor(255, null));
    try std.testing.expectEqual(@as(usize, 256), countFor(256, null));
    try std.testing.expectEqual(@as(usize, 256), countFor(257, null));
}

test "a cgroup CPU limit lowers the thread count but never raises it" {
    try std.testing.expectEqual(@as(usize, 2), countFor(8, 2));
    try std.testing.expectEqual(@as(usize, 4), countFor(4, 16));
    try std.testing.expectEqual(@as(usize, 100), countFor(128, 100));
}

test "cpu.max is read as whole CPUs, rounded up" {
    try std.testing.expectEqual(@as(?usize, null), parseCpuMax("max 100000\n"));
    try std.testing.expectEqual(@as(?usize, 2), parseCpuMax("200000 100000\n"));
    try std.testing.expectEqual(@as(?usize, 1), parseCpuMax("50000 100000\n"));
    try std.testing.expectEqual(@as(?usize, 2), parseCpuMax("150000 100000"));
    try std.testing.expectEqual(@as(?usize, 1), parseCpuMax("1 100000\n"));
}

test "a malformed cpu.max means no limit" {
    for ([_][]const u8{ "", "\n", "100000", "0 100000", "100000 0", "abc 100000", "100000 100000 1", "-1 100000" }) |text| {
        try std.testing.expectEqual(@as(?usize, null), parseCpuMax(text));
    }
}
