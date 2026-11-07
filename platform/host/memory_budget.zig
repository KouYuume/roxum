//! How much memory `Server.MemoryLimit.Auto` lets one process's requests
//! hold: the memory the server may use, divided among the
//! processes, less a reserve per thread for what is not request values. On Linux a cgroup v2
//! memory limit (`memory.max`) lowers it, so a container given 1 GiB on a
//! larger machine plans for 1 GiB.
const std = @import("std");
const builtin = @import("builtin");

/// What a thread holds besides its requests' values, estimated for a
/// worker of one thread: the idle worker (about 25 MiB), bodies the loop receives (up to 64 MiB),
/// requests waiting on fibers outside their heaps (1,024 × about 60 KiB),
/// and outbound TLS sessions (about 20 MiB), about 170 MiB, with room.
const reserve_bytes: u64 = 192 * 1024 * 1024;

/// The least a thread's requests get, however small the machine.
const minimum_bytes: u64 = 32 * 1024 * 1024;

pub fn automatic(processes: usize, threads: usize) usize {
    return budgetFor(physicalMemory(), cgroupMemoryLimit(), processes, threads);
}

pub fn budgetFor(physical: ?u64, cgroup_limit: ?u64, processes: usize, threads: usize) usize {
    const known: u64 = if (physical) |bytes|
        (if (cgroup_limit) |limit| @min(bytes, limit) else bytes)
    else
        cgroup_limit orelse return std.math.maxInt(usize);
    const per_process = known / @max(processes, 1);
    const thread_count: u64 = @max(threads, 1);
    return std.math.cast(usize, @max(per_process -| reserve_bytes * thread_count, minimum_bytes * thread_count)) orelse std.math.maxInt(usize);
}

fn physicalMemory() ?u64 {
    switch (builtin.os.tag) {
        std.Target.Os.Tag.macos => {
            var bytes: u64 = 0;
            var length: usize = @sizeOf(u64);
            if (std.c.sysctlbyname("hw.memsize", &bytes, &length, null, 0) != 0) return null;
            return bytes;
        },
        std.Target.Os.Tag.linux => {
            var info: std.os.linux.Sysinfo = undefined;
            if (std.os.linux.sysinfo(&info) != 0) return null;
            return @as(u64, info.totalram) * @max(info.mem_unit, 1);
        },
        else => return null,
    }
}

/// The memory limit of the process's cgroup, as `worker_count` reads the
/// CPU limit.
fn cgroupMemoryLimit() ?u64 {
    if (builtin.os.tag != std.Target.Os.Tag.linux) return null;
    const descriptor = std.c.open("/sys/fs/cgroup/memory.max", .{ .ACCMODE = std.posix.ACCMODE.RDONLY, .CLOEXEC = true });
    if (descriptor < 0) return null;
    defer _ = std.c.close(descriptor);
    var buffer: [64]u8 = undefined;
    const count = std.c.read(descriptor, &buffer, buffer.len);
    if (count <= 0) return null;
    return parseMemoryMax(buffer[0..@intCast(count)]);
}

/// `memory.max` holds a byte count, or `max` without a limit.
pub fn parseMemoryMax(text: []const u8) ?u64 {
    const line = std.mem.trimEnd(u8, text, "\n");
    if (std.mem.eql(u8, line, "max")) return null;
    const bytes = std.fmt.parseInt(u64, line, 10) catch return null;
    if (bytes == 0) return null;
    return bytes;
}

test "the budget is the smaller of physical memory and the cgroup limit, per process, less the reserve" {
    const mib: u64 = 1024 * 1024;
    const gib: u64 = 1024 * mib;
    try std.testing.expectEqual(@as(usize, 320 * mib), budgetFor(8 * gib, gib, 2, 1));
    try std.testing.expectEqual(@as(usize, 2 * gib - 192 * mib), budgetFor(8 * gib, null, 4, 1));
    try std.testing.expectEqual(@as(usize, gib - 192 * mib), budgetFor(null, gib, 1, 1));
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), budgetFor(null, null, 1, 1));
    // A small container: the reserve would leave too little.
    try std.testing.expectEqual(@as(usize, 64 * mib), budgetFor(null, 512 * mib, 2, 1));
    try std.testing.expectEqual(@as(usize, 32 * mib), budgetFor(null, 256 * mib, 2, 1));
    // Threads of one process: the reserve and the floor are per thread.
    try std.testing.expectEqual(@as(usize, 8 * gib - 4 * 192 * mib), budgetFor(8 * gib, null, 1, 4));
    try std.testing.expectEqual(@as(usize, 4 * 32 * mib), budgetFor(null, 512 * mib, 1, 4));
}

test "memory.max is read as bytes, max meaning no limit" {
    try std.testing.expectEqual(@as(?u64, null), parseMemoryMax("max\n"));
    try std.testing.expectEqual(@as(?u64, 1073741824), parseMemoryMax("1073741824\n"));
    for ([_][]const u8{ "", "\n", "0", "-1", "1 2", "abc" }) |text| {
        try std.testing.expectEqual(@as(?u64, null), parseMemoryMax(text));
    }
}
