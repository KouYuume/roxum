//! HTTP/2 connection state, accessed only under its worker connection lock.
const std = @import("std");
const engine = @import("engine.zig");
const transport = @import("owner.zig");
const input = @import("input.zig");
const streams = @import("streams.zig");
const net = @import("../net.zig");
const poller = @import("../net/poller.zig");
const fiber = @import("../fiber.zig");
const fiber_wait = @import("../fiber_wait.zig");

var worker_memory = @import("worker_memory.zig").Budget{};

pub const Execution = struct {
    ticket: ?streams.Ticket = null,
    claimed: bool = false,
    waiter: ?struct { target: *fiber.Fiber, serial: u64, body_limit: ?u64 = null } = null,
};

pub const Connection = struct {
    owner: transport.Owner = undefined,
    budget: input.Budget = .{ .backing = std.heap.smp_allocator, .limit = 16 * 1024 * 1024 },
    streams: streams.Streams = undefined,
    executions: [16]Execution = @splat(.{}),
    failed: bool = false,
    closed: bool = false,
    draining: bool = false,
    now: u64 = 0,
    deadlines: [16]u64 = @splat(0),
    body_deadlines: [16]u64 = @splat(0),
    writing: [16]bool = @splat(false),
    terminal_write_deadline: u64 = 0,
    header_deadline: u64 = 0,
    head_timeout: u64 = 0,
    body_timeout: u64 = 0,
    write_timeout: u64 = 0,
    execution_limit: ?u64 = null,
    completed_access: [16]@import("../access_log.zig").Entry = undefined,
    completed_access_count: usize = 0,
    access: [16]?@import("../access_log.zig").Entry = @splat(null),

    pub fn create(socket: net.Socket, readiness: *poller.Poller, token: u64, limits: @import("../connection.zig").Limits) !*Connection {
        const self = try worker_memory.allocator().create(Connection);
        errdefer worker_memory.allocator().destroy(self);
        self.* = .{
            .head_timeout = limits.request_head_timeout_milliseconds * std.time.ns_per_ms,
            .body_timeout = limits.request_body_timeout_milliseconds * std.time.ns_per_ms,
            .write_timeout = limits.response_write_timeout_milliseconds * std.time.ns_per_ms,
            .execution_limit = limits.http2_execution_nanoseconds,
        };
        self.budget.backing = worker_memory.allocator();
        const body_limit = std.math.cast(usize, limits.maximum_body_bytes) orelse std.math.maxInt(usize);
        self.streams = streams.Streams.init(token, &self.budget, .{ .header_bytes = 16 * 1024, .body_bytes = body_limit });
        self.owner = try transport.Owner.init(worker_memory.allocator(), socket, readiness, token, .{
            .session_bytes = 16 * 1024 * 1024,
            .body_bytes = body_limit,
            .response_bytes = 2 * 1024 * 1024,
        }, .{
            .context = self,
            .headers_started = headersStarted,
            .headers_finished = headersFinished,
            .header = header,
            .headers_complete = headersComplete,
            .data = data,
            .end = end,
            .closed = streamClosed,
        });
        return self;
    }

    pub fn destroy(self: *Connection) void {
        std.debug.assert(!self.busy());
        self.streams.disconnect();
        self.owner.engine.destroy();
        std.debug.assert(self.budget.used == 0);
        worker_memory.allocator().destroy(self);
    }

    pub fn busy(self: *const Connection) bool {
        for (self.executions) |entry| if (entry.ticket != null) return true;
        return false;
    }

    pub fn execution(self: *Connection, ticket: streams.Ticket) ?*Execution {
        if (ticket.slot >= self.executions.len) return null;
        const value = &self.executions[ticket.slot];
        const current = value.ticket orelse return null;
        if (current.connection != ticket.connection or current.sequence != ticket.sequence) return null;
        return value;
    }

    pub fn wakeClosed(self: *Connection) void {
        for (self.executions) |execution_value| {
            const ticket = execution_value.ticket orelse continue;
            const waiter = execution_value.waiter orelse continue;
            if (self.streams.leases.runningStream(ticket) == null) {
                fiber_wait.wakeStopped(waiter.target, waiter.serial, fiber.Stop.client_gone);
            } else if (waiter.body_limit) |limit| {
                if (self.bodyReady(ticket, limit)) fiber_wait.wake(waiter.target, waiter.serial);
            }
        }
    }

    /// Called under the owner lock both after input callbacks and when parking
    /// a reader. The second check closes the input-completion/parking race.
    pub fn bodyReady(self: *Connection, ticket: streams.Ticket, limit: u64) bool {
        const buffer = self.streams.runningInput(ticket) orelse return true;
        return buffer.phase == input.Phase.rejected or buffer.body() != null or buffer.bytes.items.len > limit;
    }

    pub fn disconnect(self: *Connection) void {
        if (self.closed) return;
        self.closed = true;
        self.owner.terminal = true;
        for (&self.access) |*entry| {
            if (entry.*) |*value| {
                if (value.outcome == @import("../access_log.zig").Outcome.handled) value.outcome = @import("../access_log.zig").Outcome.client_closed;
                @import("../access_log.zig").record(value, self.now);
            }
            entry.* = null;
        }
        for (self.completed_access[0..self.completed_access_count]) |*entry| {
            if (entry.outcome == @import("../access_log.zig").Outcome.handled) entry.outcome = @import("../access_log.zig").Outcome.client_closed;
            @import("../access_log.zig").record(entry, self.now);
        }
        self.completed_access_count = 0;
        self.streams.disconnect();
        self.wakeClosed();
        // Remove interest before close so a concurrent epoll scan cannot
        // defer the socket's final release until its next userspace return.
        self.owner.poller.unwatchReadable(self.owner.socket) catch {};
        net.closeSocket(self.owner.socket);
    }

    pub fn recordCompleted(self: *Connection) void {
        // Terminal frame callbacks run before send. Keep copied access entries
        // separate from reusable stream slots until those bytes are written.
        if (self.owner.engine.pending.len != 0) {
            if (self.terminal_write_deadline == 0) self.terminal_write_deadline = self.now +| self.write_timeout;
            return;
        }
        self.terminal_write_deadline = 0;
        for (self.completed_access[0..self.completed_access_count]) |*entry| @import("../access_log.zig").record(entry, self.now);
        self.completed_access_count = 0;
    }

    pub fn expire(self: *Connection, now: u64) void {
        self.now = now;
        if (self.streams.expireExecutions(now)) self.owner.runnable = true;
        for (self.streams.entries, 0..) |entry, index| {
            const ticket = entry.ticket orelse continue;
            if (!self.streams.leases.executionExpired(ticket)) continue;
            if (self.access[index]) |*value| {
                if (value.outcome == @import("../access_log.zig").Outcome.handled) value.outcome = @import("../access_log.zig").Outcome.timeout;
            }
        }
        if ((self.header_deadline != 0 and now >= self.header_deadline) or
            (self.terminal_write_deadline != 0 and now >= self.terminal_write_deadline))
        {
            self.failed = true;
            self.owner.runnable = true;
        }
        for (0..self.deadlines.len) |slot| {
            const body_deadline = &self.body_deadlines[slot];
            if (body_deadline.* != 0 and now >= body_deadline.*) {
                body_deadline.* = 0;
                if (self.streams.entries[slot].ticket) |ticket| {
                    if (self.access[slot]) |*entry| entry.outcome = @import("../access_log.zig").Outcome.timeout;
                    if (self.streams.leases.stream(ticket)) |id| self.cancelTimedOut(id);
                }
            }
            const deadline = &self.deadlines[slot];
            if (deadline.* == 0 or now < deadline.*) continue;
            deadline.* = 0;
            if (self.owner.watching_writable) self.failed = true;
            const ticket = self.streams.entries[slot].ticket orelse continue;
            if (self.streams.leases.stream(ticket)) |id| self.cancelTimedOut(id);
        }
    }

    fn cancelTimedOut(self: *Connection, id: engine.StreamId) void {
        self.owner.cancel(id) catch {
            // A failed reset must not strand a waiter after its timer is cleared.
            self.failed = true;
            self.owner.runnable = true;
        };
    }

    fn from(ptr: *anyopaque) *Connection {
        return @ptrCast(@alignCast(ptr));
    }
    fn headersStarted(ptr: *anyopaque, _: engine.StreamId) void {
        const self = from(ptr);
        self.header_deadline = self.now +| self.head_timeout;
    }
    fn headersFinished(ptr: *anyopaque, _: engine.StreamId) void {
        from(ptr).header_deadline = 0;
    }
    fn header(ptr: *anyopaque, id: engine.StreamId, field: engine.Header) void {
        const self = from(ptr);
        self.streams.header(id, field) catch {
            self.failed = true;
            return;
        };
    }
    fn headersComplete(ptr: *anyopaque, id: engine.StreamId) void {
        const self = from(ptr);
        // Event-batch time can predate lock contention and frame decoding.
        const completed_at = net.monotonicNanoseconds() catch {
            self.failed = true;
            return;
        };
        self.streams.headersComplete(id, completed_at) catch {
            self.failed = true;
            return;
        };
        if (self.streams.leases.find(id)) |ticket| {
            self.body_deadlines[ticket.slot] = self.now +| self.body_timeout;
            // Rejected input has no completed metadata and is already queued for reset.
            if (self.streams.leases.headersElapsed(ticket, completed_at) == null) return;
            if (self.execution_limit) |duration| {
                if (!self.streams.leases.limitExecution(ticket, duration, duration)) self.failed = true;
            }
        }
    }
    fn data(ptr: *anyopaque, id: engine.StreamId, bytes: []const u8) void {
        const self = from(ptr);
        self.streams.data(id, bytes) catch {
            self.failed = true;
        };
    }
    fn end(ptr: *anyopaque, id: engine.StreamId) void {
        const self = from(ptr);
        self.streams.end(id) catch {
            self.failed = true;
        };
        if (self.streams.leases.find(id)) |ticket| self.body_deadlines[ticket.slot] = 0;
    }
    fn streamClosed(ptr: *anyopaque, id: engine.StreamId) void {
        const self = from(ptr);
        if (self.streams.leases.find(id)) |ticket| {
            const deadline = self.deadlines[ticket.slot];
            if (self.writing[ticket.slot] and self.owner.engine.close_error == 0 and deadline != 0) {
                if (self.terminal_write_deadline == 0 or deadline < self.terminal_write_deadline) self.terminal_write_deadline = deadline;
            }
            self.body_deadlines[ticket.slot] = 0;
            self.writing[ticket.slot] = false;
            self.deadlines[ticket.slot] = 0;
            if (self.access[ticket.slot]) |*entry| {
                if (self.owner.engine.close_error != 0 or entry.status == 0) {
                    if (entry.outcome == @import("../access_log.zig").Outcome.handled) entry.outcome = @import("../access_log.zig").Outcome.client_closed;
                    @import("../access_log.zig").record(entry, self.now);
                } else if (self.completed_access_count < self.completed_access.len) {
                    self.completed_access[self.completed_access_count] = entry.*;
                    self.completed_access_count += 1;
                } else {
                    self.failed = true;
                }
            }
            self.access[ticket.slot] = null;
        }
        self.streams.close(id);
    }
};

test "execution expiry records timeout and preserves running cleanup" {
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
    defer net.closeSocket(pair[1]);
    try net.setListenerNonBlocking(pair[0]);
    var readiness = try poller.Poller.init();
    defer readiness.deinit();
    const connection = try Connection.create(pair[0], &readiness, 1, .{ .http2_execution_nanoseconds = 10 });
    defer {
        connection.disconnect();
        connection.destroy();
    }
    connection.now = 100;
    try connection.owner.engine.receive("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
        "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
        "\x00\x00\x0e\x01\x05\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost");
    const work = connection.streams.next().?.execute;
    const anchor = work.headers_at;
    connection.access[work.ticket.slot] = .{};
    connection.owner.runnable = false;
    connection.expire(anchor + 9);
    try std.testing.expect(connection.streams.runningInput(work.ticket) != null);
    connection.expire(anchor + 10);
    try std.testing.expect(connection.owner.runnable);
    try std.testing.expect(connection.streams.runningInput(work.ticket) == null);
    try std.testing.expectEqual(@import("../access_log.zig").Outcome.timeout, connection.access[work.ticket.slot].?.outcome);
    try std.testing.expectEqual(work.id, connection.streams.next().?.cancel);
    try std.testing.expect(connection.streams.next() == null);
    try connection.owner.cancel(work.id);
    while (true) {
        const bytes = try connection.owner.engine.output();
        if (bytes.len == 0) break;
        try connection.owner.engine.consumeOutput(bytes.len);
    }
    try std.testing.expect(connection.streams.finish(work.ticket));
    try std.testing.expectEqual(@as(usize, 0), connection.budget.used);
}

test "configured execution cap starts before body completion and queue claim" {
    for ([_]?u64{ null, 10 }) |limit| {
        for ([_]bool{ false, true }) |body_complete| {
            var pair: [2]c_int = undefined;
            try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
            defer net.closeSocket(pair[1]);
            try net.setListenerNonBlocking(pair[0]);
            var readiness = try poller.Poller.init();
            defer readiness.deinit();
            const connection = try Connection.create(pair[0], &readiness, 1, .{ .http2_execution_nanoseconds = limit });
            defer {
                connection.disconnect();
                connection.destroy();
            }
            connection.now = 100;
            const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00";
            try connection.owner.engine.receive(preface);
            var frame = "\x00\x00\x0e\x01\x04\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost".*;
            if (body_complete) frame[4] = 5;
            const before = try net.monotonicNanoseconds();
            try connection.owner.engine.receive(&frame);
            const after = try net.monotonicNanoseconds();
            const ticket = connection.streams.leases.find(@fromBackingInt(1)).?;
            const anchor = after - connection.streams.leases.headersElapsed(ticket, after).?;
            try std.testing.expect(anchor >= before and anchor <= after);
            try std.testing.expect(anchor > connection.now);
            connection.expire(anchor + 9);
            try std.testing.expect(!connection.streams.leases.executionExpired(ticket));
            for ([_]u64{ anchor + 10, anchor + 11 }) |now| {
                connection.expire(now);
                try std.testing.expectEqual(limit != null, connection.streams.leases.executionExpired(ticket));
            }
            if (limit != null) {
                try std.testing.expectEqual(@as(engine.StreamId, @fromBackingInt(1)), connection.streams.next().?.cancel);
                try std.testing.expect(connection.streams.next() == null);
                try std.testing.expectEqual(@as(usize, 0), connection.budget.used);
            } else if (body_complete) {
                const work = connection.streams.next().?.execute;
                try std.testing.expect(connection.streams.finish(work.ticket));
            } else try std.testing.expect(connection.streams.next() == null);
        }
    }
}

test "body wait readiness covers EOF rejection and route-limit boundaries" {
    var connection = Connection{};
    connection.budget.backing = std.testing.allocator;
    connection.streams = streams.Streams.init(1, &connection.budget, .{ .header_bytes = 1024, .body_bytes = 8 });
    defer connection.streams.disconnect();
    const id: engine.StreamId = @fromBackingInt(1);
    try connection.streams.header(id, .{ .name = ":method", .value = "POST" });
    try connection.streams.headersComplete(id, 0);
    const work = connection.streams.nextMetadata().?.execute;
    defer _ = connection.streams.finish(work.ticket);
    try std.testing.expect(!connection.bodyReady(work.ticket, 4));
    try connection.streams.data(id, "123");
    try std.testing.expect(!connection.bodyReady(work.ticket, 4));
    try connection.streams.data(id, "4");
    try std.testing.expect(!connection.bodyReady(work.ticket, 4));
    try connection.streams.data(id, "5");
    try std.testing.expect(connection.bodyReady(work.ticket, 4));
    try std.testing.expect(!connection.bodyReady(work.ticket, 8));
    try connection.streams.end(id);
    try std.testing.expect(connection.bodyReady(work.ticket, 8));
    // A waiter installed after EOF observes the same ready state as a waiter
    // already present when input completes. Expiry also cannot leave it asleep.
    try std.testing.expect(connection.streams.leases.limitExecution(work.ticket, 0, 0));
    try std.testing.expect(connection.streams.expireExecutions(0));
    try std.testing.expect(connection.bodyReady(work.ticket, 8));
    connection.streams.close(id);
    try std.testing.expect(connection.bodyReady(work.ticket, 8));
}

test "input and response deadlines remain independent after metadata dispatch" {
    for ([_]bool{ false, true }) |end_input| {
        var pair: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
        defer net.closeSocket(pair[1]);
        try net.setListenerNonBlocking(pair[0]);
        var readiness = try poller.Poller.init();
        defer readiness.deinit();
        const connection = try Connection.create(pair[0], &readiness, 1, .{});
        defer {
            connection.disconnect();
            connection.destroy();
        }
        connection.now = 100;
        connection.body_timeout = 10;
        try connection.owner.engine.receive("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
            "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
            "\x00\x00\x0e\x01\x04\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost");
        const work = connection.streams.nextMetadata().?.execute;
        defer _ = connection.streams.finish(work.ticket);
        const slot = work.ticket.slot;
        connection.deadlines[slot] = 200;
        connection.writing[slot] = true;
        try std.testing.expectEqual(@as(u64, 110), connection.body_deadlines[slot]);
        if (end_input) {
            try connection.owner.engine.receive("\x00\x00\x00\x00\x01\x00\x00\x00\x01");
            try std.testing.expectEqual(@as(u64, 0), connection.body_deadlines[slot]);
        }
        connection.expire(109);
        try connection.owner.engine.checkDispatchable(work.id);
        connection.expire(110);
        connection.expire(111);
        try std.testing.expectEqual(@as(u64, 200), connection.deadlines[slot]);
        if (end_input) {
            try connection.owner.engine.checkDispatchable(work.id);
        } else {
            try std.testing.expectError(error.Closed, connection.owner.engine.checkDispatchable(work.id));
        }
    }
}

test "timeout reset allocation failure schedules connection termination" {
    for ([_]bool{ false, true }) |body_timeout| {
        var pair: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
        defer net.closeSocket(pair[1]);
        try net.setListenerNonBlocking(pair[0]);
        var readiness = try poller.Poller.init();
        defer readiness.deinit();
        const connection = try Connection.create(pair[0], &readiness, 1, .{});
        defer {
            connection.disconnect();
            connection.destroy();
        }
        connection.now = 100;
        connection.body_timeout = 10;
        try connection.owner.engine.receive("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
            "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
            "\x00\x00\x0e\x01\x04\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost");
        const work = connection.streams.nextMetadata().?.execute;
        defer _ = connection.streams.finish(work.ticket);
        if (!body_timeout) {
            connection.body_deadlines[work.ticket.slot] = 0;
            connection.deadlines[work.ticket.slot] = 110;
        }
        connection.owner.engine.memory.limit = connection.owner.engine.memory.used;
        connection.owner.runnable = false;
        connection.expire(109);
        try std.testing.expect(!connection.failed);
        connection.expire(110);
        try std.testing.expect(connection.failed);
        try std.testing.expect(connection.owner.runnable);
        try std.testing.expectEqual(@as(u64, 0), connection.body_deadlines[work.ticket.slot]);
        try std.testing.expectEqual(@as(u64, 0), connection.deadlines[work.ticket.slot]);
        connection.expire(111);
        try std.testing.expect(connection.failed);
    }
}
