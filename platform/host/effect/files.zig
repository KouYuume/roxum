//! `Files` and `Reply.file`: opening files under a root and sending
//! them as a response body. Opening and reading run as blocking jobs, off
//! the Roc threads. A request holds at most one open file, in its fiber's
//! `Locals`, closed when the request ends, however it ends.
const std = @import("std");
const abi = @import("../roc_platform_abi.zig");
const allocator_context = @import("../allocator/context.zig");
const blocking = @import("../blocking.zig");
const fiber = @import("../fiber.zig");
const fiber_wait = @import("../fiber_wait.zig");
const files = @import("../files.zig");
const raw_bytes = @import("../raw_bytes.zig");
const response_writer = @import("response_writer.zig");
const runtime = @import("../runtime.zig");

/// How much of a file is read at a time, and held while it is written.
pub const part_bytes: usize = 64 * 1024;

/// The open file of code off a fiber, as in tests.
threadlocal var thread_file: c_int = -1;

fn slot() *c_int {
    if (fiber.currentLocals()) |locals| return &locals.file;
    return &thread_file;
}

fn closeCurrent() void {
    const place = slot();
    if (place.* < 0) return;
    files.close(place.*);
    place.* = -1;
}

/// Closes the file a request held when it stopped or ended.
pub fn closeHeldBy(target: *fiber.Fiber) void {
    if (target.locals.file < 0) return;
    files.close(target.locals.file);
    target.locals.file = -1;
}

pub fn hostedFilesOpenRoot(path: abi.RocStr) callconv(std.builtin.CallingConvention.c) abi.HostFilesRootOpened {
    var roc_host = rocHost();
    defer path.decref(&roc_host);
    const handle = files.openRoot(path.asSlice()) catch |err| return rootResult(switch (err) {
        error.NotFound => abi.HostFilesRootOpenedTag.NotFound,
        error.NotDirectory => abi.HostFilesRootOpenedTag.NotDirectory,
        error.PermissionDenied => abi.HostFilesRootOpenedTag.PermissionDenied,
        error.Failed => abi.HostFilesRootOpenedTag.Failed,
    }, 0);
    return rootResult(abi.HostFilesRootOpenedTag.Opened, handle);
}

const OpenJob = struct {
    job: blocking.Job = .{ .run = run },
    root: u64,
    path: []const u8,
    result: files.OpenError!files.Entry = error.Failed,

    fn run(job: *blocking.Job) void {
        const self: *OpenJob = @fieldParentPtr("job", job);
        self.result = files.openBeneath(self.root, self.path);
    }
};

pub fn hostedFilesOpen(root: u64, path: abi.RocStr) callconv(std.builtin.CallingConvention.c) abi.HostFilesFileOpened {
    var roc_host = rocHost();
    defer path.decref(&roc_host);
    closeCurrent();
    var open = OpenJob{ .root = root, .path = path.asSlice() };
    blocking.run(&open.job);
    const entry = open.result catch |err| {
        fiber_wait.stopIfStreamEnds();
        return fileResult(switch (err) {
            error.NotFound => abi.HostFilesFileOpenedTag.NotFound,
            error.Failed => abi.HostFilesFileOpenedTag.Failed,
        }, null);
    };
    slot().* = entry.descriptor;
    fiber_wait.stopIfStreamEnds();
    return fileResult(abi.HostFilesFileOpenedTag.Opened, entry);
}

const ReadJob = struct {
    job: blocking.Job = .{ .run = run },
    descriptor: c_int,
    buffer: []u8,
    offset: u64,
    result: error{Failed}!usize = error.Failed,

    fn run(job: *blocking.Job) void {
        const self: *ReadJob = @fieldParentPtr("job", job);
        self.result = files.readAt(self.descriptor, self.buffer, self.offset);
    }
};

/// Writes `length` bytes of the open file from `offset` to the body of
/// stream `token`, a part at a time: a blocking job reads the part, and the
/// request's fiber writes it, waiting while the client does not take it.
pub fn hostedFilesSend(token: u64, offset: u64, length: u64) callconv(std.builtin.CallingConvention.c) bool {
    const sent = send(token, offset, length);
    if (!sent) response_writer.abort(token);
    fiber_wait.stopIfStreamEnds();
    return sent;
}

fn send(token: u64, offset: u64, length: u64) bool {
    const descriptor = slot().*;
    if (descriptor < 0) return false;
    const buffer = raw_bytes.alloc(@intCast(@min(length, part_bytes))) catch return false;
    defer raw_bytes.free(buffer);
    var position = offset;
    var left = length;
    while (left != 0) {
        const wanted: usize = @intCast(@min(left, buffer.len));
        var read = ReadJob{ .descriptor = descriptor, .buffer = buffer[0..wanted], .offset = position };
        blocking.run(&read.job);
        const count = read.result catch return false;
        // The file shrank: the body ends short and the connection closes.
        if (count == 0) return false;
        if (!response_writer.write(token, buffer[0..count])) return false;
        position += count;
        left -= count;
        // A gone client or a drain stops the request between parts.
        const target = fiber.current() orelse continue;
        if (target.stop.load(std.builtin.AtomicOrder.acquire) != fiber.Stop.none) return false;
    }
    return true;
}

pub fn hostedFilesClose() callconv(std.builtin.CallingConvention.c) void {
    closeCurrent();
}

fn rootResult(tag: abi.HostFilesRootOpenedTag, handle: u64) abi.HostFilesRootOpened {
    var result: abi.HostFilesRootOpened = undefined;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    result.tag = tag;
    if (tag == abi.HostFilesRootOpenedTag.Opened) {
        const payload: *u64 = @ptrCast(@alignCast(&result.payload));
        payload.* = handle;
    }
    return result;
}

fn fileResult(tag: abi.HostFilesFileOpenedTag, entry: ?files.Entry) abi.HostFilesFileOpened {
    var result: abi.HostFilesFileOpened = undefined;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    result.tag = tag;
    if (entry) |opened| {
        const payload: *@TypeOf(result.payload_opened()) = @ptrCast(@alignCast(&result.payload));
        payload.* = std.mem.zeroes(@TypeOf(payload.*));
        payload.size = opened.size;
        payload.modified_seconds = opened.modified_seconds;
        payload.directory = opened.directory;
    }
    return result;
}

fn rocHost() abi.RocHost {
    const context = allocator_context.current() orelse @panic("allocator context is not set");
    return runtime.makeRocHost(@ptrCast(context.host_allocator));
}
