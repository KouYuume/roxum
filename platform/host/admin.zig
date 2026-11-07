//! The admin port: the supervisor answers `/metrics`, `/ready`, and
//! `/live` on an address and port of its own, apart from the app's, so it
//! answers even while every worker is busy.
//!
//! It runs in the supervisor's loop and never waits: each turn accepts what is
//! queued, reads what arrived, and writes what the socket takes. Every
//! response closes its connection.
const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const metrics = @import("metrics.zig");
const net = @import("net.zig");

/// Connections answered at once; more wait in the kernel's queue.
const maximum_clients: usize = 16;
const maximum_head_bytes: usize = 4096;
/// A client that has not sent its request or read the response by then is
/// closed.
const client_timeout_milliseconds: u64 = 5_000;

const Client = struct {
    socket: net.Socket = -1,
    head: [maximum_head_bytes]u8 = undefined,
    head_length: usize = 0,
    /// The response, an `std.heap.smp_allocator` allocation, once built.
    output: ?[]u8 = null,
    sent: usize = 0,
    deadline_milliseconds: u64 = 0,

    fn close(self: *Client) void {
        if (self.output) |output| std.heap.smp_allocator.free(output);
        net.closeSocket(self.socket);
        self.* = .{};
    }
};

/// What the supervisor knows when it answers.
pub const State = struct {
    /// At least one worker is up and the server is not draining.
    ready: bool,
    workers: usize,
    now_milliseconds: u64,
};

var listener: ?net.Socket = null;
var clients: [maximum_clients]Client = @splat(.{});

/// Listens on the admin port, for the address and port worker 0 reported.
pub fn open(address: [4]u8, port: u16) net.Error!void {
    const opened = try net.listenIpv4(address, port);
    errdefer net.closeSocket(opened.socket);
    try net.setListenerNonBlocking(opened.socket);
    listener = opened.socket;
}

/// Closes the admin sockets in a worker just forked from the supervisor.
pub fn closeInWorker() void {
    if (listener) |socket| net.closeSocket(socket);
    listener = null;
    for (&clients) |*client| {
        if (client.socket == -1) continue;
        net.closeSocket(client.socket);
        client.* = .{};
    }
}

/// One turn of the admin port.
pub fn serve(state: State) void {
    const socket = listener orelse return;
    for (&clients) |*client| {
        if (client.socket != -1) continue;
        switch (net.acceptPending(socket)) {
            net.PendingAccept.accepted => |accepted| {
                client.socket = accepted.socket;
                client.deadline_milliseconds = state.now_milliseconds + client_timeout_milliseconds;
            },
            net.PendingAccept.none, net.PendingAccept.exhausted, net.PendingAccept.failed => break,
        }
    }
    for (&clients) |*client| {
        if (client.socket == -1) continue;
        if (state.now_milliseconds >= client.deadline_milliseconds) {
            client.close();
            continue;
        }
        if (client.output == null) readRequest(client, state) else writeResponse(client);
    }
}

fn readRequest(client: *Client, state: State) void {
    const room = client.head[client.head_length..];
    if (room.len == 0) return answer(client, "431 Request Header Fields Too Large", "", "");
    const received = net.receiveAvailable(client.socket, room) catch return client.close();
    const count = received orelse return;
    if (count == 0) return client.close();
    client.head_length += count;
    const head = client.head[0..client.head_length];
    if (std.mem.indexOf(u8, head, "\r\n\r\n") == null) return;
    respond(client, head, state);
}

fn respond(client: *Client, head: []const u8, state: State) void {
    const line_end = std.mem.indexOf(u8, head, "\r\n").?;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    const method = parts.next() orelse "";
    const target = parts.next() orelse "";
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const head_only = std.mem.eql(u8, method, "HEAD");
    if (!head_only and !std.mem.eql(u8, method, "GET")) return answer(client, "405 Method Not Allowed", "Allow: GET, HEAD\r\n", "");
    if (std.mem.eql(u8, path, "/live")) return answer(client, "200 OK", text_type, if (head_only) "" else "live\n");
    if (std.mem.eql(u8, path, "/ready")) {
        if (state.ready) return answer(client, "200 OK", text_type, if (head_only) "" else "ready\n");
        return answer(client, "503 Service Unavailable", text_type, if (head_only) "" else "not ready\n");
    }
    if (std.mem.eql(u8, path, "/metrics")) {
        var body: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
        defer body.deinit();
        metrics.render(&body.writer, state.workers) catch return answer(client, "500 Internal Server Error", "", "");
        return answer(client, "200 OK", "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n", if (head_only) "" else body.written());
    }
    answer(client, "404 Not Found", text_type, if (head_only) "" else "not found\n");
}

const text_type = "Content-Type: text/plain; charset=utf-8\r\n";

/// Builds the response and starts writing it. `fields` are whole header
/// lines.
fn answer(client: *Client, status: []const u8, fields: []const u8, body: []const u8) void {
    client.output = std.fmt.allocPrint(
        std.heap.smp_allocator,
        "HTTP/1.1 {s}\r\n{s}Content-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{s}",
        .{ status, fields, body.len, body },
    ) catch return client.close();
    writeResponse(client);
}

fn writeResponse(client: *Client) void {
    const output = client.output.?;
    while (client.sent < output.len) {
        const sent = net.sendAvailable(client.socket, output[client.sent..]) catch return client.close();
        if (sent == 0) return;
        client.sent += sent;
    }
    client.close();
}

test "the admin port answers its paths and refuses other methods" {
    const testing = std.testing;
    try open(.{ 127, 0, 0, 1 }, 0);
    defer {
        closeInWorker();
    }
    var address: std.c.sockaddr.in = undefined;
    var length: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    try testing.expectEqual(@as(c_int, 0), std.c.getsockname(listener.?, @ptrCast(&address), &length));
    const port = std.mem.bigToNative(u16, address.port);

    const cases = [_]struct { request: []const u8, ready: bool, status: []const u8 }{
        .{ .request = "GET /live HTTP/1.1\r\n\r\n", .ready = false, .status = "HTTP/1.1 200 OK" },
        .{ .request = "GET /ready HTTP/1.1\r\n\r\n", .ready = true, .status = "HTTP/1.1 200 OK" },
        .{ .request = "GET /ready HTTP/1.1\r\n\r\n", .ready = false, .status = "HTTP/1.1 503 Service Unavailable" },
        .{ .request = "GET /metrics?x=1 HTTP/1.1\r\n\r\n", .ready = true, .status = "HTTP/1.1 200 OK" },
        .{ .request = "POST /live HTTP/1.1\r\n\r\n", .ready = true, .status = "HTTP/1.1 405 Method Not Allowed" },
        .{ .request = "GET /other HTTP/1.1\r\n\r\n", .ready = true, .status = "HTTP/1.1 404 Not Found" },
    };
    for (cases) |case| {
        const socket = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        defer _ = std.c.close(socket);
        var target = std.c.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        try testing.expectEqual(@as(c_int, 0), std.c.connect(socket, @ptrCast(&target), @sizeOf(std.c.sockaddr.in)));
        try testing.expectEqual(@as(isize, @intCast(case.request.len)), std.c.write(socket, case.request.ptr, case.request.len));
        var response: [4096]u8 = undefined;
        var received: usize = 0;
        for (0..200) |_| {
            serve(.{ .ready = case.ready, .workers = 1, .now_milliseconds = 0 });
            const count = std.c.recv(socket, response[received..].ptr, response.len - received, std.c.MSG.DONTWAIT);
            if (count > 0) received += @intCast(count);
            if (count == 0) break;
            const pause = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = std.c.nanosleep(&pause, null);
        }
        try testing.expect(std.mem.startsWith(u8, response[0..received], case.status));
    }
}
