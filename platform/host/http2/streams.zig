//! Serialized finite-input admission and execution leases for one connection.
const std = @import("std");
const engine = @import("engine.zig");
const input = @import("input.zig");
const requests = @import("requests.zig");
pub const Ticket = requests.Ticket;
pub const Error = error{ Full, Exhausted, InvalidState };
const Entry = struct {
    ticket: ?Ticket = null,
    buffer: ?input.Input = null,
    cancel_pending: bool = false,
};
pub const Work = union(enum) {
    cancel: engine.StreamId,
    execute: struct { ticket: Ticket, id: engine.StreamId, headers_at: u64, buffer: *input.Input },
};

pub const Streams = struct {
    leases: requests.Requests,
    budget: *input.Budget,
    limits: input.Limits,
    disconnected: bool = false,
    entries: [16]Entry = @splat(.{}),

    /// The budget and this table must remain at stable addresses until all
    /// claimed executions finish. All operations require the connection owner.
    pub fn init(connection: u64, budget: *input.Budget, limits: input.Limits) Streams {
        return .{ .leases = .{ .connection = connection }, .budget = budget, .limits = limits };
    }

    pub fn header(self: *Streams, id: engine.StreamId, field: engine.Header) Error!void {
        if (self.disconnected) return error.InvalidState;
        const ticket = self.leases.find(id) orelse try self.leases.open(id);
        const entry = &self.entries[ticket.slot];
        if (entry.ticket == null) entry.* = .{ .ticket = ticket, .buffer = input.Input.init(self.budget, self.limits) };
        const buffer = if (entry.buffer) |*buffer| buffer else return error.InvalidState;
        if (buffer.phase == input.Phase.rejected) return;
        buffer.header(field) catch |err| switch (err) {
            error.InvalidState => return error.InvalidState,
            else => self.reject(entry),
        };
    }

    pub fn headersComplete(self: *Streams, id: engine.StreamId, now: u64) Error!void {
        const entry = try self.lookup(id);
        const buffer = if (entry.buffer) |*buffer| buffer else return error.InvalidState;
        if (buffer.phase == input.Phase.rejected) return;
        buffer.headersComplete() catch return error.InvalidState;
        if (!self.leases.ready(entry.ticket.?, now)) return error.InvalidState;
    }

    pub fn data(self: *Streams, id: engine.StreamId, bytes: []const u8) Error!void {
        const entry = try self.lookup(id);
        const buffer = if (entry.buffer) |*buffer| buffer else return error.InvalidState;
        if (buffer.phase == input.Phase.rejected) return;
        buffer.data(bytes) catch |err| switch (err) {
            error.InvalidState => return error.InvalidState,
            else => self.reject(entry),
        };
    }

    pub fn end(self: *Streams, id: engine.StreamId) Error!void {
        const entry = try self.lookup(id);
        const buffer = if (entry.buffer) |*buffer| buffer else return error.InvalidState;
        if (buffer.phase == input.Phase.rejected) return;
        buffer.end() catch return error.InvalidState;
    }

    fn lookup(self: *Streams, id: engine.StreamId) Error!*Entry {
        const ticket = self.leases.find(id) orelse return error.InvalidState;
        return &self.entries[ticket.slot];
    }

    fn reject(_: *Streams, entry_value: *Entry) void {
        entry_value.buffer.?.deinit();
        entry_value.cancel_pending = true;
    }

    /// Called only between engine calls. Returned input is borrowed until close,
    /// disconnect, or finish; consume it synchronously before queueing owned Roc
    /// values. Every execute result must be finished after request cleanup, even
    /// if the protocol closes meanwhile. Cancellation work is emitted once.
    pub fn next(self: *Streams) ?Work {
        for (&self.entries) |*entry_value| {
            const ticket = entry_value.ticket orelse continue;
            const id = self.leases.stream(ticket) orelse continue;
            if (entry_value.cancel_pending) {
                entry_value.cancel_pending = false;
                return .{ .cancel = id };
            }
            const buffer = if (entry_value.buffer) |*buffer| buffer else continue;
            if (buffer.body() == null) continue;
            const anchor = self.leases.claim(ticket) orelse continue;
            return .{ .execute = .{ .ticket = ticket, .id = id, .headers_at = anchor, .buffer = buffer } };
        }
        return null;
    }

    /// Borrow input only for a still-open claimed execution. The owner must
    /// consume it before another engine call can close or reuse the slot.
    pub fn runningInput(self: *Streams, ticket: Ticket) ?*input.Input {
        _ = self.leases.runningStream(ticket) orelse return null;
        return if (self.entries[ticket.slot].buffer) |*buffer| buffer else null;
    }

    pub fn finish(self: *Streams, ticket: Ticket) bool {
        if (!self.leases.finish(ticket)) return false;
        const entry_value = &self.entries[ticket.slot];
        if (entry_value.buffer) |*buffer| buffer.deinit();
        entry_value.buffer = null;
        if (self.leases.stream(ticket) == null) entry_value.* = .{};
        return true;
    }

    pub fn close(self: *Streams, id: engine.StreamId) void {
        const ticket = self.leases.find(id) orelse return;
        const entry_value = &self.entries[ticket.slot];
        if (entry_value.buffer) |*buffer| buffer.deinit();
        entry_value.buffer = null;
        entry_value.cancel_pending = false;
        self.leases.close(id);
        if (self.leases.stream(ticket) == null) entry_value.* = .{};
    }

    /// Invalidate queued work and release input, retaining claimed lease slots.
    /// This is not effect cancellation; executors must still clean up and finish.
    pub fn disconnect(self: *Streams) void {
        self.disconnected = true;
        for (&self.entries) |*entry_value| {
            const ticket = entry_value.ticket orelse continue;
            const id = self.leases.stream(ticket) orelse continue;
            self.close(id);
        }
    }
};

fn testId(value: i32) engine.StreamId {
    return @fromBackingInt(@intCast(value));
}

fn testReady(table: *Streams, id: engine.StreamId) !void {
    try table.header(id, .{ .name = ":method", .value = "POST" });
    try table.headersComplete(id, 42);
    try table.data(id, "body");
    try table.end(id);
}

test "dispatch waits for EOF and retains initial timestamp across body waits" {
    var budget = input.Budget{ .backing = std.testing.allocator, .limit = 8192 };
    var table = Streams.init(1, &budget, .{ .header_bytes = 1024, .body_bytes = 16 });
    defer table.disconnect();
    const id = testId(1);
    try table.header(id, .{ .name = ":method", .value = "POST" });
    try std.testing.expect(table.next() == null);
    try table.headersComplete(id, 7);
    try table.data(id, "body");
    try std.testing.expect(table.next() == null);
    try table.header(id, .{ .name = "trailer", .value = "ignored" });
    try table.end(id);
    const work = table.next().?.execute;
    try std.testing.expectEqual(@as(u64, 7), work.headers_at);
    try std.testing.expectEqualStrings("body", work.buffer.body().?);
    try std.testing.expectEqual(@as(usize, 1), work.buffer.headers().?.len);
    try std.testing.expect(table.next() == null);
    try std.testing.expect(table.finish(work.ticket));
    try std.testing.expect(!table.finish(work.ticket));
    try std.testing.expect(table.next() == null);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    table.close(id);
}

test "reset discards queued input and pins claimed slots until cleanup" {
    var budget = input.Budget{ .backing = std.testing.allocator, .limit = 8192 };
    var table = Streams.init(3, &budget, .{ .header_bytes = 1024, .body_bytes = 16 });
    defer table.disconnect();
    try testReady(&table, testId(1));
    const queued = table.leases.find(testId(1)).?;
    table.close(testId(1));
    try std.testing.expect(table.next() == null);
    try testReady(&table, testId(3));
    const running = table.next().?.execute;
    try std.testing.expectEqual(queued.slot, running.ticket.slot);
    try std.testing.expect(!table.finish(queued));
    table.close(testId(3));
    try testReady(&table, testId(5));
    const peer = table.next().?.execute;
    try std.testing.expect(peer.ticket.slot != running.ticket.slot);
    try std.testing.expectEqualStrings("body", peer.buffer.body().?);
    try std.testing.expect(table.finish(running.ticket));
    table.disconnect();
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    try std.testing.expect(table.next() == null);
    try std.testing.expect(table.finish(peer.ticket));
    try std.testing.expect(!table.finish(running.ticket));
}

test "input failures queue one cancellation and leave peer work intact" {
    // Nearest below/at/above the finite body limit.
    for ([_]usize{ 3, 4, 5 }) |size| {
        var budget = input.Budget{ .backing = std.testing.allocator, .limit = 8192 };
        var table = Streams.init(4, &budget, .{ .header_bytes = 1024, .body_bytes = 4 });
        defer table.disconnect();
        try table.header(testId(1), .{ .name = ":method", .value = "POST" });
        try table.headersComplete(testId(1), 0);
        try table.data(testId(1), "12345"[0..size]);
        try table.end(testId(1));
        if (size > 4) {
            try std.testing.expectEqual(testId(1), table.next().?.cancel);
            try table.data(testId(1), "discard");
            try std.testing.expect(table.next() == null);
        } else {
            const work = table.next().?.execute;
            try std.testing.expectEqual(size, work.buffer.body().?.len);
            try std.testing.expect(table.finish(work.ticket));
        }
        try testReady(&table, testId(3));
        const peer = table.next().?.execute;
        try std.testing.expectEqual(testId(3), peer.id);
        try std.testing.expect(table.finish(peer.ticket));
        table.close(testId(1));
        try std.testing.expectEqual(@as(usize, 0), budget.used);
    }
}

test "closed running leases count toward capacity until the executor finishes" {
    // Nearest valid capacities and first refused stream.
    for ([_]usize{ 15, 16, 17 }) |count| {
        var budget = input.Budget{ .backing = std.testing.allocator, .limit = 65536 };
        var table = Streams.init(5, &budget, .{ .header_bytes = 1024, .body_bytes = 16 });
        defer table.disconnect();
        var tickets: [16]Ticket = undefined;
        for (0..@min(count, 16)) |index| {
            const id = testId(@intCast(index * 2 + 1));
            try testReady(&table, id);
            tickets[index] = table.next().?.execute.ticket;
            table.close(id);
        }
        if (count == 17) try std.testing.expectError(error.Full, table.header(testId(33), .{ .name = "x", .value = "y" }));
        try std.testing.expectEqual(@as(usize, 0), budget.used);
        for (tickets[0..@min(count, 16)]) |ticket| try std.testing.expect(table.finish(ticket));
        try testReady(&table, testId(35));
        const reused = table.next().?.execute;
        for (tickets[0..@min(count, 16)]) |ticket| try std.testing.expect(!table.finish(ticket));
        var wrong = reused.ticket;
        wrong.connection += 1;
        try std.testing.expect(!table.finish(wrong));
        try std.testing.expect(table.finish(reused.ticket));
    }
}

test "allocation failure frees only rejected input and disconnect discards cancellations" {
    var budget = input.Budget{ .backing = std.testing.allocator, .limit = 8192 };
    var table = Streams.init(6, &budget, .{ .header_bytes = 1024, .body_bytes = 16 });
    defer table.disconnect();
    try testReady(&table, testId(1));
    const peer_bytes = budget.used;
    budget.limit = budget.used;
    try table.header(testId(3), .{ .name = "x", .value = "y" });
    try std.testing.expectEqual(peer_bytes, budget.used);
    const peer = table.next().?.execute;
    try std.testing.expectEqualStrings("body", peer.buffer.body().?);
    table.disconnect();
    try std.testing.expect(table.next() == null);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    try std.testing.expect(table.finish(peer.ticket));
    table.disconnect();
}

test "invalid callback order and sequence exhaustion cannot create execution" {
    var budget = input.Budget{ .backing = std.testing.allocator, .limit = 8192 };
    var table = Streams.init(7, &budget, .{ .header_bytes = 1024, .body_bytes = 16 });
    defer table.disconnect();
    try std.testing.expectError(error.InvalidState, table.end(testId(1)));
    try table.header(testId(1), .{ .name = "x", .value = "y" });
    const used = budget.used;
    try std.testing.expectError(error.InvalidState, table.data(testId(1), "early"));
    try std.testing.expectError(error.InvalidState, table.end(testId(1)));
    try std.testing.expectEqual(used, budget.used);
    try table.headersComplete(testId(1), 5);
    try std.testing.expectError(error.InvalidState, table.headersComplete(testId(1), 99));
    try table.end(testId(1));
    try std.testing.expectError(error.InvalidState, table.end(testId(1)));
    const work = table.next().?.execute;
    try std.testing.expectEqual(@as(u64, 5), work.headers_at);
    try std.testing.expect(table.finish(work.ticket));
    table.close(testId(1));
    table.leases.sequence = std.math.maxInt(u64);
    try std.testing.expectError(error.Exhausted, table.header(testId(3), .{ .name = "x", .value = "y" }));
    try std.testing.expect(table.next() == null);
    table.disconnect();
    try std.testing.expectError(error.InvalidState, table.header(testId(5), .{ .name = "x", .value = "y" }));
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

test "bounded callback and completion sequences release all input and leases" {
    // Exercise out-of-order callbacks and delayed completions in addition to
    // valid engine traces. Fixed seeds make failures reproducible.
    for (0..32) |seed| {
        var budget = input.Budget{ .backing = std.testing.allocator, .limit = 2048 };
        var table = Streams.init(seed, &budget, .{ .header_bytes = 64, .body_bytes = 4 });
        defer table.disconnect();
        var tickets: [16]?Ticket = @splat(null);
        var random: u64 = seed + 1;
        for (0..512) |_| {
            random = random *% 6364136223846793005 +% 1442695040888963407;
            const id = testId(@intCast(((random >> 32) % 20) * 2 + 1));
            switch ((random >> 48) % 8) {
                0 => table.header(id, .{ .name = "x", .value = "y" }) catch {},
                1 => table.headersComplete(id, random) catch {},
                2 => table.data(id, "body") catch {},
                3 => table.end(id) catch {},
                4 => table.close(id),
                5, 6 => if (table.next()) |work| {
                    switch (work) {
                        Work.cancel => |cancelled| table.close(cancelled),
                        Work.execute => |execution| tickets[execution.ticket.slot] = execution.ticket,
                    }
                },
                7 => if (tickets[(random >> 16) % tickets.len]) |ticket| {
                    _ = table.finish(ticket);
                },
                else => unreachable,
            }
            try std.testing.expect(budget.used <= budget.limit);
        }
        table.disconnect();
        for (tickets) |ticket| if (ticket) |value| {
            _ = table.finish(value);
        };
        try std.testing.expectEqual(@as(usize, 0), budget.used);
        try std.testing.expect(table.next() == null);
        for (0..20) |index| try std.testing.expect(table.leases.find(testId(@intCast(index * 2 + 1))) == null);
    }
}
