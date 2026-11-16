//! Isolated transport experiment. No production listener or Roc ABI changes.
const std = @import("std");
const net = @import("host/net.zig");
const fiber = @import("host/fiber.zig");
const c = @import("c.zig");

const capacity = 4096;
const Stream = struct {
    id: i32 = 0,
    owner: *Connection = undefined,
    task: ?*fiber.Fiber = null,
    input: [capacity]u8 = undefined,
    input_len: usize = 0,
    output: [capacity]u8 = undefined,
    output_len: usize = 0,
    eof: bool = false,
    output_pending: bool = false,
    closed: bool = false,
    runnable: bool = false,
};

const Connection = struct {
    session: ?*c.nghttp2_session = null,
    streams: [16]Stream = @splat(.{}),
    allocations: usize = 0,
    peak_allocations: usize = 0,
    created: usize = 0,
    destroyed: usize = 0,
    cancelled: usize = 0,
    cancelled_writers: usize = 0,
    resumed_writers: usize = 0,

    fn find(self: *Connection, id: i32) ?*Stream {
        for (&self.streams) |*stream| {
            if (stream.id == id) return stream;
        }
        return null;
    }

    // Called outside nghttp2 callbacks, so fibers cannot reenter the session.
    fn schedule(self: *Connection) bool {
        var progressed = false;
        for (&self.streams) |*stream| {
            const task = stream.task orelse continue;
            if (stream.runnable or stream.closed) {
                stream.runnable = false;
                if (!task.finished) fiber.resumeFiber(task);
                progressed = true;
            }
            if (stream.closed) {
                std.debug.assert(task.finished);
                task.destroy();
                self.destroyed += 1;
                stream.* = .{};
            }
        }
        return progressed;
    }
};

fn owner(user: ?*anyopaque) *Connection {
    return @ptrCast(@alignCast(user.?));
}

fn allocate(size: usize, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) ?*anyopaque {
    const ptr = c.malloc(size) orelse return null;
    const self = owner(user);
    self.allocations += 1;
    self.peak_allocations = @max(self.peak_allocations, self.allocations);
    return ptr;
}

fn release(ptr: ?*anyopaque, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) void {
    if (ptr != null) owner(user).allocations -= 1;
    c.free(ptr);
}

fn calloc(count: usize, size: usize, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) ?*anyopaque {
    const bytes = std.math.mul(usize, count, size) catch return null;
    const ptr = allocate(bytes, user) orelse return null;
    @memset(@as([*]u8, @ptrCast(ptr))[0..bytes], 0);
    return ptr;
}

fn resize(ptr: ?*anyopaque, size: usize, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) ?*anyopaque {
    if (ptr == null) return allocate(size, user);
    if (size == 0) {
        release(ptr, user);
        return null;
    }
    return c.realloc(ptr, size);
}

fn field(name: []const u8, value: []const u8) c.nghttp2_nv {
    return .{ .name = @constCast(name.ptr), .value = @constCast(value.ptr), .namelen = name.len, .valuelen = value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
}

fn readOutput(_: ?*c.nghttp2_session, id: i32, buffer: [*c]u8, length: usize, flags: [*c]u32, _: [*c]c.nghttp2_data_source, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) isize {
    const stream = owner(user).find(id) orelse return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    const count = @min(length, stream.output_len);
    @memcpy(buffer[0..count], stream.output[0..count]);
    std.mem.copyForwards(u8, &stream.output, stream.output[count..stream.output_len]);
    stream.output_len -= count;
    // Finish each provider on its final DATA, even when that exhausts credit.
    if (stream.output_len == 0) flags.* = c.NGHTTP2_DATA_FLAG_EOF | c.NGHTTP2_DATA_FLAG_NO_END_STREAM;
    return @intCast(count);
}

fn frameSent(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) c_int {
    if (frame.*.hd.type == c.NGHTTP2_DATA) {
        if (owner(user).find(frame.*.hd.stream_id)) |stream| {
            if (stream.output_len == 0) {
                stream.output_pending = false;
                stream.runnable = true;
            }
        }
    }
    return 0;
}

fn write(stream: *Stream, bytes: []const u8) bool {
    std.debug.assert(bytes.len <= capacity);
    var waited = false;
    while (stream.output_pending and !stream.closed) {
        waited = true;
        fiber.suspendCurrent();
    }
    if (stream.closed) {
        if (waited) stream.owner.cancelled_writers += 1;
        return false;
    }
    if (waited) stream.owner.resumed_writers += 1;
    @memcpy(stream.output[0..bytes.len], bytes);
    stream.output_len = bytes.len;
    stream.output_pending = true;
    const provider = c.nghttp2_data_provider2{ .source = .{ .ptr = null }, .read_callback = readOutput };
    std.debug.assert(c.nghttp2_submit_data2(stream.owner.session, c.NGHTTP2_FLAG_NONE, stream.id, &provider) == 0);
    return true;
}

fn handle(task: *fiber.Fiber) void {
    const stream: *Stream = @ptrCast(@alignCast(task.userdata.?));
    if (!write(stream, "ready\n")) return;
    while (!stream.closed) {
        while (stream.input_len == 0 and !stream.eof and !stream.closed) fiber.suspendCurrent();
        if (stream.closed) return;
        if (stream.input_len > 0) {
            const count = stream.input_len;
            if (!write(stream, stream.input[0..count])) return;
            // Input can grow while this fiber waits for output capacity.
            std.mem.copyForwards(u8, &stream.input, stream.input[count..stream.input_len]);
            stream.input_len -= count;
            std.debug.assert(c.nghttp2_session_consume(stream.owner.session, stream.id, count) == 0);
        }
        if (stream.eof and stream.input_len == 0) break;
    }
    while (stream.output_pending and !stream.closed) fiber.suspendCurrent();
    if (stream.closed) return;
    // HEADERS are not flow controlled; completion also works at zero DATA credit.
    const trailers = [_]c.nghttp2_nv{field("x-spike-complete", "yes")};
    std.debug.assert(c.nghttp2_submit_trailer(stream.owner.session, stream.id, &trailers, trailers.len) == 0);
}

fn frameReceived(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) c_int {
    const self = owner(user);
    const hd = frame.*.hd;
    if (hd.type == c.NGHTTP2_HEADERS and frame.*.headers.cat == c.NGHTTP2_HCAT_REQUEST) {
        for (&self.streams) |*stream| {
            if (stream.id != 0) continue;
            stream.* = .{ .id = hd.stream_id, .owner = self, .runnable = true };
            const task = fiber.Fiber.create() catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            task.prepare(handle, stream);
            stream.task = task;
            self.created += 1;
            const headers = [_]c.nghttp2_nv{ field(":status", "200"), field("content-type", "application/octet-stream") };
            if (c.nghttp2_submit_headers(session, c.NGHTTP2_FLAG_NONE, hd.stream_id, null, &headers, headers.len, null) < 0) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            break;
        }
        if (self.find(hd.stream_id) == null) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    if ((hd.type == c.NGHTTP2_HEADERS or hd.type == c.NGHTTP2_DATA) and (hd.flags & c.NGHTTP2_FLAG_END_STREAM) != 0) {
        if (self.find(hd.stream_id)) |stream| {
            stream.eof = true;
            stream.runnable = true;
        }
    }
    return 0;
}

fn dataReceived(_: ?*c.nghttp2_session, _: u8, id: i32, data: [*c]const u8, length: usize, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) c_int {
    const stream = owner(user).find(id) orelse return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    if (length > capacity - stream.input_len) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    @memcpy(stream.input[stream.input_len..][0..length], data[0..length]);
    stream.input_len += length;
    stream.runnable = true;
    return 0;
}

fn streamClosed(_: ?*c.nghttp2_session, id: i32, code: u32, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) c_int {
    const self = owner(user);
    if (self.find(id)) |stream| stream.closed = true;
    if (code == c.NGHTTP2_CANCEL) self.cancelled += 1;
    return 0;
}

pub fn main() !void {
    // A disappearing test client must cause an error, not SIGPIPE termination.
    const ignore = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);
    const listener = try net.listenIpv4(.{ 127, 0, 0, 1 }, 0);
    defer net.closeSocket(listener.socket);
    var port_buffer: [16]u8 = undefined;
    const port_line = try std.fmt.bufPrint(&port_buffer, "{d}\n", .{listener.port});
    if (c.write(1, port_line.ptr, port_line.len) != port_line.len) return error.StdoutFailed;
    const accepted = switch (net.acceptPending(listener.socket)) {
        net.PendingAccept.accepted => |value| value,
        else => return error.AcceptFailed,
    };
    defer net.closeSocket(accepted.socket);
    var self = Connection{};
    var callbacks: ?*c.nghttp2_session_callbacks = null;
    try check(c.nghttp2_session_callbacks_new(&callbacks));
    defer c.nghttp2_session_callbacks_del(callbacks);
    c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, frameReceived);
    c.nghttp2_session_callbacks_set_on_frame_send_callback(callbacks, frameSent);
    c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, dataReceived);
    c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, streamClosed);
    var options: ?*c.nghttp2_option = null;
    try check(c.nghttp2_option_new(&options));
    defer c.nghttp2_option_del(options);
    c.nghttp2_option_set_no_auto_window_update(options, 1);
    var memory = c.nghttp2_mem{ .mem_user_data = &self, .malloc = allocate, .free = release, .calloc = calloc, .realloc = resize };
    try check(c.nghttp2_session_server_new3(&self.session, callbacks, &self, options, &memory));
    defer {
        for (&self.streams) |*stream| stream.closed = true;
        _ = self.schedule();
        c.nghttp2_session_del(self.session);
        std.debug.assert(self.created == self.destroyed and self.allocations == 0);
        std.debug.print("created={d} destroyed={d} cancelled={d} allocations={d} peak={d} cancelled_writers={d} resumed_writers={d}\n", .{ self.created, self.destroyed, self.cancelled, self.allocations, self.peak_allocations, self.cancelled_writers, self.resumed_writers });
    }
    const settings = [_]c.nghttp2_settings_entry{
        .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = 16 },
        .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = capacity },
    };
    try check(c.nghttp2_submit_settings(self.session, c.NGHTTP2_FLAG_NONE, &settings, settings.len));
    var input: [16384]u8 = undefined;
    while (true) {
        const progress = self.schedule();
        var output: [*c]const u8 = null;
        const length = c.nghttp2_session_mem_send2(self.session, &output);
        if (length < 0) return error.Http2Failed;
        if (length > 0) {
            try net.sendAllUntil(accepted.socket, output[0..@intCast(length)], try net.Deadline.afterMilliseconds(5000));
            continue;
        }
        if (progress) continue;
        const count = try net.receiveUntil(accepted.socket, &input, try net.Deadline.afterMilliseconds(5000));
        if (count == 0) break;
        const consumed = c.nghttp2_session_mem_recv2(self.session, &input, count);
        if (consumed < 0 or consumed != count) return error.Http2Failed;
    }
}

fn check(result: c_int) !void {
    if (result != 0) return error.Http2Failed;
}
