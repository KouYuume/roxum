//! HTTP/2 connection state, accessed only under its worker connection lock.
const std = @import("std");
const engine = @import("engine.zig");
const transport = @import("owner.zig");
const input = @import("input.zig");
const streams = @import("streams.zig");
const net = @import("../net.zig");
const poller = @import("../net/poller.zig");
const fiber = @import("../fiber.zig");
const terminal = @import("terminal_fields.zig");
const fiber_wait = @import("../fiber_wait.zig");

var worker_memory = @import("worker_memory.zig").Budget{};

pub const Execution = struct {
    ticket: ?streams.Ticket = null,
    claimed: bool = false,
    response_complete: bool = false,
    finishing: bool = false,
    waiter: ?struct { target: *fiber.Fiber, serial: u64, body_limit: ?u64 = null, output: bool = false, completion: bool = false } = null,
};

pub const Connection = struct {
    owner: transport.Owner = undefined,
    budget: input.Budget = .{ .backing = std.heap.smp_allocator, .limit = 16 * 1024 * 1024 },
    streams: streams.Streams = undefined,
    executions: [16]Execution = @splat(.{}),
    terminals: [16]terminal.Terminal = @splat(.{}),
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
            .response_sent = responseSent,
        });
        return self;
    }

    pub fn destroy(self: *Connection) void {
        std.debug.assert(!self.busy());
        self.streams.disconnect();
        for (&self.terminals) |*value| value.deinit();
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
            if (waiter.completion and execution_value.finishing and !self.failed and !self.closed) {
                if (execution_value.response_complete) fiber_wait.wake(waiter.target, waiter.serial);
                // Protocol close may precede consumption of terminal output.
                if (self.terminals[ticket.slot].selection == terminal.Selection.normal or execution_value.response_complete) continue;
            }
            if (self.streams.leases.runningStream(ticket) == null) {
                fiber_wait.wakeStopped(waiter.target, waiter.serial, fiber.Stop.client_gone);
            } else if (waiter.output) {
                if (self.outputReady(ticket)) fiber_wait.wake(waiter.target, waiter.serial);
            } else if (waiter.body_limit) |limit| {
                if (self.bodyReady(ticket, limit)) fiber_wait.wake(waiter.target, waiter.serial);
            }
        }
    }

    pub fn outputReady(self: *Connection, ticket: streams.Ticket) bool {
        if (self.failed or self.closed) return true;
        const id = self.streams.leases.runningStream(ticket) orelse return true;
        return self.owner.engine.streamingReady(id) catch true;
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
        for (&self.terminals) |*value| value.deinit();
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

    /// Register expiry fields before committing headers. Failed validation leaves
    /// the previous deadline and snapshot unchanged.
    pub fn registerExpiryTrailers(self: *Connection, ticket: streams.Ticket, duration: u64, fields: []const engine.Header) !void {
        const id = self.streams.leases.runningStream(ticket) orelse return error.Closed;
        try self.owner.engine.checkDispatchable(id);
        var copy = try terminal.Fields.init(self.budget.allocator(), self.owner.engine, fields);
        errdefer copy.deinit();
        if (!self.streams.leases.limitExecution(ticket, duration, std.math.maxInt(u64))) return error.Closed;
        self.terminals[ticket.slot].deinit();
        self.terminals[ticket.slot].fields = copy;
        self.streams.clearExpiryResponse(ticket);
    }

    /// Selection is serialized with expiry. Accepted normal completion disables
    /// execution expiry, but never the response-write deadline.
    pub fn selectCompletion(self: *Connection, ticket: streams.Ticket, fields: []const engine.Header) !void {
        const copy = try terminal.Fields.init(self.budget.allocator(), self.owner.engine, fields);
        return self.selectPreparedCompletion(ticket, copy);
    }

    /// Consumes the copied fields on every outcome. Production callers recheck
    /// expiry after preparing the copy, before selecting normal completion.
    pub fn selectPreparedCompletion(self: *Connection, ticket: streams.Ticket, fields: terminal.Fields) !void {
        var copy = fields;
        errdefer copy.deinit();
        const id = self.streams.leases.runningStream(ticket) orelse return error.Closed;
        const selected = &self.terminals[ticket.slot];
        if (selected.selection != terminal.Selection.open) return error.InvalidState;
        _ = try self.owner.engine.streamingReady(id);
        if (!self.streams.leases.commitResponse(ticket)) return error.Closed;
        selected.deinit();
        selected.* = .{ .selection = terminal.Selection.normal, .fields = copy };
        self.streams.clearExpiryResponse(ticket);
        if (self.execution(ticket)) |execution_value| execution_value.finishing = true;
        self.owner.runnable = true;
    }

    /// Retry selected terminal metadata only after accepted DATA has drained.
    /// This also runs after an expired request fiber has been abandoned.
    pub fn advanceTerminals(self: *Connection) void {
        for (&self.terminals, 0..) |*selected, index| {
            if (selected.selection == terminal.Selection.open or selected.submitted) continue;
            const ticket = self.streams.entries[index].ticket orelse continue;
            const id = self.streams.leases.stream(ticket) orelse continue;
            const ready = self.owner.engine.streamingReady(id) catch {
                selected.deinit();
                self.cancelTimedOut(id);
                continue;
            };
            if (!ready) continue;
            const fields = &(selected.fields orelse unreachable);
            self.owner.engine.finishResponse(id, fields.fields) catch {
                selected.deinit();
                self.cancelTimedOut(id);
                continue;
            };
            selected.fields.?.deinit();
            selected.fields = null;
            selected.submitted = true;
            self.owner.runnable = true;
        }
    }

    /// Called between engine operations, under the connection lock. Expiry has
    /// already invalidated execution; only its copied response remains usable.
    pub fn completeExpired(self: *Connection, id: engine.StreamId) !void {
        const ticket = self.streams.leases.find(id) orelse return;
        defer self.streams.clearExpiryResponse(ticket);
        if (self.streams.leases.executionExpired(ticket)) {
            const selected = &self.terminals[ticket.slot];
            if (selected.fields != null and selected.selection == terminal.Selection.open) {
                _ = self.owner.engine.streamingReady(id) catch {
                    selected.deinit();
                    return self.owner.cancel(id);
                };
                selected.selection = terminal.Selection.expiry;
                self.owner.runnable = true;
                return;
            }
            if (self.streams.entries[ticket.slot].expiry_response) |*response| {
                // An I/O timeout may already have queued a reset in this tick.
                // Never replace it or turn its stream-local failure into a close.
                self.owner.engine.checkDispatchable(id) catch |err| switch (err) {
                    error.Closed => return,
                    error.InvalidState => {
                        // Keep finite or already-finishing output. An open writer
                        // has no generic expiry trailers yet, so reset it.
                        _ = self.owner.engine.streamingReady(id) catch return;
                        return self.owner.cancel(id);
                    },
                    else => return err,
                };
                try response.submit(self.owner.engine, id);
                self.owner.runnable = true;
                self.deadlines[ticket.slot] = self.now +| self.write_timeout;
                self.writing[ticket.slot] = true;
                if (self.access[ticket.slot]) |*entry| {
                    entry.outcome = @import("../access_log.zig").Outcome.timeout;
                    entry.status = response.status;
                    entry.body_bytes = response.body.len;
                }
                return;
            }
        }
        try self.owner.cancel(id);
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
    fn responseSent(ptr: *anyopaque, id: engine.StreamId) void {
        const self = from(ptr);
        if (self.streams.leases.find(id)) |ticket| {
            self.deadlines[ticket.slot] = 0;
            self.writing[ticket.slot] = false;
            if (self.execution(ticket)) |execution_value| {
                if (execution_value.finishing and self.terminals[ticket.slot].selection == terminal.Selection.normal) execution_value.response_complete = true;
            }
            self.terminals[ticket.slot].deinit();
        }
    }
    fn streamClosed(ptr: *anyopaque, id: engine.StreamId) void {
        const self = from(ptr);
        if (self.streams.leases.find(id)) |ticket| {
            const deadline = self.deadlines[ticket.slot];
            if (self.writing[ticket.slot] and self.owner.engine.close_error == 0 and !self.owner.engine.close_peer_reset and deadline != 0) {
                if (self.terminal_write_deadline == 0 or deadline < self.terminal_write_deadline) self.terminal_write_deadline = deadline;
            }
            if (self.owner.engine.close_error != 0 or self.owner.engine.close_peer_reset or self.terminals[ticket.slot].selection != terminal.Selection.normal) self.terminals[ticket.slot].deinit();
            self.body_deadlines[ticket.slot] = 0;
            self.writing[ticket.slot] = false;
            self.deadlines[ticket.slot] = 0;
            if (self.access[ticket.slot]) |*entry| {
                if (self.owner.engine.close_error != 0 or self.owner.engine.close_peer_reset or entry.status == 0) {
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

test "early response write deadline ends only after the final output byte" {
    const Form = enum { empty, body, trailers };
    for ([_]Form{ Form.empty, Form.body, Form.trailers }) |form| {
        for ([_]bool{ false, true }) |finish_output| {
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
            connection.body_timeout = 100;
            try connection.owner.engine.receive("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
                "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
                "\x00\x00\x0e\x01\x04\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost");
            const work = connection.streams.nextMetadata().?.execute;
            const slot = work.ticket.slot;
            try connection.owner.engine.respondWithTrailers(work.id, 403, &.{}, if (form == Form.empty) "" else "denied", if (form == Form.trailers) &.{.{ .name = "x-result", .value = "done" }} else &.{});
            connection.deadlines[slot] = 110;
            connection.writing[slot] = true;
            try std.testing.expect(connection.streams.finish(work.ticket));
            // One unsent byte still needs a write deadline, even after the
            // terminal frame and any trailers have been serialized.
            while (true) {
                const bytes = try connection.owner.engine.output();
                try std.testing.expect(bytes.len > 0);
                try std.testing.expectEqual(@as(u64, 110), connection.deadlines[slot]);
                if (connection.owner.engine.pending_response_end != null) {
                    try connection.owner.engine.consumeOutput(bytes.len - 1);
                    break;
                }
                try connection.owner.engine.consumeOutput(bytes.len);
            }
            connection.expire(109);
            try std.testing.expectEqual(@as(u64, 110), connection.deadlines[slot]);
            try std.testing.expect(connection.writing[slot]);
            if (finish_output) {
                try connection.owner.engine.consumeOutput(1);
                try std.testing.expectEqual(@as(u64, 0), connection.deadlines[slot]);
                try std.testing.expect(!connection.writing[slot]);
            }
            connection.expire(110);
            connection.expire(111);
            try std.testing.expectEqual(@as(u64, 200), connection.body_deadlines[slot]);
            try std.testing.expect(!connection.failed);
            try std.testing.expectError(if (finish_output) error.InvalidState else error.Closed, connection.owner.engine.checkDispatchable(work.id));
            if (finish_output) {
                connection.expire(199);
                try std.testing.expectError(error.InvalidState, connection.owner.engine.checkDispatchable(work.id));
                connection.expire(200);
                connection.expire(201);
                try std.testing.expectError(error.Closed, connection.owner.engine.checkDispatchable(work.id));
                try std.testing.expectEqual(@as(u64, 0), connection.body_deadlines[slot]);
            }
        }
    }
}

test "deferred expiry responses own bytes through cleanup and release on every terminal path" {
    const End = enum { expire, finish_first, io_timeout, reset, disconnect, normal };
    for (std.enums.values(End)) |ending| {
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
        try connection.owner.engine.receive("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
            "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
            "\x00\x00\x0e\x01\x05\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost");
        const work = connection.streams.nextMetadata().?.execute;
        // Nearest below/at/above the configured response-body bound.
        connection.owner.engine.limits.response_bytes = 4;
        for ([_]usize{ 3, 4, 5 }) |length| {
            const attempt = @import("deferred_response.zig").Response.init(connection.budget.allocator(), connection.owner.engine, work.id, 200, &.{}, "12345"[0..length], &.{});
            if (length > 4) {
                try std.testing.expectError(error.LimitExceeded, attempt);
            } else {
                var accepted = try attempt;
                accepted.deinit();
            }
        }
        connection.owner.engine.limits.response_bytes = 1024;
        const before = connection.budget.used;
        connection.budget.limit = before;
        try std.testing.expectError(error.OutOfMemory, @import("deferred_response.zig").Response.init(connection.budget.allocator(), connection.owner.engine, work.id, 200, &.{}, "body", &.{}));
        try std.testing.expectEqual(before, connection.budget.used);
        connection.budget.limit = 16 * 1024 * 1024;
        var body = "expired".*;
        var value = "done".*;
        const response = try @import("deferred_response.zig").Response.init(connection.budget.allocator(), connection.owner.engine, work.id, 504, &.{.{ .name = "x-initial", .value = &value }}, &body, &.{.{ .name = "x-final", .value = &value }});
        connection.streams.entries[work.ticket.slot].expiry_response = response;
        @memset(&body, 'x');
        @memset(&value, 'x');
        try std.testing.expectEqualStrings("expired", response.body);
        try std.testing.expectEqualStrings("done", response.headers[0].value);
        try std.testing.expectEqualStrings("done", response.trailers[0].value);
        try std.testing.expect(connection.streams.leases.limitExecution(work.ticket, 10, 10));
        switch (ending) {
            End.expire, End.finish_first, End.io_timeout => {
                connection.expire(work.headers_at + 9);
                try std.testing.expect(connection.streams.nextMetadata() == null);
                connection.expire(work.headers_at + 10);
                if (ending == End.finish_first) try std.testing.expect(connection.streams.finish(work.ticket));
                const cancel = connection.streams.nextMetadata().?.cancel;
                if (ending == End.io_timeout) try connection.owner.cancel(cancel);
                try connection.completeExpired(cancel);
                try std.testing.expectEqual(ending != End.io_timeout, connection.writing[work.ticket.slot]);
                if (ending != End.io_timeout) try std.testing.expect(connection.deadlines[work.ticket.slot] > connection.now);
                connection.expire(work.headers_at + 11);
                try std.testing.expect(connection.streams.nextMetadata() == null);
                if (ending != End.finish_first) try std.testing.expect(connection.streams.finish(work.ticket));
            },
            End.reset => {
                connection.streams.close(work.id);
                try std.testing.expect(connection.streams.finish(work.ticket));
            },
            End.disconnect => {
                connection.disconnect();
                try std.testing.expect(connection.streams.finish(work.ticket));
            },
            End.normal => {
                try connection.owner.respond(work.id, 200, &.{}, "ok");
                try std.testing.expect(connection.streams.leases.commitResponse(work.ticket));
                try std.testing.expect(connection.streams.finish(work.ticket));
            },
        }
        try std.testing.expectEqual(@as(usize, 0), connection.budget.used);
        if (!connection.closed) {
            while (true) {
                const bytes = try connection.owner.engine.output();
                if (bytes.len == 0) break;
                try connection.owner.engine.consumeOutput(bytes.len);
            }
        }
    }
}

test "output readiness and execution lookup cannot revive a reused lease" {
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
    defer net.closeSocket(pair[1]);
    try net.setListenerNonBlocking(pair[0]);
    var readiness = try poller.Poller.init();
    defer readiness.deinit();
    const connection = try Connection.create(pair[0], &readiness, 17, .{});
    defer {
        connection.executions = @splat(.{});
        connection.disconnect();
        connection.destroy();
    }
    try connection.owner.engine.receive("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
        "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
        "\x00\x00\x0e\x01\x05\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost");
    const first = connection.streams.nextMetadata().?.execute;
    connection.executions[first.ticket.slot] = .{ .ticket = first.ticket };
    try connection.owner.engine.beginStreamingResponse(first.id, 200, &.{});
    try std.testing.expect(!connection.outputReady(first.ticket));
    while (true) {
        const bytes = try connection.owner.engine.output();
        if (bytes.len == 0) break;
        try connection.owner.engine.consumeOutput(bytes.len);
    }
    // The same predicate is checked before parking and after output progress.
    try std.testing.expect(connection.outputReady(first.ticket));
    try std.testing.expect(try connection.owner.engine.writeStreamingResponse(first.id, "chunk"));
    try std.testing.expect(!connection.outputReady(first.ticket));
    try connection.selectCompletion(first.ticket, &.{.{ .name = "x-result", .value = "normal" }});
    try connection.owner.engine.receive("\x00\x00\x04\x03\x00\x00\x00\x00\x01\x00\x00\x00\x00");
    connection.advanceTerminals();
    try std.testing.expect(!connection.failed);
    try std.testing.expect(connection.terminals[first.ticket.slot].fields == null);
    try std.testing.expect(!connection.executions[first.ticket.slot].response_complete);
    try std.testing.expect(connection.outputReady(first.ticket));
    try std.testing.expect(connection.streams.finish(first.ticket));
    connection.executions[first.ticket.slot] = .{};
    try connection.owner.engine.receive("\x00\x00\x0e\x01\x05\x00\x00\x00\x03\x83\x86\x84\x01\x09localhost");
    const second = connection.streams.nextMetadata().?.execute;
    defer _ = connection.streams.finish(second.ticket);
    try std.testing.expectEqual(first.ticket.slot, second.ticket.slot);
    try std.testing.expect(first.ticket.sequence != second.ticket.sequence);
    connection.executions[second.ticket.slot] = .{ .ticket = second.ticket };
    try std.testing.expect(connection.execution(first.ticket) == null);
    var stale_connection = second.ticket;
    stale_connection.connection += 1;
    try std.testing.expect(connection.execution(stale_connection) == null);
    try std.testing.expect(connection.execution(second.ticket) != null);
    try connection.owner.engine.beginStreamingResponse(second.id, 200, &.{});
    try std.testing.expect(!connection.outputReady(second.ticket));
}

test "expiry resets open writers but preserves finite and already-finishing responses" {
    const Form = enum { finite, writing, finishing };
    for (std.enums.values(Form)) |form| {
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
        try connection.owner.engine.receive("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
            "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
            "\x00\x00\x0e\x01\x05\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost");
        const work = connection.streams.nextMetadata().?.execute;
        defer _ = connection.streams.finish(work.ticket);
        connection.streams.entries[work.ticket.slot].expiry_response = try @import("deferred_response.zig").Response.init(connection.budget.allocator(), connection.owner.engine, work.id, 504, &.{}, "expired", &.{});
        try std.testing.expect(connection.streams.leases.limitExecution(work.ticket, 10, 10));
        if (form == Form.finite) {
            try connection.owner.engine.respond(work.id, 200, &.{}, "finite");
        } else {
            try connection.owner.engine.beginStreamingResponse(work.id, 200, &.{});
            if (form == Form.finishing) {
                while (true) {
                    const bytes = try connection.owner.engine.output();
                    if (bytes.len == 0) break;
                    try connection.owner.engine.consumeOutput(bytes.len);
                }
                try connection.owner.engine.finishResponse(work.id, &.{});
            }
        }
        connection.expire(work.headers_at + 10);
        const id = connection.streams.nextMetadata().?.cancel;
        try connection.completeExpired(id);
        try std.testing.expect(connection.streams.entries[work.ticket.slot].expiry_response == null);
        try std.testing.expectError(if (form == Form.writing) error.Closed else error.InvalidState, connection.owner.engine.checkDispatchable(work.id));
    }
}

test "terminal selection arbitrates expiry and waits for actual output consumption" {
    const Winner = enum { normal, expiry };
    for (std.enums.values(Winner)) |winner| {
        var pair: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
        defer net.closeSocket(pair[1]);
        try net.setListenerNonBlocking(pair[0]);
        var readiness = try poller.Poller.init();
        defer readiness.deinit();
        const connection = try Connection.create(pair[0], &readiness, 1, .{});
        defer {
            connection.executions = @splat(.{});
            connection.disconnect();
            connection.destroy();
        }
        try connection.owner.engine.receive("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
            "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
            "\x00\x00\x0e\x01\x05\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost");
        const work = connection.streams.nextMetadata().?.execute;
        defer _ = connection.streams.finish(work.ticket);
        connection.executions[work.ticket.slot] = .{ .ticket = work.ticket };
        try connection.registerExpiryTrailers(work.ticket, 10, &.{.{ .name = "X-Result", .value = "expired" }});
        const limit = connection.budget.limit;
        connection.budget.limit = connection.budget.used;
        try std.testing.expectError(error.OutOfMemory, connection.registerExpiryTrailers(work.ticket, 0, &.{.{ .name = "x-result", .value = "replacement" }}));
        // Byte storage fits, but the descriptor allocation does not. Both
        // allocation-failure positions must preserve the previous snapshot.
        const baseline = connection.budget.used;
        connection.budget.limit = baseline + "x-result".len + "replacement".len;
        try std.testing.expectError(error.OutOfMemory, connection.registerExpiryTrailers(work.ticket, 0, &.{.{ .name = "x-result", .value = "replacement" }}));
        try std.testing.expectEqual(baseline, connection.budget.used);
        connection.budget.limit = limit;
        try std.testing.expectEqualStrings("expired", connection.terminals[work.ticket.slot].fields.?.fields[0].value);
        // The field-count bound accepts its nearest values and rejects excess.
        var many: [65]engine.Header = @splat(.{ .name = "x", .value = "v" });
        for ([_]usize{ 63, 64, 65 }) |count| {
            if (count <= 64) {
                var fields = try terminal.Fields.init(connection.budget.allocator(), connection.owner.engine, many[0..count]);
                fields.deinit();
            } else try std.testing.expectError(error.LimitExceeded, terminal.Fields.init(connection.budget.allocator(), connection.owner.engine, many[0..count]));
        }
        const maximum_value = connection.owner.engine.limits.header_bytes - 33;
        const boundary_value = try std.testing.allocator.alloc(u8, maximum_value + 1);
        defer std.testing.allocator.free(boundary_value);
        @memset(boundary_value, 'v');
        for ([_]usize{ maximum_value - 1, maximum_value, maximum_value + 1 }) |size| {
            const source = [_]engine.Header{.{ .name = "x", .value = boundary_value[0..size] }};
            if (size <= maximum_value) {
                var fields = try terminal.Fields.init(connection.budget.allocator(), connection.owner.engine, &source);
                fields.deinit();
            } else try std.testing.expectError(error.LimitExceeded, terminal.Fields.init(connection.budget.allocator(), connection.owner.engine, &source));
        }
        try std.testing.expectError(error.InvalidHeaders, connection.registerExpiryTrailers(work.ticket, 0, &.{.{ .name = "Content-Length", .value = "0" }}));
        try connection.owner.engine.beginStreamingResponse(work.id, 200, &.{});
        while (true) {
            const bytes = try connection.owner.engine.output();
            if (bytes.len == 0) break;
            try connection.owner.engine.consumeOutput(bytes.len);
        }
        try std.testing.expect(try connection.owner.engine.writeStreamingResponse(work.id, "accepted DATA"));
        // Nearest times around expiry; invalid registration must not tighten it.
        connection.expire(work.headers_at + 9);
        try std.testing.expect(!connection.streams.leases.executionExpired(work.ticket));
        if (winner == Winner.normal) {
            try std.testing.expectError(error.InvalidHeaders, connection.selectCompletion(work.ticket, &.{.{ .name = "connection", .value = "close" }}));
            try connection.selectCompletion(work.ticket, &.{.{ .name = "x-result", .value = "normal" }});
            try std.testing.expectError(error.InvalidState, connection.selectCompletion(work.ticket, &.{}));
        }
        connection.expire(work.headers_at + 10);
        connection.expire(work.headers_at + 11);
        if (winner == Winner.expiry) {
            try std.testing.expect(connection.streams.leases.executionExpired(work.ticket));
            const expired = connection.streams.nextMetadata().?.cancel;
            try connection.completeExpired(expired);
            try std.testing.expectError(error.Closed, connection.selectCompletion(work.ticket, &.{}));
        } else try std.testing.expect(!connection.streams.leases.executionExpired(work.ticket));
        connection.advanceTerminals();
        try std.testing.expect(!connection.terminals[work.ticket.slot].submitted);
        var observed_terminal = false;
        for (0..32) |_| {
            connection.advanceTerminals();
            const bytes = try connection.owner.engine.output();
            if (bytes.len == 0) break;
            if (connection.owner.engine.pending_response_end != null) {
                observed_terminal = true;
                try std.testing.expect(!connection.executions[work.ticket.slot].response_complete);
                if (bytes.len > 1) {
                    try connection.owner.engine.consumeOutput(bytes.len - 1);
                    try std.testing.expect(!connection.executions[work.ticket.slot].response_complete);
                }
                try connection.owner.engine.consumeOutput(connection.owner.engine.pending.len);
                try std.testing.expectEqual(winner == Winner.normal, connection.executions[work.ticket.slot].response_complete);
            } else try connection.owner.engine.consumeOutput(bytes.len);
        }
        try std.testing.expect(observed_terminal);
        try std.testing.expect(connection.terminals[work.ticket.slot].fields == null);
    }
}
