//! A serialized connection transport. The scheduler supplies unique tokens and
//! runs queued application work between bounded steps, outside engine callbacks.
const std = @import("std");
const protocol = @import("engine.zig");
const net = @import("../net.zig");
const bridge = @import("../bridge.zig");
const request = @import("../bridge/http2_request.zig");
const request_types = @import("../bridge/request.zig");
const response = @import("../bridge/http2_response.zig");
const streams = @import("streams.zig");
const readiness = @import("../net/poller.zig");

pub const Error = protocol.Error || net.Error || readiness.Error;
pub const Progress = enum { runnable, waiting, closed };

pub const Owner = struct {
    engine: *protocol.Engine,
    socket: net.Socket,
    poller: *readiness.Poller,
    token: u64,
    runnable: bool = true,
    terminal: bool = false,
    read_eof: bool = false,
    watching_writable: bool = false,
    /// Bounds a write syscall; tests also use this to force short writes.
    write_bytes: usize = 16 * 1024,
    input: [16 * 1024]u8 = undefined,

    /// Takes the nonblocking accepted socket only on success. The token must
    /// never identify a different live connection or a stale queued event.
    pub fn init(allocator: std.mem.Allocator, socket: net.Socket, poller: *readiness.Poller, token: u64, limits: protocol.Limits, observer: protocol.Observer) Error!Owner {
        const engine = try protocol.Engine.create(allocator, limits, observer);
        errdefer engine.destroy();
        try poller.watchReadable(socket, token);
        return .{ .engine = engine, .socket = socket, .poller = poller, .token = token };
    }

    /// Closing the exclusively owned descriptor removes its kernel watches.
    /// The caller must invalidate queued work and cancel application lifetimes
    /// before deinit; engine destruction does not issue observer notifications.
    pub fn deinit(self: *Owner) void {
        net.closeSocket(self.socket);
        self.engine.destroy();
        self.* = undefined;
    }

    pub fn ready(self: *Owner, event: readiness.Event) bool {
        if (self.terminal or event.token != self.token) return false;
        self.runnable = true;
        return true;
    }

    pub fn respond(self: *Owner, id: protocol.StreamId, status: u16, headers: []const protocol.Header, body: []const u8) Error!void {
        if (self.terminal) return error.Closed;
        try self.engine.respond(id, status, headers, body);
        self.runnable = true;
    }

    /// Transfer finite input to the active Roc request domain outside callbacks.
    /// Reject invalid execution/protocol identities without touching input. Once
    /// conversion starts, input is consumed on success or failure. The caller
    /// owns the returned request and must finish the lease after its cleanup.
    pub fn requestOwned(self: *Owner, registry: *streams.Streams, ticket: streams.Ticket, remote: bridge.RemoteAddress, request_id: []const u8, host: bridge.RequestHost) (Error || request.Error)!request_types.HttpRequest {
        if (self.terminal or registry.leases.connection != self.token) return error.Closed;
        const id = registry.leases.runningStream(ticket) orelse return error.Closed;
        try self.engine.checkDispatchable(id);
        const buffer = registry.runningInput(ticket) orelse return error.Closed;
        return request.requestFromHttp2Input(buffer, remote, request_id, host);
    }

    /// Consumes one Roc response on every outcome. The serialized owner must
    /// run this outside engine callbacks, with the Roc host/request domain alive
    /// and the corresponding Roc allocator context active.
    /// A closed or stale execution cannot submit output. The executor still
    /// owns request cleanup and must finish its lease after this returns.
    pub fn respondOwned(self: *Owner, registry: *streams.Streams, ticket: streams.Ticket, value: bridge.HttpResponse, roc_host: *bridge.RocHost, semantics: bridge.ResponseRequestSemantics) (Error || response.Error)!void {
        return self.respondOwnedWithDebug(registry, ticket, value, roc_host, semantics, false);
    }

    pub fn respondOwnedWithDebug(self: *Owner, registry: *streams.Streams, ticket: streams.Ticket, value: bridge.HttpResponse, roc_host: *bridge.RocHost, semantics: bridge.ResponseRequestSemantics, debug: bool) (Error || response.Error)!void {
        const id = if (!self.terminal and registry.leases.connection == self.token)
            registry.leases.runningStream(ticket)
        else
            null;
        const live = id orelse {
            value.decref(roc_host);
            return error.Closed;
        };
        var owned = try response.OwnedResponse.init(value, roc_host, registry.budget.allocator(), semantics, .{
            .header_bytes = self.engine.limits.header_bytes,
            .body_bytes = self.engine.limits.response_bytes,
        });
        defer owned.deinit();
        var headers: [64]protocol.Header = undefined;
        @memcpy(headers[0..owned.headers.len], owned.headers);
        var count = owned.headers.len;
        if (debug) {
            const request_debug = @import("../request_debug.zig");
            var accounted: usize = 42;
            for (owned.headers) |field| accounted += field.name.len + field.value.len + 32;
            var captured: [request_debug.maximum_headers]@import("../http1/encoder.zig").Header = undefined;
            for (request_debug.takeResponseHeadersWithOverhead(&captured, .{
                .bytes = self.engine.limits.header_bytes - accounted,
                .fields = headers.len - count,
            }, 32)) |field| {
                headers[count] = .{
                    .name = if (std.mem.eql(u8, field.name, "X-Roxum-Dbg")) "x-roxum-dbg" else "x-roxum-dbg-truncated",
                    .value = field.value,
                };
                count += 1;
            }
        }
        try self.respond(live, owned.response.status, headers[0..count], owned.body);
    }

    pub fn cancel(self: *Owner, id: protocol.StreamId) Error!void {
        if (self.terminal) return error.Closed;
        try self.engine.cancel(id);
        self.runnable = true;
    }

    /// At most one bounded write and one bounded read per call. A successful
    /// read returns to the scheduler before requesting output, so observer work
    /// can be dispatched outside callbacks. Keep runnable owners on a fair queue
    /// until both directions would block; edge-triggered polling cannot supply
    /// another edge for bytes deliberately left unread after a scheduling turn.
    pub fn step(self: *Owner) Error!Progress {
        if (self.terminal) return Progress.closed;
        if (!self.runnable) return Progress.waiting;
        errdefer self.terminal = true;
        std.debug.assert(self.write_bytes > 0);
        var progress = false;
        const output = try self.engine.output();
        if (output.len == 0 and self.read_eof) {
            self.terminal = true;
            return Progress.closed;
        }
        if (output.len > 0) {
            const count = try net.sendAvailable(self.socket, output[0..@min(output.len, self.write_bytes)]);
            try self.engine.consumeOutput(count);
            progress = count > 0;
            if (count == 0 and !self.watching_writable) {
                try self.poller.watchWritable(self.socket, self.token);
                self.watching_writable = true;
            }
        } else if (self.watching_writable) {
            try self.poller.unwatchWritable(self.socket, self.token);
            self.watching_writable = false;
        }
        if (!self.read_eof) {
            if (try net.receiveAvailable(self.socket, &self.input)) |count| {
                if (count == 0) {
                    // Preserve already queued output after a TCP half-close.
                    // Output blocked on HTTP/2 credit cannot progress after EOF.
                    self.read_eof = true;
                } else {
                    try self.engine.receive(self.input[0..count]);
                }
                progress = true;
            }
        }
        self.runnable = progress;
        return if (progress) Progress.runnable else Progress.waiting;
    }
};

test "queued readiness cannot wake a replaced or terminal connection" {
    var owner: Owner = undefined;
    owner.token = 2;
    owner.runnable = false;
    owner.terminal = false;
    try std.testing.expect(!owner.ready(.{ .kind = readiness.Event.Kind.readable, .token = 1 }));
    try std.testing.expect(!owner.runnable);
    try std.testing.expect(owner.ready(.{ .kind = readiness.Event.Kind.writable, .token = 2 }));
    try std.testing.expect(owner.runnable);
    owner.runnable = false;
    owner.terminal = true;
    try std.testing.expect(!owner.ready(.{ .kind = readiness.Event.Kind.readable, .token = 2, .hangup = true }));
    try std.testing.expect(!owner.runnable);
    try std.testing.expectEqual(Progress.closed, try owner.step());
}

test "failed engine initialization leaves the socket with its caller" {
    const listener = try net.listenIpv4(.{ 127, 0, 0, 1 }, 0);
    defer net.closeSocket(listener.socket);
    try net.setListenerNonBlocking(listener.socket);
    var poller = try readiness.Poller.init();
    defer poller.deinit();
    const Ignore = struct {
        fn header(_: *anyopaque, _: protocol.StreamId, _: protocol.Header) void {}
        fn data(_: *anyopaque, _: protocol.StreamId, _: []const u8) void {}
        fn end(_: *anyopaque, _: protocol.StreamId) void {}
    };
    var context: u8 = 0;
    const observer = protocol.Observer{ .context = &context, .header = Ignore.header, .data = Ignore.data, .end = Ignore.end, .closed = Ignore.end };
    try std.testing.expectError(error.OutOfMemory, Owner.init(std.testing.allocator, listener.socket, &poller, 1, .{ .session_bytes = 0 }, observer));
    try std.testing.expectEqual(net.PendingAccept.none, net.acceptPending(listener.socket));
    try std.testing.expectError(error.PollerChangeFailed, Owner.init(std.testing.allocator, std.math.maxInt(c_int), &poller, 1, .{}, observer));
}
