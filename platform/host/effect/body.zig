const std = @import("std");
const abi = @import("../roc_platform_abi.zig");
const allocator_context = @import("../allocator/context.zig");
const request_bridge = @import("../bridge/request.zig");
const request_reader = @import("../connection/request_reader.zig");
const runtime = @import("../runtime.zig");
const fiber = @import("../fiber.zig");

pub const maximum_read_bytes = request_reader.maximum_stream_chunk_bytes;

/// A transport copies each result into the current request domain before
/// releasing its input lock. The callback may suspend, but retains no view.
pub const Reader = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, u64, bool) abi.HostBodyRequestRead,
    limit: *const fn (*anyopaque, u64, bool) void,
};
const Source = union(enum) { http1: *request_reader.BodyStream, reader: Reader };
pub const Active = struct { token: u64, source: Source };

/// The active body of code off a fiber. A request fiber keeps its own in
/// its `Locals`, so it follows the fiber to another thread.
threadlocal var thread_active: ?Active = null;
/// Tokens are unique in the process, so a stale handle never matches
/// another request's body, whichever thread runs it.
var next_token = std.atomic.Value(u64).init(1);

fn slot() *?Active {
    if (fiber.currentLocals()) |locals| return &locals.body;
    return &thread_active;
}

pub fn activate(stream: *request_reader.BodyStream) u64 {
    return activateSource(.{ .http1 = stream });
}

pub fn activateReader(reader: Reader) u64 {
    return activateSource(.{ .reader = reader });
}

fn activateSource(source: Source) u64 {
    const place = slot();
    std.debug.assert(place.* == null);
    var token = next_token.fetchAdd(1, std.builtin.AtomicOrder.monotonic);
    // 0 never names a body; after the counter wraps, skip it.
    if (token == 0) token = next_token.fetchAdd(1, std.builtin.AtomicOrder.monotonic);
    place.* = .{ .token = token, .source = source };
    return token;
}

pub fn deactivate() void {
    const place = slot();
    std.debug.assert(place.* != null);
    place.* = null;
}

/// Reads the next part of the body: `whole` as a body read into memory, or
/// as a stream, each under its limit and time limit.
pub fn hostedBodyRead(
    token: u64,
    requested_maximum: u64,
    whole: bool,
) callconv(std.builtin.CallingConvention.c) abi.HostBodyRequestRead {
    if (requested_maximum == 0) return resultWithTag(
        abi.HostBodyRequestReadTag.InvalidLimit,
    );
    const requested = std.math.cast(usize, requested_maximum) orelse
        maximum_read_bytes;
    const maximum_bytes = @min(requested, maximum_read_bytes);

    const current = slot().* orelse return resultWithTag(
        abi.HostBodyRequestReadTag.Closed,
    );
    if (current.token != token) return resultWithTag(
        abi.HostBodyRequestReadTag.Closed,
    );

    const stream = switch (current.source) {
        Source.http1 => |stream| stream,
        Source.reader => |reader| return reader.read(reader.context, requested_maximum, whole),
    };

    // A whole read that asks for more than a part gets the rest of the body
    // at once when it has all been received.
    const buffered = if (whole and requested > maximum_read_bytes)
        stream.readBufferedWhole() catch |err| return resultWithTag(failureTag(err))
    else
        null;
    const mode = if (whole) request_reader.ReadMode.whole else request_reader.ReadMode.streamed;
    const read = buffered orelse stream.readAs(maximum_bytes, mode) catch |err| return resultWithTag(
        failureTag(err),
    );
    return switch (read) {
        request_reader.StreamRead.end => resultWithTag(
            abi.HostBodyRequestReadTag.End,
        ),
        request_reader.StreamRead.chunk => |bytes| chunkResult(
            stream,
            bytes,
        ),
    };
}

/// Sets the limit of the current request's body read into memory, for a
/// route's `BodyLimit.whole` layer. A stale token does nothing.
pub fn hostedBodyLimitWhole(token: u64, bytes: u64) callconv(std.builtin.CallingConvention.c) void {
    const current = slot().* orelse return;
    if (current.token != token) return;
    switch (current.source) {
        Source.http1 => |stream| stream.limits.whole_bytes = bytes,
        Source.reader => |reader| reader.limit(reader.context, bytes, true),
    }
}

/// Sets the limit of the current request's body read as a stream, for a
/// route's `BodyLimit.streamed` layer; `maxInt` for none.
pub fn hostedBodyLimitStreamed(token: u64, bytes: u64) callconv(std.builtin.CallingConvention.c) void {
    const current = slot().* orelse return;
    if (current.token != token) return;
    switch (current.source) {
        Source.http1 => |stream| stream.limits.streamed_bytes = bytes,
        Source.reader => |reader| reader.limit(reader.context, bytes, false),
    }
}

fn chunkResult(
    stream: *request_reader.BodyStream,
    bytes: []const u8,
) abi.HostBodyRequestRead {
    const context = allocator_context.current() orelse
        @panic("allocator context is not set");
    var roc_host = runtime.makeRocHost(@ptrCast(context.host_allocator));
    const list = request_bridge.rocByteListFromSliceChecked(
        bytes,
        .{ .roc_host = &roc_host, .try_alloc = runtime.tryAllocWithHost },
    ) catch {
        stream.markFailed();
        return resultWithTag(abi.HostBodyRequestReadTag.Failed);
    };

    var result: abi.HostBodyRequestRead = undefined;
    result.tag = abi.HostBodyRequestReadTag.Chunk;
    const payload: *abi.RocListWith(u8, false) = @ptrCast(
        @alignCast(&result.payload),
    );
    payload.* = list;
    return result;
}

fn resultWithTag(
    tag: abi.HostBodyRequestReadTag,
) abi.HostBodyRequestRead {
    var result: abi.HostBodyRequestRead = undefined;
    result.tag = tag;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    return result;
}

test "body read rejects zero and stale tokens before allocator access" {
    try std.testing.expectEqual(
        abi.HostBodyRequestReadTag.InvalidLimit,
        hostedBodyRead(1, 0, true).tag,
    );
    try std.testing.expectEqual(
        abi.HostBodyRequestReadTag.Closed,
        hostedBodyRead(1, 1, true).tag,
    );
}

fn failureTag(err: request_reader.Error) abi.HostBodyRequestReadTag {
    return switch (err) {
        error.InvalidRequest, error.InvalidChunkedBody, error.IncompleteBody, error.MissingBodyFraming, error.ReceiveFailed => abi.HostBodyRequestReadTag.BadRequest,
        error.RequestBodyTooLarge => abi.HostBodyRequestReadTag.TooLarge,
        error.RequestBodyTimeout => abi.HostBodyRequestReadTag.TimedOut,
        else => abi.HostBodyRequestReadTag.Failed,
    };
}

test "body failure categories preserve client and internal distinctions" {
    for ([_]request_reader.Error{ error.InvalidRequest, error.InvalidChunkedBody, error.IncompleteBody, error.MissingBodyFraming, error.ReceiveFailed }) |err| {
        try std.testing.expectEqual(abi.HostBodyRequestReadTag.BadRequest, failureTag(err));
    }
    try std.testing.expectEqual(abi.HostBodyRequestReadTag.TooLarge, failureTag(error.RequestBodyTooLarge));
    try std.testing.expectEqual(abi.HostBodyRequestReadTag.TimedOut, failureTag(error.RequestBodyTimeout));
    try std.testing.expectEqual(abi.HostBodyRequestReadTag.Failed, failureTag(error.OutOfMemory));
    try std.testing.expectEqual(abi.HostBodyRequestReadTag.Failed, failureTag(error.ClockFailed));
}

test "transport reader validates tokens and forwards whole streamed limits and read sizes" {
    const Context = struct {
        maximum: u64 = 0,
        whole: bool = false,
        whole_limit: u64 = 0,
        streamed_limit: u64 = 0,
        fn read(ptr: *anyopaque, maximum: u64, whole: bool) abi.HostBodyRequestRead {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.maximum = maximum;
            self.whole = whole;
            return resultWithTag(abi.HostBodyRequestReadTag.End);
        }
        fn limit(ptr: *anyopaque, bytes: u64, whole: bool) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (whole) self.whole_limit = bytes else self.streamed_limit = bytes;
        }
    };
    var context = Context{};
    const reader = Reader{ .context = &context, .read = Context.read, .limit = Context.limit };
    const first = activateReader(reader);
    try std.testing.expectEqual(abi.HostBodyRequestReadTag.InvalidLimit, hostedBodyRead(first, 0, true).tag);
    try std.testing.expectEqual(@as(u64, 0), context.maximum);
    for ([_]u64{ 1, maximum_read_bytes, maximum_read_bytes + 1, std.math.maxInt(u64) }) |maximum| {
        for ([_]bool{ false, true }) |whole| {
            try std.testing.expectEqual(abi.HostBodyRequestReadTag.End, hostedBodyRead(first, maximum, whole).tag);
            try std.testing.expectEqual(maximum, context.maximum);
            try std.testing.expectEqual(whole, context.whole);
        }
    }
    hostedBodyLimitWhole(first, 3);
    hostedBodyLimitStreamed(first, 4);
    try std.testing.expectEqual(@as(u64, 3), context.whole_limit);
    try std.testing.expectEqual(@as(u64, 4), context.streamed_limit);
    deactivate();
    const second = activateReader(reader);
    defer deactivate();
    try std.testing.expect(second != first);
    try std.testing.expectEqual(abi.HostBodyRequestReadTag.Closed, hostedBodyRead(first, 1, true).tag);
    hostedBodyLimitWhole(first, 99);
    hostedBodyLimitStreamed(first, 99);
    try std.testing.expectEqual(@as(u64, 3), context.whole_limit);
    try std.testing.expectEqual(@as(u64, 4), context.streamed_limit);
}
