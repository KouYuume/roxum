const std = @import("std");
const builtin = @import("builtin");
const diagnostics = @import("../diagnostics.zig");
const errno = @import("../net/errno.zig");

pub fn hostedRandomU64() callconv(std.builtin.CallingConvention.c) u64 {
    return randomU64();
}

// Both sources are cryptographically secure. arc4random_buf cannot fail;
// getrandom only blocks until the kernel pool is first initialized and never
// returns short for 8 bytes, so a failure is a broken system, not an error
// the app can handle.
pub fn randomU64() u64 {
    var bytes: [8]u8 = undefined;
    fill(&bytes);
    return std.mem.readInt(u64, &bytes, std.builtin.Endian.little);
}

/// Fills `bytes` with random bytes, in one system call for up to 256.
pub fn fill(bytes: []u8) void {
    switch (builtin.os.tag) {
        std.Target.Os.Tag.linux => fillFromKernel(bytes),
        else => std.c.arc4random_buf(bytes.ptr, bytes.len),
    }
}

fn fillFromKernel(bytes: []u8) void {
    var filled: usize = 0;
    while (filled < bytes.len) {
        const result = std.c.getrandom(bytes[filled..].ptr, bytes.len - filled, 0);
        if (result > 0) {
            filled += @intCast(result);
            continue;
        }
        if (result == -1 and errno.lastError() == std.c.E.INTR) continue;
        diagnostics.fatal("getrandom failed");
    }
}

test "consecutive random values are not all identical" {
    const first = randomU64();
    var index: usize = 0;
    while (index < 4) : (index += 1) {
        if (randomU64() != first) return;
    }
    return error.RandomSourceRepeated;
}
