//! Independent-client fixture for the engine, not a production listener.
const std = @import("std");
const http2 = @import("http2_engine").engine;
const input = @import("http2_engine").input;
const streams = @import("http2_engine").streams;
const roc_values = @import("roc_values.zig");
const bridge = @import("http2_engine").bridge;
const transport = @import("http2_engine").owner;
const readiness = @import("http2_engine").poller;
const net = @import("http2_engine").net;
extern "c" fn setsockopt(c_int, c_int, c_int, *const anyopaque, u32) c_int;

const State = struct {
    budget: input.Budget = .{ .backing = std.heap.smp_allocator, .limit = 128 * 1024 },
    streams: streams.Streams = undefined,
    failed: bool = false,
    closed: usize = 0,
    admitted: usize = 0,
    active: usize = 0,
    peak_streams: usize = 0,
    fn from(ctx: *anyopaque) *State {
        return @ptrCast(@alignCast(ctx));
    }
    fn header(ctx: *anyopaque, id: http2.StreamId, field: http2.Header) void {
        const self = from(ctx);
        const existing = self.streams.leases.find(id) != null;
        self.streams.header(id, field) catch {
            self.failed = true;
            return;
        };
        if (!existing) {
            self.admitted += 1;
            self.active += 1;
            self.peak_streams = @max(self.peak_streams, self.active);
        }
    }
    fn headersComplete(ctx: *anyopaque, id: http2.StreamId) void {
        const self = from(ctx);
        const now = net.monotonicNanoseconds() catch {
            self.failed = true;
            return;
        };
        self.streams.headersComplete(id, now) catch {
            self.failed = true;
        };
    }
    fn data(ctx: *anyopaque, id: http2.StreamId, bytes: []const u8) void {
        const self = from(ctx);
        self.streams.data(id, bytes) catch {
            self.failed = true;
        };
    }
    fn end(ctx: *anyopaque, id: http2.StreamId) void {
        const self = from(ctx);
        self.streams.end(id) catch {
            self.failed = true;
        };
    }
    fn close(ctx: *anyopaque, id: http2.StreamId) void {
        const self = from(ctx);
        if (self.streams.leases.find(id) != null) self.active -= 1;
        self.streams.close(id);
        self.closed += 1;
    }
};

const Connection = struct {
    state: State = .{},
    remote: bridge.RemoteAddress = bridge.RemoteAddress.unix,
    owner: ?transport.Owner = null,
    deadline: net.Deadline = undefined,
    blocked_reported: bool = false,

    fn close(self: *Connection) void {
        const owner = &self.owner.?;
        std.debug.print("closed={d} peak={d} admitted={d} active={d} peak_streams={d}\n", .{ self.state.closed, owner.engine.memory.peak, self.state.admitted, self.state.active, self.state.peak_streams });
        self.state.streams.disconnect();
        owner.deinit();
        std.debug.assert(self.state.budget.used == 0);
        self.owner = null;
    }

    fn run(self: *Connection) !bool {
        const owner = &self.owner.?;
        // Bound each turn even when a peer continuously sends or reads.
        for (0..32) |_| {
            if (self.state.failed) return false;
            while (self.state.streams.next()) |work| {
                const execution = switch (work) {
                    streams.Work.cancel => |id| {
                        try owner.cancel(id);
                        continue;
                    },
                    streams.Work.execute => |value| value,
                };
                defer std.debug.assert(self.state.streams.finish(execution.ticket));
                var values = roc_values.Environment{ .allocator = std.heap.smp_allocator };
                var host = values.rocHost();
                defer std.debug.assert(values.live_allocations == 0);
                const request = owner.requestOwned(&self.state.streams, execution.ticket, self.remote, "fixture-request", roc_values.Environment.requestHost(&host)) catch {
                    try owner.cancel(execution.id);
                    continue;
                };
                defer request.decref(&host);
                const body = if (request.body.tag == bridge.HttpRequestBodyTag.Bytes) request.body.payload_bytes().items() else "";
                const path = request.raw_target.items();
                var count_buffer: [20]u8 = undefined;
                const field_count = try std.fmt.bufPrint(&count_buffer, "{d}", .{request.headers.items().len});
                var path_length_buffer: [20]u8 = undefined;
                const path_length = try std.fmt.bufPrint(&path_length_buffer, "{d}", .{path.len});
                const semantics = if (request.method == bridge.HttpMethod.head) bridge.ResponseRequestSemantics.head else bridge.ResponseRequestSemantics.regular;
                const response = roc_values.response(200, &.{
                    .{ .name = "content-type", .value = "application/octet-stream" },
                    .{ .name = "x-initial-fields", .value = field_count },
                    .{ .name = "x-request-path", .value = path[0..@min(path.len, 64)] },
                    .{ .name = "x-request-path-length", .value = path_length },
                }, body, &host);
                try owner.respondOwned(&self.state.streams, execution.ticket, response, &host, semantics);
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
    const input_budget = if (std.c.getenv("ROXUM_TEST_HTTP2_INPUT_BUDGET")) |value|
        try std.fmt.parseInt(usize, std.mem.span(value), 10)
    else
        128 * 1024;
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
                connection.remote = .{ .v4 = .{ .octets = accepted.remote_address.v4, .port = accepted.remote_port } };
                connection.state.streams = streams.Streams.init(next_token, &connection.state.budget, .{ .header_bytes = 1024, .body_bytes = 4096 });
                connection.state.budget.limit = input_budget;
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
