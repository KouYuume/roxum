//! `ResponseWriter`: the body a handler writes as it goes. While a
//! request's Roc code runs, its session is the sink: `start!` sends the
//! head and `write!` the parts of the body. The handle lives in the
//! request fiber's `Locals`, so it follows the fiber to another thread.
const std = @import("std");
const abi = @import("../roc_platform_abi.zig");
const allocator_context = @import("../allocator/context.zig");
const fiber = @import("../fiber.zig");
const runtime = @import("../runtime.zig");

/// Where a request's written body goes: its session.
pub const Sink = struct {
    context: *anyopaque,
    /// Sends the head from the response's status and headers; false when
    /// the stream did not start (the host has answered or the client is
    /// gone). Does not take the response or the bytes: while the body is
    /// quiet for `keep_alive_milliseconds` (0 for never), `keep_alive_bytes`
    /// are written. With `ends_on_drain`, a drain ends the body. A
    /// known `content_length` is sent instead of chunked framing.
    /// With `gzip_body`, the parts are gzip-compressed as they go.
    start: *const fn (context: *anyopaque, response: *const abi.HttpResponse, keep_alive_milliseconds: u64, keep_alive_bytes: []const u8, ends_on_drain: bool, content_length: ?u64, gzip_body: bool) bool,
    /// Writes the next part; false when the stream is over.
    write: *const fn (context: *anyopaque, bytes: []const u8) bool,
    /// Aborts the body without writing a successful terminator.
    abort: *const fn (context: *anyopaque) void,
};

pub const Active = struct {
    token: u64,
    sink: Sink,
    started: bool = false,
};

/// The active sink of code off a fiber, as in tests.
threadlocal var thread_active: ?Active = null;
/// Unique in the process, so a handle from an earlier request never
/// matches, whichever thread runs it.
var next_token = std.atomic.Value(u64).init(1);

fn slot() *?Active {
    if (fiber.currentLocals()) |locals| return &locals.response;
    return &thread_active;
}

pub fn activate(sink: Sink) void {
    const place = slot();
    std.debug.assert(place.* == null);
    place.* = .{ .token = 0, .sink = sink };
}

pub fn deactivate() void {
    const place = slot();
    std.debug.assert(place.* != null);
    place.* = null;
}

/// `content_length` is the body's length, or the largest `U64` when it is
/// not known. With `gzip_body`, the body is gzip-compressed as it goes.
pub fn hostedStreamStart(response: abi.HttpResponse, keep_alive_milliseconds: u64, keep_alive_bytes: abi.RocListWith(u8, false), ends_on_drain: bool, content_length: u64, gzip_body: bool) callconv(std.builtin.CallingConvention.c) u64 {
    var roc_host = rocHost();
    defer response.decref(&roc_host);
    defer keep_alive_bytes.decref(&roc_host);
    const place = slot();
    const current = &(place.* orelse return 0);
    // One stream per request.
    if (current.started) return 0;
    current.started = true;
    // Buffered responses never publish a stream capability or contend for its counter.
    var token = next_token.fetchAdd(1, std.builtin.AtomicOrder.monotonic);
    if (token == 0) token = next_token.fetchAdd(1, std.builtin.AtomicOrder.monotonic);
    current.token = token;
    if (!current.sink.start(current.sink.context, &response, keep_alive_milliseconds, keep_alive_bytes.items(), ends_on_drain, if (content_length == std.math.maxInt(u64)) null else content_length, gzip_body)) return 0;
    return current.token;
}

pub fn hostedStreamWrite(token: u64, bytes: abi.RocListWith(u8, false)) callconv(std.builtin.CallingConvention.c) bool {
    var roc_host = rocHost();
    defer bytes.decref(&roc_host);
    return write(token, bytes.items());
}

/// Writes the next part of the request's body, as `hostedStreamWrite` does,
/// from host memory, such as a part of a file.
pub fn write(token: u64, bytes: []const u8) bool {
    if (token == 0) return false;
    const current = slot().* orelse return false;
    if (current.token != token) return false;
    return current.sink.write(current.sink.context, bytes);
}

pub fn abort(token: u64) void {
    const current = slot().* orelse return;
    if (current.token != token or !current.started) return;
    current.sink.abort(current.sink.context);
}

fn rocHost() abi.RocHost {
    const context = allocator_context.current() orelse @panic("allocator context is not set");
    return runtime.makeRocHost(@ptrCast(context.host_allocator));
}

test "stream capabilities reject zero, repeated starts, and previous requests" {
    const Mock = struct {
        writes: usize = 0,
        fn start(_: *anyopaque, _: *const abi.HttpResponse, _: u64, _: []const u8, _: bool, _: ?u64, _: bool) bool {
            return true;
        }
        fn writeBytes(context: *anyopaque, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.writes += 1;
            return true;
        }
        fn abortStream(_: *anyopaque) void {}
        fn begin() u64 {
            var response = std.mem.zeroes(abi.HttpResponse);
            response.status = 200;
            return hostedStreamStart(response, 0, abi.RocListWith(u8, false).empty(), false, 0, false);
        }
    };
    const allocator = @import("../allocator/host_allocator.zig");
    var memory = allocator.HostAllocator{
        .persistent_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
    };
    allocator_context.setCurrent(.{ .host_allocator = &memory, .domain = allocator.Domain.request, .generation = 1 });
    defer allocator_context.clearCurrent();
    var mock = Mock{};
    const sink = Sink{ .context = &mock, .start = Mock.start, .write = Mock.writeBytes, .abort = Mock.abortStream };
    activate(sink);
    try std.testing.expect(!write(0, "before start"));
    const first = Mock.begin();
    try std.testing.expect(first != 0);
    try std.testing.expectEqual(@as(u64, 0), Mock.begin());
    try std.testing.expect(write(first, "active stream"));
    deactivate();
    try std.testing.expect(!write(first, "after cleanup"));
    activate(sink);
    defer deactivate();
    try std.testing.expect(!write(first, "next request before start"));
    const second = Mock.begin();
    try std.testing.expect(second != 0 and second != first);
    try std.testing.expect(!write(first, "stale capability"));
    try std.testing.expect(write(second, "next stream"));
    try std.testing.expectEqual(@as(usize, 2), mock.writes);
}
