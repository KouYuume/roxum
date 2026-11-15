//! A bounded connection-owned snapshot. No Roc values survive registration.
const std = @import("std");
const engine = @import("engine.zig");

pub const Response = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    status: u16,
    headers: [64]engine.Header = undefined,
    trailers: [64]engine.Header = undefined,
    header_count: usize,
    trailer_count: usize,
    body: []const u8,

    /// The engine validates all size and protocol constraints before allocation.
    pub fn init(allocator: std.mem.Allocator, protocol: *engine.Engine, id: engine.StreamId, status: u16, headers: []const engine.Header, body: []const u8, trailers: []const engine.Header) engine.Error!Response {
        try protocol.validateFiniteResponse(id, status, headers, body, trailers);
        var size = body.len;
        for (headers) |field| size = std.math.add(usize, size, field.name.len + field.value.len) catch return error.LimitExceeded;
        for (trailers) |field| size = std.math.add(usize, size, field.name.len + field.value.len) catch return error.LimitExceeded;
        const bytes = try allocator.alloc(u8, size);
        var result = Response{ .allocator = allocator, .bytes = bytes, .status = status, .header_count = headers.len, .trailer_count = trailers.len, .body = bytes[0..body.len] };
        @memcpy(bytes[0..body.len], body);
        var offset = body.len;
        for (headers, 0..) |field, index| result.headers[index] = copyField(bytes, &offset, field);
        for (trailers, 0..) |field, index| result.trailers[index] = copyField(bytes, &offset, field);
        return result;
    }

    fn copyField(bytes: []u8, offset: *usize, field: engine.Header) engine.Header {
        const name = bytes[offset.*..][0..field.name.len];
        @memcpy(name, field.name);
        offset.* += name.len;
        const value = bytes[offset.*..][0..field.value.len];
        @memcpy(value, field.value);
        offset.* += value.len;
        return .{ .name = name, .value = value };
    }

    pub fn submit(self: *const Response, protocol: *engine.Engine, id: engine.StreamId) engine.Error!void {
        try protocol.respondWithTrailers(id, self.status, self.headers[0..self.header_count], self.body, self.trailers[0..self.trailer_count]);
    }

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};
