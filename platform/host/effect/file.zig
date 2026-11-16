//! `File.read_bytes!`: reads a whole file, refusing one larger than the
//! caller's limit. Reads block the Roc thread; they are meant for `init!`.
const std = @import("std");
const abi = @import("../roc_platform_abi.zig");
const allocator_context = @import("../allocator/context.zig");
const request_bridge = @import("../bridge/request.zig");
const runtime = @import("../runtime.zig");
const errno = @import("../net/errno.zig");

pub const ReadError = error{ NotFound, PermissionDenied, TooLarge, Failed };

/// The contents of the file at `path`, at most `maximum_bytes` long, in
/// memory from `allocator`.
pub fn readBounded(allocator: std.mem.Allocator, path: []const u8, maximum_bytes: u64) ReadError![]u8 {
    var path_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len == 0 or path.len >= path_buffer.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.Failed;
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;
    const descriptor = std.c.open(&path_buffer, .{ .ACCMODE = std.posix.ACCMODE.RDONLY, .CLOEXEC = true });
    if (descriptor < 0) return switch (errno.lastError()) {
        std.c.E.NOENT, std.c.E.NOTDIR => error.NotFound,
        std.c.E.ACCES, std.c.E.PERM => error.PermissionDenied,
        else => error.Failed,
    };
    defer _ = std.c.close(descriptor);

    const limit = std.math.cast(usize, maximum_bytes) orelse std.math.maxInt(usize);
    var contents: std.ArrayList(u8) = .empty;
    errdefer contents.deinit(allocator);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const remaining = limit - contents.items.len;
        // One extra byte distinguishes an exact-size file from an oversized
        // one without reading a whole chunk beyond the caller's budget.
        const wanted = @min(chunk.len, remaining +| 1);
        const count = std.c.read(descriptor, &chunk, wanted);
        if (count < 0) {
            if (errno.lastError() == std.c.E.INTR) continue;
            // A directory opens but fails to read.
            return error.Failed;
        }
        if (count == 0) break;
        const read: usize = @intCast(count);
        if (read > remaining) return error.TooLarge;
        contents.appendSlice(allocator, chunk[0..read]) catch return error.Failed;
    }
    return contents.toOwnedSlice(allocator) catch error.Failed;
}

pub fn hostedFileRead(path: abi.RocStr, maximum_bytes: u64) callconv(std.builtin.CallingConvention.c) abi.HostFileRead {
    const context = allocator_context.current() orelse @panic("allocator context is not set");
    var roc_host = runtime.makeRocHost(@ptrCast(context.host_allocator));
    defer path.decref(&roc_host);
    const contents = readBounded(std.heap.smp_allocator, path.asSlice(), maximum_bytes) catch |err| return withTag(switch (err) {
        error.NotFound => abi.HostFileReadTag.NotFound,
        error.PermissionDenied => abi.HostFileReadTag.PermissionDenied,
        error.TooLarge => abi.HostFileReadTag.TooLarge,
        error.Failed => abi.HostFileReadTag.Failed,
    });
    defer std.heap.smp_allocator.free(contents);
    const list = request_bridge.rocByteListFromSliceChecked(
        contents,
        .{ .roc_host = &roc_host, .try_alloc = runtime.tryAllocWithHost },
    ) catch return withTag(abi.HostFileReadTag.Failed);
    var result: abi.HostFileRead = undefined;
    result.tag = abi.HostFileReadTag.Bytes;
    const payload: *abi.RocListWith(u8, false) = @ptrCast(@alignCast(&result.payload));
    payload.* = list;
    return result;
}

fn withTag(tag: abi.HostFileReadTag) abi.HostFileRead {
    var result: abi.HostFileRead = undefined;
    result.tag = tag;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    return result;
}

/// A path for a test file in `$TMPDIR`, or `/tmp` without it.
pub fn testPath(buffer: []u8, label: []const u8) ![:0]u8 {
    const directory = if (std.c.getenv("TMPDIR")) |value| std.mem.trimEnd(u8, std.mem.span(value), "/") else "/tmp";
    return std.fmt.bufPrintSentinel(buffer, "{s}/roxum-{s}-{d}", .{ directory, label, std.c.getpid() }, 0);
}

const TestFile = struct {
    path: [512:0]u8 = undefined,
    len: usize = 0,

    fn create(contents: []const u8, mode: std.c.mode_t) !TestFile {
        var self = TestFile{};
        var label: [32]u8 = undefined;
        const name = try testPath(&self.path, try std.fmt.bufPrint(&label, "file-test-{d}", .{contents.len}));
        self.len = name.len;
        const descriptor = std.c.open(name.ptr, .{ .ACCMODE = std.posix.ACCMODE.WRONLY, .CREAT = true, .TRUNC = true }, mode);
        if (descriptor < 0) return error.CreateFailed;
        defer _ = std.c.close(descriptor);
        if (contents.len > 0 and std.c.write(descriptor, contents.ptr, contents.len) != @as(isize, @intCast(contents.len))) return error.WriteFailed;
        return self;
    }

    fn slice(self: *const TestFile) []const u8 {
        return self.path[0..self.len];
    }

    fn remove(self: *const TestFile) void {
        _ = std.c.unlink(&self.path);
    }
};

test "a file is read when its size is below or at the limit and refused above it" {
    const file = try TestFile.create("12345", 0o600);
    defer file.remove();
    const below = try readBounded(std.testing.allocator, file.slice(), 6);
    defer std.testing.allocator.free(below);
    try std.testing.expectEqualStrings("12345", below);
    const at = try readBounded(std.testing.allocator, file.slice(), 5);
    defer std.testing.allocator.free(at);
    try std.testing.expectEqualStrings("12345", at);
    try std.testing.expectError(error.TooLarge, readBounded(std.testing.allocator, file.slice(), 4));
}

test "an empty file is read with a zero limit" {
    const file = try TestFile.create("", 0o600);
    defer file.remove();
    const contents = try readBounded(std.testing.allocator, file.slice(), 0);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 0), contents.len);
}

test "missing files, directories, and bad paths are told apart" {
    var missing: [512]u8 = undefined;
    try std.testing.expectError(error.NotFound, readBounded(std.testing.allocator, try testPath(&missing, "file-test-missing"), 10));
    try std.testing.expectError(error.NotFound, readBounded(std.testing.allocator, "/etc/hosts/below-a-file", 10));
    try std.testing.expectError(error.Failed, readBounded(std.testing.allocator, "/tmp", 10));
    try std.testing.expectError(error.Failed, readBounded(std.testing.allocator, "", 10));
    try std.testing.expectError(error.Failed, readBounded(std.testing.allocator, "a\x00b", 10));
}

test "a file the process may not read is reported as such" {
    // root reads any file, so the check only holds for other users.
    if (std.c.getuid() == 0) return error.SkipZigTest;
    const file = try TestFile.create("secret", 0o000);
    defer file.remove();
    try std.testing.expectError(error.PermissionDenied, readBounded(std.testing.allocator, file.slice(), 10));
}

test "bounded reads preserve bytes around the chunk boundary and reject one byte over budget" {
    var bytes: [16 * 1024 + 1]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index);
    // Nearest byte lengths below, at, and above the 16 KiB read boundary.
    for ([_]usize{ 16 * 1024 - 1, 16 * 1024, 16 * 1024 + 1 }) |length| {
        const file = try TestFile.create(bytes[0..length], 0o600);
        defer file.remove();
        try std.testing.expectError(error.TooLarge, readBounded(std.testing.allocator, file.slice(), length - 1));
        for ([_]u64{ length, length + 1, std.math.maxInt(u64) }) |limit| {
            const contents = try readBounded(std.testing.allocator, file.slice(), limit);
            defer std.testing.allocator.free(contents);
            try std.testing.expectEqualSlices(u8, bytes[0..length], contents);
        }
    }
    const one = try TestFile.create("x", 0o600);
    defer one.remove();
    try std.testing.expectError(error.TooLarge, readBounded(std.testing.allocator, one.slice(), 0));
}
