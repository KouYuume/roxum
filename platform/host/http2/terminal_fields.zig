//! Bounded terminal metadata owned by the connection, never by a Roc stack.
const std = @import("std");
const engine = @import("engine.zig");

pub const Fields = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    fields: []engine.Header,

    pub fn init(allocator: std.mem.Allocator, protocol: *engine.Engine, source: []const engine.Header) engine.Error!Fields {
        if (source.len > 64) return error.LimitExceeded;
        var size: usize = 0;
        var charged: usize = 0;
        for (source) |header| {
            const length = std.math.add(usize, header.name.len, header.value.len) catch return error.LimitExceeded;
            size = std.math.add(usize, size, length) catch return error.LimitExceeded;
            charged = std.math.add(usize, charged, length) catch return error.LimitExceeded;
            charged = std.math.add(usize, charged, 32) catch return error.LimitExceeded;
        }
        if (charged > protocol.limits.header_bytes) return error.LimitExceeded;
        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);
        const fields = try allocator.alloc(engine.Header, source.len);
        errdefer allocator.free(fields);
        const result = Fields{ .allocator = allocator, .bytes = bytes, .fields = fields };
        var offset: usize = 0;
        for (source, 0..) |header, index| {
            const name = bytes[offset..][0..header.name.len];
            for (header.name, name) |byte, *lower| lower.* = std.ascii.toLower(byte);
            offset += name.len;
            const value = bytes[offset..][0..header.value.len];
            @memcpy(value, header.value);
            offset += value.len;
            result.fields[index] = .{ .name = name, .value = value };
        }
        try protocol.validateTrailers(result.fields);
        return result;
    }

    pub fn deinit(self: *Fields) void {
        self.allocator.free(self.fields);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Selection = enum { open, normal, expiry };
pub const Terminal = struct {
    selection: Selection = Selection.open,
    fields: ?Fields = null,
    submitted: bool = false,

    pub fn deinit(self: *Terminal) void {
        if (self.fields) |*fields| fields.deinit();
        self.* = .{};
    }
};
