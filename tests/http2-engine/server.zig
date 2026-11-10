//! Independent-client fixture for the engine, not a production listener.
const std = @import("std");
const http2 = @import("http2_engine");
const net = @import("net");

const Request = struct {
    id: ?http2.StreamId = null,
    body: [4096]u8 = undefined,
    length: usize = 0,
    ended: bool = false,
    sent: bool = false,
};
const State = struct {
    requests: [16]Request = @splat(.{}),
    closed: usize = 0,
    admitted: usize = 0,
    active: usize = 0,
    peak_streams: usize = 0,
    fn from(ctx: *anyopaque) *State {
        return @ptrCast(@alignCast(ctx));
    }
    fn request(self: *State, id: http2.StreamId) *Request {
        for (&self.requests) |*r| if (r.id == id) return r;
        for (&self.requests) |*r| {
            if (r.id != null) continue;
            r.* = .{ .id = id };
            self.admitted += 1;
            self.active += 1;
            self.peak_streams = @max(self.peak_streams, self.active);
            return r;
        }
        @panic("fixture stream capacity exceeded");
    }
    fn header(ctx: *anyopaque, id: http2.StreamId, _: http2.Header) void {
        _ = from(ctx).request(id);
    }
    fn data(ctx: *anyopaque, id: http2.StreamId, bytes: []const u8) void {
        const r = from(ctx).request(id);
        @memcpy(r.body[r.length..][0..bytes.len], bytes);
        r.length += bytes.len;
    }
    fn end(ctx: *anyopaque, id: http2.StreamId) void {
        from(ctx).request(id).ended = true;
    }
    fn close(ctx: *anyopaque, id: http2.StreamId) void {
        const self = from(ctx);
        self.request(id).* = .{};
        self.closed += 1;
        self.active -= 1;
    }
};

pub fn main() !void {
    const ignore = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);
    const listener = try net.listenIpv4(.{ 127, 0, 0, 1 }, 0);
    defer net.closeSocket(listener.socket);
    var port_buffer: [16]u8 = undefined;
    const line = try std.fmt.bufPrint(&port_buffer, "{d}\n", .{listener.port});
    if (std.c.write(1, line.ptr, line.len) != line.len) return error.StdoutFailed;
    const accepted = switch (net.acceptPending(listener.socket)) {
        net.PendingAccept.accepted => |value| value,
        else => return error.AcceptFailed,
    };
    defer net.closeSocket(accepted.socket);
    var state = State{};
    const engine = try http2.Engine.create(std.heap.smp_allocator, .{ .body_bytes = 4096, .header_bytes = 1024 }, .{
        .context = &state,
        .header = State.header,
        .data = State.data,
        .end = State.end,
        .closed = State.close,
    });
    defer engine.destroy();
    var input: [8192]u8 = undefined;
    while (true) {
        for (&state.requests) |*r| {
            if (!r.ended or r.sent) continue;
            var length_buffer: [20]u8 = undefined;
            const length = try std.fmt.bufPrint(&length_buffer, "{d}", .{r.length});
            try engine.respond(r.id.?, 200, &.{
                .{ .name = "content-type", .value = "application/octet-stream" },
                .{ .name = "content-length", .value = length },
            }, r.body[0..r.length]);
            // The engine has its own copy; catch accidental borrowing on the wire.
            @memset(r.body[0..r.length], 0xa5);
            r.sent = true;
        }
        const output = try engine.output();
        if (output.len > 0) {
            // Exercise the retained output cursor across very short writes.
            const count = @min(output.len, 7);
            try net.sendAllUntil(accepted.socket, output[0..count], try net.Deadline.afterMilliseconds(5000));
            try engine.consumeOutput(count);
            continue;
        }
        const count = try net.receiveUntil(accepted.socket, &input, try net.Deadline.afterMilliseconds(5000));
        if (count == 0) break;
        try engine.receive(input[0..count]);
    }
    std.debug.print("closed={d} peak={d} admitted={d} active={d} peak_streams={d}\n", .{ state.closed, engine.memory.peak, state.admitted, state.active, state.peak_streams });
}
