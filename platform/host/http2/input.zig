//! Owned finite request input, serialized by its connection owner. Borrowed engine
//! callback bytes never escape. This is not a streaming receive-window manager.
const std = @import("std");
const protocol = @import("engine.zig");
pub const Budget = @import("memory.zig").Memory;
pub const Limits = struct { header_bytes: usize, body_bytes: usize };
pub const Phase = enum { headers, body, ended, rejected };
pub const Error = error{ InvalidState, LimitExceeded, OutOfMemory };

pub const Input = struct {
    budget: *Budget,
    limits: Limits,
    phase: Phase = Phase.headers,
    fields: std.ArrayList(protocol.Header) = std.ArrayList(protocol.Header).empty,
    bytes: std.ArrayList(u8) = std.ArrayList(u8).empty,
    header_bytes: usize = 0,

    /// Budget must outlive this input and all other inputs that share it.
    pub fn init(budget: *Budget, limits: Limits) Input {
        return .{ .budget = budget, .limits = limits };
    }

    pub fn deinit(self: *Input) void {
        self.reject();
    }

    /// After initial completion, header callbacks contain trailers. They are
    /// intentionally omitted from the initial metadata and remain engine-limited.
    pub fn header(self: *Input, field: protocol.Header) Error!void {
        if (self.phase == Phase.body) return;
        if (self.phase != Phase.headers) return error.InvalidState;
        errdefer self.reject();
        const size = std.math.add(usize, field.name.len, field.value.len) catch return error.LimitExceeded;
        const accounted = std.math.add(usize, size, 32) catch return error.LimitExceeded;
        if (accounted > self.limits.header_bytes - self.header_bytes) return error.LimitExceeded;
        const allocator = self.budget.allocator();
        // One allocation keeps both slices stable when the field array grows.
        const owned = try allocator.alloc(u8, size);
        errdefer allocator.free(owned);
        @memcpy(owned[0..field.name.len], field.name);
        @memcpy(owned[field.name.len..], field.value);
        try self.fields.append(allocator, .{ .name = owned[0..field.name.len], .value = owned[field.name.len..] });
        self.header_bytes += accounted;
    }

    pub fn headersComplete(self: *Input) Error!void {
        if (self.phase != Phase.headers) return error.InvalidState;
        self.phase = Phase.body;
    }

    pub fn data(self: *Input, bytes: []const u8) Error!void {
        if (self.phase != Phase.body) return error.InvalidState;
        errdefer self.reject();
        if (bytes.len > self.limits.body_bytes - self.bytes.items.len) return error.LimitExceeded;
        try self.bytes.appendSlice(self.budget.allocator(), bytes);
    }

    pub fn end(self: *Input) Error!void {
        if (self.phase != Phase.body) return error.InvalidState;
        self.phase = Phase.ended;
    }

    /// The owner copies these views before releasing input or dispatching work
    /// to another thread. Rejection or deinit invalidates every borrowed view;
    /// views do not pin input across protocol closure.
    pub fn headers(self: *const Input) ?[]const protocol.Header {
        if (self.phase != Phase.body and self.phase != Phase.ended) return null;
        return self.fields.items;
    }

    pub fn body(self: *const Input) ?[]const u8 {
        if (self.phase != Phase.ended) return null;
        return self.bytes.items;
    }

    pub fn reject(self: *Input) void {
        const allocator = self.budget.allocator();
        for (self.fields.items) |field| allocator.free(field.name.ptr[0 .. field.name.len + field.value.len]);
        self.fields.deinit(allocator);
        self.bytes.deinit(allocator);
        self.fields = std.ArrayList(protocol.Header).empty;
        self.bytes = std.ArrayList(u8).empty;
        self.header_bytes = 0;
        self.phase = Phase.rejected;
    }
};

test "input owns callback bytes and freezes initial fields before body and trailers" {
    var budget = Budget{ .backing = std.testing.allocator, .limit = 4096 };
    var input = Input.init(&budget, .{ .header_bytes = 1024, .body_bytes = 16 });
    defer input.deinit();
    var name = "x-owned".*;
    var value = "original".*;
    var bytes = "body".*;
    try std.testing.expect(input.headers() == null);
    try std.testing.expect(input.body() == null);
    try input.header(.{ .name = &name, .value = &value });
    @memset(&name, 'x');
    @memset(&value, 'x');
    try input.headersComplete();
    try std.testing.expectEqualStrings("x-owned", input.headers().?[0].name);
    try std.testing.expectEqualStrings("original", input.headers().?[0].value);
    try input.data(&bytes);
    @memset(&bytes, 'x');
    try input.header(.{ .name = "trailer", .value = "ignored" });
    try std.testing.expectEqual(@as(usize, 1), input.headers().?.len);
    try std.testing.expect(input.body() == null);
    try input.end();
    try std.testing.expectEqualStrings("body", input.body().?);
    input.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    try std.testing.expect(input.headers() == null);
    try std.testing.expect(input.body() == null);
}

test "header and body accounting accept below and at limits and reject above" {
    for ([_]usize{ 2, 3, 4 }) |size| {
        var budget = Budget{ .backing = std.testing.allocator, .limit = 4096 };
        var input = Input.init(&budget, .{ .header_bytes = 36, .body_bytes = 3 });
        defer input.deinit();
        const result = input.header(.{ .name = "x", .value = "abcd"[0..size] });
        if (size == 4) {
            try std.testing.expectError(error.LimitExceeded, result);
            try std.testing.expectEqual(Phase.rejected, input.phase);
            try std.testing.expectEqual(@as(usize, 0), budget.used);
            continue;
        }
        try result;
        try std.testing.expectEqual(33 + size, input.header_bytes);
        try input.headersComplete();
        try input.end();
        try std.testing.expectEqual(@as(usize, 0), input.body().?.len);
    }
    for ([_]usize{ 2, 3, 4 }) |size| {
        var budget = Budget{ .backing = std.testing.allocator, .limit = 4096 };
        var input = Input.init(&budget, .{ .header_bytes = 36, .body_bytes = 3 });
        defer input.deinit();
        try input.header(.{ .name = "x", .value = "a" });
        try input.headersComplete();
        try input.data("a");
        const result = input.data("bcd"[0 .. size - 1]);
        if (size == 4) {
            try std.testing.expectError(error.LimitExceeded, result);
            try std.testing.expectEqual(Phase.rejected, input.phase);
            try std.testing.expectEqual(@as(usize, 0), budget.used);
        } else {
            try result;
            try input.end();
            try std.testing.expectEqual(size, input.body().?.len);
        }
    }
}

test "cumulative header budget includes every field and rejection is terminal" {
    var budget = Budget{ .backing = std.testing.allocator, .limit = 4096 };
    var input = Input.init(&budget, .{ .header_bytes = 68, .body_bytes = 0 });
    defer input.deinit();
    try input.header(.{ .name = "x", .value = "a" });
    try input.header(.{ .name = "x", .value = "b" });
    try std.testing.expectError(error.LimitExceeded, input.header(.{ .name = "x", .value = "c" }));
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    try std.testing.expectError(error.InvalidState, input.headersComplete());
    try std.testing.expectError(error.InvalidState, input.data(""));
    try std.testing.expectError(error.InvalidState, input.end());
    try std.testing.expectError(error.InvalidState, input.header(.{ .name = "x", .value = "d" }));
}

test "input state transitions reject early data and duplicate completion" {
    var budget = Budget{ .backing = std.testing.allocator, .limit = 4096 };
    var input = Input.init(&budget, .{ .header_bytes = 0, .body_bytes = 0 });
    defer input.deinit();
    try std.testing.expectError(error.InvalidState, input.data(""));
    try std.testing.expectError(error.InvalidState, input.end());
    try input.headersComplete();
    try std.testing.expectError(error.InvalidState, input.headersComplete());
    try input.data("");
    try input.end();
    try std.testing.expectError(error.InvalidState, input.data(""));
    try std.testing.expectError(error.InvalidState, input.end());
    try std.testing.expectError(error.InvalidState, input.header(.{ .name = "x", .value = "y" }));
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

fn allocationLifecycle(allocator: std.mem.Allocator) !void {
    var budget = Budget{ .backing = allocator, .limit = 16384 };
    defer std.debug.assert(budget.used == 0);
    var input = Input.init(&budget, .{ .header_bytes = 2048, .body_bytes = 2048 });
    defer input.deinit();
    // Grow both arrays to cover replacement allocations and their temporary overlap.
    for (0..20) |_| try input.header(.{ .name = "x", .value = "value" });
    try input.headersComplete();
    for (0..128) |_| try input.data("0123456789");
    try input.end();
    try std.testing.expectEqual(@as(usize, 1280), input.body().?.len);
}

test "allocation failures release all partial fields and body capacities" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationLifecycle, .{});
}

test "shared budget bounds concurrent inputs and recovers after release" {
    var budget = Budget{ .backing = std.testing.allocator, .limit = 4096 };
    var first = Input.init(&budget, .{ .header_bytes = 1024, .body_bytes = 1024 });
    defer first.deinit();
    try first.header(.{ .name = "x", .value = "retained" });
    try first.headersComplete();
    const retained = budget.used;
    // Leave no aggregate capacity despite the second request's available limits.
    budget.limit = retained;
    var second = Input.init(&budget, first.limits);
    defer second.deinit();
    try std.testing.expectError(error.OutOfMemory, second.header(.{ .name = "x", .value = "other" }));
    try std.testing.expectEqual(retained, budget.used);
    try std.testing.expectEqualStrings("retained", first.headers().?[0].value);
    first.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    var next = Input.init(&budget, first.limits);
    defer next.deinit();
    try next.header(.{ .name = "x", .value = "retained" });
    try std.testing.expectEqual(retained, budget.used);
}

test "aggregate allocation ceiling includes capacity and overlapping growth" {
    var measurement = Budget{ .backing = std.testing.allocator, .limit = 16384 };
    {
        var input = Input.init(&measurement, .{ .header_bytes = 1024, .body_bytes = 1024 });
        defer input.deinit();
        try input.header(.{ .name = "x", .value = "budget" });
        try input.headersComplete();
        for (0..100) |_| try input.data("0123456789");
    }
    const peak = measurement.peak;
    try std.testing.expect(peak > 0);
    try std.testing.expectEqual(@as(usize, 0), measurement.used);
    for ([_]usize{ peak - 1, peak, peak + 1 }) |limit| {
        var budget = Budget{ .backing = std.testing.allocator, .limit = limit };
        var input = Input.init(&budget, .{ .header_bytes = 1024, .body_bytes = 1024 });
        defer input.deinit();
        try input.header(.{ .name = "x", .value = "budget" });
        try input.headersComplete();
        var failed = false;
        for (0..100) |_| {
            input.data("0123456789") catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                failed = true;
                break;
            };
        }
        try std.testing.expectEqual(limit < peak, failed);
        if (failed) {
            try std.testing.expectEqual(@as(usize, 0), budget.used);
            try std.testing.expectEqual(Phase.rejected, input.phase);
        } else {
            try input.end();
            try std.testing.expectEqual(@as(usize, 1000), input.body().?.len);
            try std.testing.expectEqual(peak, budget.peak);
        }
    }
}
