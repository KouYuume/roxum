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
    waiter: ?struct { target: *fiber.Fiber, serial: u64 } = null,
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
    writing: [16]bool = @splat(false),
    terminal_write_deadline: u64 = 0,
    header_deadline: u64 = 0,
    head_timeout: u64 = 0,
    body_timeout: u64 = 0,
    write_timeout: u64 = 0,
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
            if (self.streams.leases.runningStream(ticket) != null) continue;
            if (execution_value.waiter) |waiter| fiber_wait.wakeStopped(waiter.target, waiter.serial, fiber.Stop.client_gone);
        }
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
        if ((self.header_deadline != 0 and now >= self.header_deadline) or
            (self.terminal_write_deadline != 0 and now >= self.terminal_write_deadline))
        {
            self.failed = true;
            self.owner.runnable = true;
        }
        for (&self.deadlines, 0..) |*deadline, slot| {
            if (deadline.* == 0 or now < deadline.*) continue;
            deadline.* = 0;
            if (self.owner.watching_writable) self.failed = true;
            const ticket = self.streams.entries[slot].ticket orelse continue;
            if (self.streams.leases.stream(ticket)) |id| self.owner.cancel(id) catch {};
        }
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
        if (self.streams.leases.find(id)) |ticket| {
            if (self.deadlines[ticket.slot] == 0) self.deadlines[ticket.slot] = self.now +| self.head_timeout;
        }
    }
    fn headersComplete(ptr: *anyopaque, id: engine.StreamId) void {
        const self = from(ptr);
        self.streams.headersComplete(id, self.now) catch {
            self.failed = true;
            return;
        };
        if (self.streams.leases.find(id)) |ticket| self.deadlines[ticket.slot] = self.now +| self.body_timeout;
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
    }
    fn streamClosed(ptr: *anyopaque, id: engine.StreamId) void {
        const self = from(ptr);
        if (self.streams.leases.find(id)) |ticket| {
            const deadline = self.deadlines[ticket.slot];
            if (self.writing[ticket.slot] and self.owner.engine.close_error == 0 and deadline != 0) {
                if (self.terminal_write_deadline == 0 or deadline < self.terminal_write_deadline) self.terminal_write_deadline = deadline;
            }
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
