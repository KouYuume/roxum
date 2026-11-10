//! Independent-client fixture for the engine, not a production listener.
const std = @import("std");
const http2 = @import("http2_engine").engine;
const leases = @import("http2_engine").requests;
const transport = @import("http2_engine").owner;
const readiness = @import("http2_engine").poller;
const net = @import("http2_engine").net;
extern "c" fn setsockopt(c_int, c_int, c_int, *const anyopaque, u32) c_int;

const Request = struct {
    id: ?http2.StreamId = null,
    body: [4096]u8 = undefined,
    length: usize = 0,
    ended: bool = false,
    sent: bool = false,
};
const State = struct {
    leases: leases.Requests = .{ .connection = 0 },
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
            _ = self.leases.open(id) catch @panic("fixture lease capacity exceeded");
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
    fn headersComplete(ctx: *anyopaque, id: http2.StreamId) void {
        const self = from(ctx);
        const ticket = self.leases.find(id) orelse unreachable;
        std.debug.assert(self.leases.ready(ticket, net.monotonicNanoseconds() catch unreachable));
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
        self.leases.close(id);
        self.closed += 1;
        for (&self.requests) |*entry| {
            if (entry.id != id) continue;
            entry.* = .{};
            self.active -= 1;
            return;
        }
    }
};

const Connection = struct {
    state: State = .{},
    owner: ?transport.Owner = null,
    deadline: net.Deadline = undefined,
    blocked_reported: bool = false,

    fn close(self: *Connection) void {
        const owner = &self.owner.?;
        std.debug.print("closed={d} peak={d} admitted={d} active={d} peak_streams={d}\n", .{ self.state.closed, owner.engine.memory.peak, self.state.admitted, self.state.active, self.state.peak_streams });
        self.state.leases.disconnect();
        owner.deinit();
        self.owner = null;
    }

    fn run(self: *Connection) !bool {
        const owner = &self.owner.?;
        // Bound each turn even when a peer continuously sends or reads.
        for (0..32) |_| {
            for (&self.state.requests) |*r| {
                if (!r.ended or r.sent) continue;
                const ticket = self.state.leases.find(r.id.?) orelse unreachable;
                _ = self.state.leases.claim(ticket) orelse unreachable;
                defer std.debug.assert(self.state.leases.finish(ticket));
                var length_buffer: [20]u8 = undefined;
                const length = try std.fmt.bufPrint(&length_buffer, "{d}", .{r.length});
                try owner.respond(r.id.?, 200, &.{
                    .{ .name = "content-type", .value = "application/octet-stream" },
                    .{ .name = "content-length", .value = length },
                }, r.body[0..r.length]);
                @memset(r.body[0..r.length], 0xa5);
                r.sent = true;
            }
            const progress = owner.step() catch |err| switch (err) {
                error.SendFailed, error.ReceiveFailed, error.Protocol => return false,
                else => return err,
            };
            if (owner.watching_writable and !self.blocked_reported) {
                var buffer: [40]u8 = undefined;
                const line = try std.fmt.bufPrint(&buffer, "blocked={d}\n", .{owner.token});
                if (std.c.write(1, line.ptr, line.len) != line.len) return error.StdoutFailed;
                self.blocked_reported = true;
            }
            switch (progress) {
                transport.Progress.closed => return false,
                transport.Progress.waiting => return true,
                transport.Progress.runnable => self.deadline = try net.Deadline.afterMilliseconds(5000),
            }
        }
        return true;
    }
};

pub fn main() !void {
    const ignore = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);
    const listener = try net.listenIpv4(.{ 127, 0, 0, 1 }, 0);
    defer net.closeSocket(listener.socket);
    try net.setListenerNonBlocking(listener.socket);
    var poller = try readiness.Poller.init();
    defer poller.deinit();
    const listener_token = std.math.maxInt(u64);
    try poller.watchReadable(listener.socket, listener_token);
    var port_buffer: [16]u8 = undefined;
    const line = try std.fmt.bufPrint(&port_buffer, "{d}\n", .{listener.port});
    if (std.c.write(1, line.ptr, line.len) != line.len) return error.StdoutFailed;
    var connections: [2]Connection = @splat(.{});
    defer for (&connections) |*connection| if (connection.owner != null) connection.close();
    var next_token: u64 = 1;
    var accepted_any = false;
    var raw: [8]readiness.RawEvent = undefined;
    var events: [8 * readiness.events_per_raw]readiness.Event = undefined;
    while (true) {
        var active: usize = 0;
        var runnable = false;
        for (&connections) |*connection| {
            if (connection.owner == null) continue;
            if (!try connection.run()) {
                connection.close();
                continue;
            }
            if (try net.monotonicNanoseconds() >= connection.deadline.expires_at_nanoseconds) return error.FixtureTimeout;
            active += 1;
            runnable = runnable or connection.owner.?.runnable;
        }
        if (accepted_any and active == 0) break;
        for (try poller.wait(&raw, &events, if (runnable) 0 else 100)) |event| {
            if (event.token != listener_token) {
                for (&connections) |*connection| if (connection.owner) |*owner| {
                    _ = owner.ready(event);
                };
                continue;
            }
            // At most two accepted connections in this fixture. Keep accepting
            // to EAGAIN so the listener's edge is never lost.
            while (true) {
                const accepted = switch (net.acceptPending(listener.socket)) {
                    net.PendingAccept.accepted => |value| value,
                    net.PendingAccept.none => break,
                    else => return error.AcceptFailed,
                };
                var available: ?*Connection = null;
                for (&connections) |*connection| if (connection.owner == null) {
                    available = connection;
                    break;
                };
                const connection = available orelse {
                    net.closeSocket(accepted.socket);
                    continue;
                };
                errdefer net.closeSocket(accepted.socket);
                connection.* = .{};
                connection.state.leases.connection = next_token;
                // A small send buffer makes real socket backpressure reachable
                // without an unbounded response or platform-specific defaults.
                const send_buffer: c_int = 4096;
                if (setsockopt(accepted.socket, std.c.SOL.SOCKET, std.c.SO.SNDBUF, &send_buffer, @sizeOf(c_int)) != 0) return error.SocketOptionFailed;
                connection.deadline = try net.Deadline.afterMilliseconds(5000);
                connection.owner = try transport.Owner.init(std.heap.smp_allocator, accepted.socket, &poller, next_token, .{ .body_bytes = 4096, .header_bytes = 1024 }, .{
                    .context = &connection.state,
                    .header = State.header,
                    .headers_complete = State.headersComplete,
                    .data = State.data,
                    .end = State.end,
                    .closed = State.close,
                });
                connection.owner.?.write_bytes = 7;
                next_token += 1;
                accepted_any = true;
            }
        }
    }
}
