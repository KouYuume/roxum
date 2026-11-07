//! Files under roots the app opens at startup. A root is a directory
//! held open; a file is opened beneath it, and neither a path nor a
//! symbolic link leads out of it: Linux resolves the path with `openat2`'s
//! `RESOLVE_BENEATH`, and macOS checks where the opened file really is
//! (`F_GETPATH`). Both leave links within the root working, as Go's
//! `os.Root` does. Opening and reading block the thread, so on a request
//! fiber they run on a blocking-work thread.
const std = @import("std");
const builtin = @import("builtin");
const errno = @import("net/errno.zig");
const sync = @import("sync.zig");

pub const RootError = error{ NotFound, NotDirectory, PermissionDenied, Failed };
pub const OpenError = error{ NotFound, Failed };

/// Roots a process may open. A root is held until the process ends.
const maximum_roots = 64;

const Root = struct {
    descriptor: c_int,
    /// Where the root really is, for macOS to check opened files against.
    real_path: [std.fs.max_path_bytes]u8 = undefined,
    real_length: usize = 0,

    fn realPath(self: *const Root) []const u8 {
        return self.real_path[0..self.real_length];
    }
};

var roots_lock: sync.Mutex = .{};
var roots: [maximum_roots]Root = undefined;
var root_count = std.atomic.Value(usize).init(0);

/// Opens the directory at `path` as a root; its handle is never 0.
pub fn openRoot(path: []const u8) RootError!u64 {
    var path_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len == 0 or path.len >= path_buffer.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.NotFound;
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;
    const descriptor = std.c.open(&path_buffer, .{ .ACCMODE = std.posix.ACCMODE.RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (descriptor < 0) return switch (errno.lastError()) {
        std.c.E.NOENT => error.NotFound,
        std.c.E.NOTDIR => error.NotDirectory,
        std.c.E.ACCES, std.c.E.PERM => error.PermissionDenied,
        else => error.Failed,
    };
    errdefer _ = std.c.close(descriptor);
    var root = Root{ .descriptor = descriptor };
    if (builtin.os.tag == std.Target.Os.Tag.macos) {
        root.real_length = try realPathOf(descriptor, &root.real_path);
    }
    roots_lock.lock();
    defer roots_lock.unlock();
    const count = root_count.load(std.builtin.AtomicOrder.monotonic);
    if (count == maximum_roots) return error.Failed;
    roots[count] = root;
    root_count.store(count + 1, std.builtin.AtomicOrder.release);
    return count + 1;
}

fn rootOf(handle: u64) ?*const Root {
    const count = root_count.load(std.builtin.AtomicOrder.acquire);
    if (handle == 0 or handle > count) return null;
    return &roots[@intCast(handle - 1)];
}

pub const Entry = struct {
    descriptor: c_int,
    size: u64,
    /// Seconds since the Unix epoch.
    modified_seconds: i64,
    directory: bool,
};

/// Opens `relative`, a path under the root `handle` (empty for the root
/// itself). A path that leads out of the root, an absolute one, one with a
/// NUL byte, and anything but a regular file or a directory are not found.
/// Blocks the thread.
pub fn openBeneath(handle: u64, relative: []const u8) OpenError!Entry {
    const root = rootOf(handle) orelse return error.NotFound;
    var path_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = if (relative.len == 0) "." else relative;
    if (path.len >= path_buffer.len or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.NotFound;
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;
    const descriptor = try openUnder(root, &path_buffer);
    errdefer _ = std.c.close(descriptor);
    const status = try statusOf(descriptor);
    const directory = std.c.S.ISDIR(status.mode);
    if (!directory and !std.c.S.ISREG(status.mode)) return error.NotFound;
    return .{
        .descriptor = descriptor,
        .size = status.size,
        .modified_seconds = status.modified_seconds,
        .directory = directory,
    };
}

const Status = struct { mode: u32, size: u64, modified_seconds: i64 };

/// Zig's libc bindings have no `fstat` on Linux; `statx` gives the same.
fn statusOf(descriptor: c_int) OpenError!Status {
    switch (builtin.os.tag) {
        std.Target.Os.Tag.linux => {
            const linux = std.os.linux;
            var buffer: linux.Statx = undefined;
            const result = linux.statx(descriptor, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .SIZE = true, .MTIME = true }, &buffer);
            if (linux.errno(result) != std.os.linux.E.SUCCESS) return error.Failed;
            return .{ .mode = buffer.mode, .size = buffer.size, .modified_seconds = buffer.mtime.sec };
        },
        else => {
            var stat: std.c.Stat = undefined;
            if (std.c.fstat(descriptor, &stat) != 0) return error.Failed;
            return .{ .mode = @intCast(stat.mode), .size = @intCast(stat.size), .modified_seconds = @intCast(stat.mtime().sec) };
        },
    }
}

/// Non-blocking, so a FIFO placed under the root does not hold the thread.
const open_flags: std.c.O = .{ .ACCMODE = std.posix.ACCMODE.RDONLY, .CLOEXEC = true, .NONBLOCK = true };

fn openUnder(root: *const Root, path: [*:0]const u8) OpenError!c_int {
    return switch (builtin.os.tag) {
        std.Target.Os.Tag.linux => openBeneathLinux(root.descriptor, path),
        std.Target.Os.Tag.macos => openBeneathMac(root, path),
        else => @compileError("files are served on Linux and macOS"),
    };
}

const OpenHow = extern struct {
    flags: u64,
    mode: u64,
    resolve: u64,
};
const resolve_beneath: u64 = 0x08;
const resolve_no_magiclinks: u64 = 0x02;

fn openBeneathLinux(root: c_int, path: [*:0]const u8) OpenError!c_int {
    const linux = std.os.linux;
    var how = OpenHow{
        .flags = @as(u32, @bitCast(open_flags)),
        .mode = 0,
        .resolve = resolve_beneath | resolve_no_magiclinks,
    };
    while (true) {
        const result = linux.syscall4(linux.SYS.openat2, @bitCast(@as(isize, root)), @intFromPtr(path), @intFromPtr(&how), @sizeOf(OpenHow));
        switch (linux.errno(result)) {
            std.os.linux.E.SUCCESS => return @intCast(result),
            std.os.linux.E.INTR => continue,
            // Out of the root (`EXDEV`), missing, or not allowed: all are
            // simply not there for the client.
            std.os.linux.E.XDEV, std.os.linux.E.NOENT, std.os.linux.E.NOTDIR, std.os.linux.E.LOOP, std.os.linux.E.ACCES, std.os.linux.E.PERM, std.os.linux.E.NAMETOOLONG => return error.NotFound,
            else => return error.Failed,
        }
    }
}

fn openBeneathMac(root: *const Root, path: [*:0]const u8) OpenError!c_int {
    const descriptor = while (true) {
        const opened = std.c.openat(root.descriptor, path, open_flags);
        if (opened >= 0) break opened;
        switch (errno.lastError()) {
            std.c.E.INTR => continue,
            std.c.E.NOENT, std.c.E.NOTDIR, std.c.E.LOOP, std.c.E.ACCES, std.c.E.PERM, std.c.E.NAMETOOLONG => return error.NotFound,
            else => return error.Failed,
        }
    };
    errdefer _ = std.c.close(descriptor);
    var real: [std.fs.max_path_bytes]u8 = undefined;
    const length = realPathOf(descriptor, &real) catch return error.Failed;
    if (!isWithin(root.realPath(), real[0..length])) return error.NotFound;
    return descriptor;
}

/// Where the open file `descriptor` really is, links resolved (macOS).
fn realPathOf(descriptor: c_int, buffer: *[std.fs.max_path_bytes]u8) error{Failed}!usize {
    if (std.c.fcntl(descriptor, std.c.F.GETPATH, buffer) != 0) return error.Failed;
    return std.mem.indexOfScalar(u8, buffer, 0) orelse error.Failed;
}

fn isWithin(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    // The root itself may be `/`.
    if (root.len > 0 and root[root.len - 1] == '/') return true;
    return path[root.len] == '/';
}

/// Reads up to `buffer.len` bytes at `offset`; 0 at the end. Blocks the
/// thread.
pub fn readAt(descriptor: c_int, buffer: []u8, offset: u64) error{Failed}!usize {
    while (true) {
        const count = std.c.pread(descriptor, buffer.ptr, buffer.len, @intCast(offset));
        if (count >= 0) return @intCast(count);
        if (errno.lastError() == std.c.E.INTR) continue;
        return error.Failed;
    }
}

pub fn close(descriptor: c_int) void {
    _ = std.c.close(descriptor);
}

test "a path is within a root only below it" {
    try std.testing.expect(isWithin("/srv/public", "/srv/public"));
    try std.testing.expect(isWithin("/srv/public", "/srv/public/a.txt"));
    try std.testing.expect(!isWithin("/srv/public", "/srv/publicity/a.txt"));
    try std.testing.expect(!isWithin("/srv/public", "/srv/private/a.txt"));
    try std.testing.expect(isWithin("/", "/etc/passwd"));
}
