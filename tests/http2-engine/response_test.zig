const std = @import("std");
const http2 = @import("http2_engine");
const values = @import("roc_values.zig");
const bridge = http2.bridge;

const Fixture = struct {
    budget: http2.input.Budget = .{ .backing = std.testing.allocator, .limit = 8192 },
    registry: http2.streams.Streams = undefined,
    owner: http2.owner.Owner = undefined,

    fn init(self: *Fixture) !void {
        return self.initWithAllocator(std.testing.allocator);
    }

    fn initWithAllocator(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.budget.backing = allocator;
        self.registry = http2.streams.Streams.init(7, &self.budget, .{ .header_bytes = 1024, .body_bytes = 16 });
        const engine = try http2.engine.Engine.create(allocator, .{}, .{
            .context = self,
            .header = header,
            .headers_complete = headersComplete,
            .data = data,
            .end = end,
            .closed = closed,
        });
        errdefer engine.destroy();
        // Submission is byte-in/byte-out and must never touch the socket/poller.
        self.owner = .{ .engine = engine, .socket = -1, .poller = undefined, .token = 7 };
        const request = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
            "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
            "\x00\x00\x0e\x01\x05\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost";
        try engine.receive(request);
    }

    fn deinit(self: *Fixture) void {
        self.registry.disconnect();
        self.owner.engine.destroy();
        std.debug.assert(self.budget.used == 0);
    }

    fn from(ctx: *anyopaque) *Fixture {
        return @ptrCast(@alignCast(ctx));
    }
    fn header(ctx: *anyopaque, id: http2.engine.StreamId, field: http2.engine.Header) void {
        from(ctx).registry.header(id, field) catch unreachable;
    }
    fn headersComplete(ctx: *anyopaque, id: http2.engine.StreamId) void {
        from(ctx).registry.headersComplete(id, 42) catch unreachable;
    }
    fn data(ctx: *anyopaque, id: http2.engine.StreamId, bytes: []const u8) void {
        from(ctx).registry.data(id, bytes) catch unreachable;
    }
    fn end(ctx: *anyopaque, id: http2.engine.StreamId) void {
        from(ctx).registry.end(id) catch unreachable;
    }
    fn closed(ctx: *anyopaque, id: http2.engine.StreamId) void {
        from(ctx).registry.close(id);
    }
};

const body = "owned-output-must-survive-Roc-response-cleanup";
fn response(host: *bridge.RocHost) bridge.HttpResponse {
    return values.response(200, &.{.{ .name = "X-Owner", .value = "retained-until-submission" }}, body, host);
}

test "owned submission copies output before Roc cleanup and does not finish execution" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const work = fixture.registry.next().?.execute;
    defer _ = fixture.registry.finish(work.ticket);
    var environment = values.Environment{ .allocator = std.testing.allocator };
    var host = environment.rocHost();
    const input_bytes = fixture.budget.used;
    try fixture.owner.respondOwned(&fixture.registry, work.ticket, response(&host), &host, bridge.ResponseRequestSemantics.regular);
    try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
    try std.testing.expectEqual(input_bytes, fixture.budget.used);
    try std.testing.expect(fixture.registry.leases.runningStream(work.ticket) != null);
    try std.testing.expectError(error.InvalidState, fixture.owner.respondOwned(&fixture.registry, work.ticket, response(&host), &host, bridge.ResponseRequestSemantics.regular));
    try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
    var output = std.ArrayList(u8).empty;
    defer output.deinit(std.testing.allocator);
    while (true) {
        const bytes = try fixture.owner.engine.output();
        if (bytes.len == 0) break;
        try output.appendSlice(std.testing.allocator, bytes);
        try fixture.owner.engine.consumeOutput(bytes.len);
    }
    try std.testing.expect(std.mem.indexOf(u8, output.items, body) != null);
    try std.testing.expect(fixture.registry.finish(work.ticket));
    try std.testing.expectEqual(@as(usize, 0), fixture.budget.used);
}

test "owned submission consumes responses for stale closed and unclaimed executions" {
    const Case = enum { queued, finished, reset, disconnected, wrong_connection, wrong_sequence, wrong_slot, terminal, wrong_owner };
    for (std.enums.values(Case)) |case| {
        var fixture: Fixture = .{};
        try fixture.init();
        defer fixture.deinit();
        const id: http2.engine.StreamId = @fromBackingInt(@intCast(1));
        const ticket = fixture.registry.leases.find(id).?;
        if (case != Case.queued) _ = fixture.registry.next().?.execute;
        defer _ = fixture.registry.finish(ticket);
        var submitted = ticket;
        switch (case) {
            Case.queued => {},
            Case.finished => try std.testing.expect(fixture.registry.finish(ticket)),
            Case.reset => fixture.registry.close(id),
            Case.disconnected => fixture.registry.disconnect(),
            Case.wrong_connection => submitted.connection += 1,
            Case.wrong_sequence => submitted.sequence += 1,
            Case.wrong_slot => submitted.slot = 16,
            Case.terminal => fixture.owner.terminal = true,
            Case.wrong_owner => fixture.owner.token += 1,
        }
        var environment = values.Environment{ .allocator = std.testing.allocator };
        var host = environment.rocHost();
        const used = fixture.owner.engine.memory.used;
        const input_bytes = fixture.budget.used;
        try std.testing.expectError(error.Closed, fixture.owner.respondOwned(&fixture.registry, submitted, response(&host), &host, bridge.ResponseRequestSemantics.regular));
        try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
        try std.testing.expectEqual(used, fixture.owner.engine.memory.used);
        try std.testing.expectEqual(input_bytes, fixture.budget.used);
    }
}

test "owned submission rolls back conversion and engine failure without consuming the lease" {
    const Case = enum { invalid_header, scratch, engine, cancelled };
    for (std.enums.values(Case)) |case| {
        var fixture: Fixture = .{};
        try fixture.init();
        defer fixture.deinit();
        const work = fixture.registry.next().?.execute;
        defer _ = fixture.registry.finish(work.ticket);
        var environment = values.Environment{ .allocator = std.testing.allocator };
        var host = environment.rocHost();
        const input_bytes = fixture.budget.used;
        const engine_limit = fixture.owner.engine.memory.limit;
        const scratch_limit = fixture.budget.limit;
        if (case == Case.scratch) fixture.budget.limit = fixture.budget.used;
        if (case == Case.engine) fixture.owner.engine.memory.limit = fixture.owner.engine.memory.used;
        // The protocol can reject a response before its close callback arrives.
        if (case == Case.cancelled) try fixture.owner.cancel(work.id);
        const value = if (case == Case.invalid_header)
            values.response(200, &.{.{ .name = "Connection", .value = "close" }}, body, &host)
        else
            response(&host);
        const expected = switch (case) {
            Case.invalid_header => error.ApplicationControlsMessageFraming,
            Case.scratch, Case.engine => error.OutOfMemory,
            Case.cancelled => error.Closed,
        };
        try std.testing.expectError(expected, fixture.owner.respondOwned(&fixture.registry, work.ticket, value, &host, bridge.ResponseRequestSemantics.regular));
        try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
        try std.testing.expectEqual(input_bytes, fixture.budget.used);
        try std.testing.expect(fixture.registry.leases.runningStream(work.ticket) != null);
        fixture.owner.engine.memory.limit = engine_limit;
        fixture.budget.limit = scratch_limit;
        if (case != Case.cancelled) {
            try fixture.owner.respondOwned(&fixture.registry, work.ticket, response(&host), &host, bridge.ResponseRequestSemantics.regular);
            try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
        }
    }
}

test "owned submission rolls back every partial allocation before successful submission" {
    // Measure only the submission allocations; setup must succeed before fault
    // injection. A fresh session per index avoids caches hiding later failures.
    var submission_allocations: usize = 0;
    var failure_index: usize = 0;
    while (failure_index == 0 or failure_index <= submission_allocations) : (failure_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        {
            var fixture: Fixture = .{};
            try fixture.initWithAllocator(failing.allocator());
            defer fixture.deinit();
            const work = fixture.registry.next().?.execute;
            defer _ = fixture.registry.finish(work.ticket);
            var environment = values.Environment{ .allocator = std.testing.allocator };
            var host = environment.rocHost();
            const input_bytes = fixture.budget.used;
            const start = failing.alloc_index;
            // First run establishes the allocation count, then fail each one.
            if (failure_index > 0) failing.fail_index = start + failure_index - 1;
            const result = fixture.owner.respondOwned(&fixture.registry, work.ticket, response(&host), &host, bridge.ResponseRequestSemantics.regular);
            if (failure_index == 0) {
                try result;
                submission_allocations = failing.alloc_index - start;
                // Two scratch allocations, the body copy, then nghttp2's
                // submission allocations must all be included in the sweep.
                try std.testing.expect(submission_allocations > 3);
            } else {
                try std.testing.expect(failing.has_induced_failure);
                try std.testing.expectEqual(failure_index - 1, failing.alloc_index - start);
                try std.testing.expectError(error.OutOfMemory, result);
            }
            try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
            try std.testing.expectEqual(input_bytes, fixture.budget.used);
            try std.testing.expect(fixture.registry.leases.runningStream(work.ticket) != null);
            failing.fail_index = std.math.maxInt(usize);
            if (failure_index > 0) {
                try fixture.owner.respondOwned(&fixture.registry, work.ticket, response(&host), &host, bridge.ResponseRequestSemantics.regular);
                try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
                try std.testing.expectEqual(input_bytes, fixture.budget.used);
            }
        }
        // Include the session's retained allocations in the final leak check.
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try std.testing.expectEqual(failing.allocations, failing.deallocations);
    }
}
