//! Serialized request leases. Protocol closure and execution completion are
//! independent; a running lease pins its slot until the executor releases it.
const std = @import("std");
const StreamId = @import("engine.zig").StreamId;

pub const Ticket = struct { connection: u64, sequence: u64, slot: usize };
const Phase = enum { collecting, queued, running, finished };
const Slot = struct {
    id: ?StreamId = null,
    sequence: u64 = 0,
    phase: Phase = Phase.collecting,
    closed: bool = false,
    headers_at: u64 = 0,
    execution_deadline: ?u64 = null,
    expired: bool = false,
    response_committed: bool = false,
};
pub const Requests = struct {
    /// Must be unique across owners and stale queued work.
    connection: u64,
    sequence: u64 = 0,
    slots: [16]Slot = @splat(.{}),

    pub fn open(self: *Requests, id: StreamId) error{ Full, Exhausted }!Ticket {
        if (self.find(id)) |ticket| return ticket;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.id != null) continue;
            const sequence = std.math.add(u64, self.sequence, 1) catch return error.Exhausted;
            self.sequence = sequence;
            slot.* = .{ .id = id, .sequence = sequence };
            return .{ .connection = self.connection, .sequence = sequence, .slot = index };
        }
        return error.Full;
    }

    pub fn find(self: *const Requests, id: StreamId) ?Ticket {
        for (self.slots, 0..) |slot, index| {
            if (slot.id == id) return .{ .connection = self.connection, .sequence = slot.sequence, .slot = index };
        }
        return null;
    }

    fn get(self: *Requests, ticket: Ticket) ?*Slot {
        if (ticket.connection != self.connection or ticket.slot >= self.slots.len) return null;
        const slot = &self.slots[ticket.slot];
        if (slot.id == null or slot.sequence != ticket.sequence) return null;
        return slot;
    }

    /// Resolve a generation-checked lease, including a closed running lease.
    pub fn stream(self: *Requests, ticket: Ticket) ?StreamId {
        const slot = self.get(ticket) orelse return null;
        return slot.id;
    }

    /// A response may be submitted only while the claimed execution is open.
    pub fn runningStream(self: *Requests, ticket: Ticket) ?StreamId {
        const slot = self.get(ticket) orelse return null;
        if (slot.closed or slot.expired or slot.phase != Phase.running) return null;
        return slot.id;
    }

    /// Records the initial metadata anchor exactly once, before body waits.
    pub fn ready(self: *Requests, ticket: Ticket, now: u64) bool {
        const slot = self.get(ticket) orelse return false;
        if (slot.closed or slot.phase != Phase.collecting) return false;
        slot.headers_at = now;
        slot.phase = Phase.queued;
        return true;
    }

    /// Nanoseconds since initial metadata completion; queue and body time count.
    pub fn headersElapsed(self: *Requests, ticket: Ticket, now: u64) ?u64 {
        const slot = self.get(ticket) orelse return null;
        if (slot.closed or slot.phase == Phase.collecting) return null;
        return now -| slot.headers_at;
    }

    /// Install or tighten a duration from the immutable metadata anchor. Zero
    /// means immediate expiry; neither repeated calls nor queueing extend it.
    pub fn limitExecution(self: *Requests, ticket: Ticket, duration_ns: u64, maximum_ns: u64) bool {
        const slot = self.get(ticket) orelse return false;
        if (slot.closed or slot.expired or slot.response_committed) return false;
        if (slot.phase != Phase.queued and slot.phase != Phase.running) return false;
        const deadline = slot.headers_at +| @min(duration_ns, maximum_ns);
        slot.execution_deadline = if (slot.execution_deadline) |previous| @min(previous, deadline) else deadline;
        return true;
    }

    /// The serialized owner decides expiry before dispatch or response submission.
    /// An expired running lease remains pinned until execution cleanup finishes.
    pub fn expireExecution(self: *Requests, ticket: Ticket, now: u64) bool {
        const slot = self.get(ticket) orelse return false;
        if (slot.closed or slot.expired or slot.response_committed) return false;
        const deadline = slot.execution_deadline orelse return false;
        if (now < deadline) return false;
        slot.expired = true;
        return true;
    }

    pub fn executionExpired(self: *Requests, ticket: Ticket) bool {
        const slot = self.get(ticket) orelse return false;
        return slot.expired;
    }

    /// Called after successful finite response submission under the same lock
    /// as the expiry check. Socket delivery remains subject to write timeouts.
    pub fn commitResponse(self: *Requests, ticket: Ticket) bool {
        const slot = self.get(ticket) orelse return false;
        if (slot.closed or slot.expired or slot.response_committed or slot.phase != Phase.running) return false;
        slot.response_committed = true;
        return true;
    }

    pub fn claim(self: *Requests, ticket: Ticket) ?u64 {
        const slot = self.get(ticket) orelse return null;
        if (slot.closed or slot.expired or slot.phase != Phase.queued) return null;
        slot.phase = Phase.running;
        return slot.headers_at;
    }

    pub fn finish(self: *Requests, ticket: Ticket) bool {
        const slot = self.get(ticket) orelse return false;
        if (slot.phase != Phase.running) return false;
        slot.phase = Phase.finished;
        if (slot.closed) slot.* = .{};
        return true;
    }

    pub fn close(self: *Requests, id: StreamId) void {
        const ticket = self.find(id) orelse return;
        const slot = &self.slots[ticket.slot];
        slot.closed = true;
        if (slot.phase != Phase.running) slot.* = .{};
    }

    /// The executor must still finish every claimed lease after cancellation.
    pub fn disconnect(self: *Requests) void {
        for (&self.slots) |*slot| {
            if (slot.id == null) continue;
            slot.closed = true;
            if (slot.phase != Phase.running) slot.* = .{};
        }
    }
};

test "closure pins running leases and invalidates queued work across reuse" {
    var requests = Requests{ .connection = 3 };
    const first = try requests.open(@fromBackingInt(@intCast(1)));
    try std.testing.expect(requests.ready(first, 42));
    try std.testing.expect(!requests.ready(first, 99));
    try std.testing.expectEqual(@as(?u64, 42), requests.claim(first));
    try std.testing.expect(requests.claim(first) == null);
    requests.close(@fromBackingInt(@intCast(1)));
    const second = try requests.open(@fromBackingInt(@intCast(3)));
    try std.testing.expect(first.slot != second.slot);
    try std.testing.expect(requests.finish(first));
    try std.testing.expect(!requests.finish(first));
    const reused = try requests.open(@fromBackingInt(@intCast(5)));
    try std.testing.expectEqual(first.slot, reused.slot);
    try std.testing.expect(!requests.ready(first, 0));
    requests.disconnect();
    try std.testing.expect(!requests.ready(second, 0));
    try std.testing.expect(!requests.ready(reused, 0));
}

test "capacity exhaustion and connection identity cannot alias live leases" {
    var requests = Requests{ .connection = 1 };
    var tickets: [16]Ticket = undefined;
    for (&tickets, 0..) |*ticket, index| ticket.* = try requests.open(@fromBackingInt(@intCast(@as(i32, @intCast(index * 2 + 1)))));
    try std.testing.expectError(error.Full, requests.open(@fromBackingInt(@intCast(33))));
    var wrong = tickets[0];
    wrong.connection = 2;
    try std.testing.expect(!requests.ready(wrong, 0));
    wrong = tickets[0];
    wrong.slot = 16;
    try std.testing.expect(!requests.ready(wrong, 0));
    try std.testing.expect(requests.ready(tickets[0], 0));
    try std.testing.expectEqual(@as(?u64, 0), requests.claim(tickets[0]));
    requests.disconnect();
    try std.testing.expect(requests.finish(tickets[0]));
    requests.sequence = std.math.maxInt(u64) - 2;
    const below = try requests.open(@fromBackingInt(@intCast(33)));
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, below.sequence);
    const last = try requests.open(@fromBackingInt(@intCast(35)));
    try std.testing.expectEqual(std.math.maxInt(u64), last.sequence);
    try std.testing.expectError(error.Exhausted, requests.open(@fromBackingInt(@intCast(37))));
}

test "execution may finish before protocol closure without permitting another claim" {
    var requests = Requests{ .connection = 7 };
    const ticket = try requests.open(@fromBackingInt(@intCast(1)));
    try std.testing.expect(requests.ready(ticket, 5));
    _ = requests.claim(ticket) orelse return error.TestUnexpectedResult;
    try std.testing.expect(requests.finish(ticket));
    try std.testing.expect(requests.claim(ticket) == null);
    try std.testing.expect(requests.find(@fromBackingInt(@intCast(1))) != null);
    requests.close(@fromBackingInt(@intCast(1)));
    requests.close(@fromBackingInt(@intCast(1)));
    try std.testing.expect(requests.find(@fromBackingInt(@intCast(1))) == null);
    try std.testing.expect(!requests.finish(ticket));
}

test "queued closure and disconnect reject old tickets after reuse" {
    var requests = Requests{ .connection = 9 };
    const first = try requests.open(@fromBackingInt(@intCast(1)));
    try std.testing.expectEqualDeep(first, try requests.open(@fromBackingInt(@intCast(1))));
    try std.testing.expectEqual(first.sequence, requests.sequence);
    try std.testing.expect(requests.ready(first, 10));
    requests.close(@fromBackingInt(@intCast(1)));
    try std.testing.expect(requests.claim(first) == null);
    const next = try requests.open(@fromBackingInt(@intCast(3)));
    try std.testing.expectEqual(first.slot, next.slot);
    try std.testing.expect(requests.ready(next, 20));
    try std.testing.expect(requests.claim(first) == null);
    try std.testing.expect(!requests.finish(first));
    requests.disconnect();
    try std.testing.expect(requests.claim(next) == null);
    try std.testing.expect(!requests.finish(next));
}

test "execution deadline counts metadata and queue time at the exact boundary" {
    for ([_]u64{ 109, 110, 111 }) |now| {
        for ([_]bool{ false, true }) |running| {
            var table = Requests{ .connection = 7 };
            const ticket = try table.open(@fromBackingInt(1));
            try std.testing.expect(!table.limitExecution(ticket, 10, 10));
            try std.testing.expect(table.ready(ticket, 100));
            try std.testing.expect(table.limitExecution(ticket, 100, 10));
            try std.testing.expect(table.limitExecution(ticket, 1000, 1000));
            if (running) _ = table.claim(ticket).?;
            try std.testing.expectEqual(@as(?u64, now - 100), table.headersElapsed(ticket, now));
            try std.testing.expectEqual(now >= 110, table.expireExecution(ticket, now));
            try std.testing.expect(!table.expireExecution(ticket, now));
            if (now >= 110) {
                try std.testing.expect(table.claim(ticket) == null);
                try std.testing.expect(table.runningStream(ticket) == null);
                try std.testing.expect(!table.commitResponse(ticket));
                try std.testing.expect(!table.limitExecution(ticket, 1000, 1000));
            }
            table.close(@fromBackingInt(1));
            if (running) try std.testing.expect(table.finish(ticket));
            const reused = try table.open(@fromBackingInt(3));
            try std.testing.expectEqual(ticket.slot, reused.slot);
            try std.testing.expect(!table.limitExecution(ticket, 0, 0));
            try std.testing.expect(!table.expireExecution(ticket, std.math.maxInt(u64)));
        }
    }
}

test "deadline zero overflow tightening and committed response boundaries" {
    for ([_]u64{ 0, 1, 2 }) |duration| {
        var table = Requests{ .connection = 1 };
        const ticket = try table.open(@fromBackingInt(1));
        try std.testing.expect(table.ready(ticket, std.math.maxInt(u64) - 1));
        try std.testing.expect(table.limitExecution(ticket, duration, 10));
        try std.testing.expectEqual(duration == 0, table.expireExecution(ticket, std.math.maxInt(u64) - 1));
        if (duration != 0) try std.testing.expect(table.expireExecution(ticket, std.math.maxInt(u64)));
    }
    var table = Requests{ .connection = 2 };
    const ticket = try table.open(@fromBackingInt(1));
    try std.testing.expect(table.ready(ticket, 0));
    try std.testing.expect(table.limitExecution(ticket, 20, 30));
    try std.testing.expect(table.limitExecution(ticket, 10, 30));
    _ = table.claim(ticket).?;
    try std.testing.expect(!table.expireExecution(ticket, 9));
    try std.testing.expect(table.commitResponse(ticket));
    try std.testing.expect(!table.commitResponse(ticket));
    try std.testing.expect(!table.expireExecution(ticket, 10));
    try std.testing.expect(!table.limitExecution(ticket, 0, 0));
    try std.testing.expect(table.finish(ticket));
    try std.testing.expect(!table.expireExecution(ticket, 100));
}

test "server execution cap accepts below at and above its duration boundary" {
    const Case = struct { duration: u64, expires: u64 };
    for ([_]Case{ .{ .duration = 9, .expires = 109 }, .{ .duration = 10, .expires = 110 }, .{ .duration = 11, .expires = 110 } }) |case| {
        for ([_]u64{ 0, 1, 2 }) |offset| {
            var table = Requests{ .connection = 1 };
            const ticket = try table.open(@fromBackingInt(1));
            try std.testing.expect(table.ready(ticket, 100));
            try std.testing.expect(table.limitExecution(ticket, case.duration, 10));
            try std.testing.expectEqual(offset != 0, table.expireExecution(ticket, case.expires - 1 + offset));
        }
    }
}
