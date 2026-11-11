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

    /// Records the initial metadata anchor exactly once, before body waits.
    pub fn ready(self: *Requests, ticket: Ticket, now: u64) bool {
        const slot = self.get(ticket) orelse return false;
        if (slot.closed or slot.phase != Phase.collecting) return false;
        slot.headers_at = now;
        slot.phase = Phase.queued;
        return true;
    }

    pub fn claim(self: *Requests, ticket: Ticket) ?u64 {
        const slot = self.get(ticket) orelse return null;
        if (slot.closed or slot.phase != Phase.queued) return null;
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
