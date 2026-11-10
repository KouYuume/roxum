//! Filesystem Unix socket names and identity-checked cleanup.
const std = @import("std");
const builtin = @import("builtin");

pub const Path = extern struct {
    bytes: [104]u8 = @splat(0),

    pub fn init(bytes: []const u8) error{InvalidUnixPath}!Path {
        if (bytes.len == 0 or bytes.len > 103 or bytes[0] != '/') return error.InvalidUnixPath;
        if (std.mem.indexOfAny(u8, bytes, "\x00\r\n") != null) return error.InvalidUnixPath;
        var path = Path{};
        @memcpy(path.bytes[0..bytes.len], bytes);
        return path;
    }

    pub fn slice(self: *const Path) []const u8 {
        return std.mem.sliceTo(&self.bytes, 0);
    }

    pub fn terminated(self: *const Path) [*:0]const u8 {
        return @ptrCast(&self.bytes);
    }
};

pub const Owned = extern struct {
    path: Path,
    device: u64,
    inode: u64,

    pub fn capture(path: Path) error{SocketPathFailed}!Owned {
        if (builtin.os.tag == std.Target.Os.Tag.linux) {
            const linux = std.os.linux;
            var stat: linux.Statx = undefined;
            const result = linux.statx(linux.AT.FDCWD, path.terminated(), linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .INO = true }, &stat);
            if (linux.errno(result) != linux.E.SUCCESS) return error.SocketPathFailed;
            if (!stat.mask.TYPE or !stat.mask.INO or (stat.mode & linux.S.IFMT) != linux.S.IFSOCK) return error.SocketPathFailed;
            return .{ .path = path, .device = (@as(u64, stat.dev_major) << 32) | stat.dev_minor, .inode = stat.ino };
        }
        var stat: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, path.terminated(), &stat, std.c.AT.SYMLINK_NOFOLLOW) != 0) return error.SocketPathFailed;
        if ((stat.mode & std.c.S.IFMT) != std.c.S.IFSOCK) return error.SocketPathFailed;
        return .{ .path = path, .device = @intCast(stat.dev), .inode = @intCast(stat.ino) };
    }

    /// The directory must be controlled by the operator. Never remove a
    /// replacement file, symlink, or another server's socket.
    pub fn remove(self: *const Owned) void {
        const current = capture(self.path) catch return;
        if (current.device != self.device or current.inode != self.inode) return;
        _ = std.c.unlink(self.path.terminated());
    }
};

test "Unix paths enforce the portable byte limit and readiness-line contract" {
    for ([_]usize{ 102, 103 }) |length| {
        var bytes: [104]u8 = @splat('a');
        bytes[0] = '/';
        const path = try Path.init(bytes[0..length]);
        try std.testing.expectEqualStrings(bytes[0..length], path.slice());
    }
    var too_long: [104]u8 = @splat('a');
    too_long[0] = '/';
    try std.testing.expectError(error.InvalidUnixPath, Path.init(&too_long));
    _ = try Path.init("/");
    for ([_][]const u8{ "", "relative.sock", "/x\x00y", "/x\ry", "/x\ny" }) |invalid| {
        try std.testing.expectError(error.InvalidUnixPath, Path.init(invalid));
    }
}
