//! Finite Roc response ownership at the HTTP/2 transport boundary.
const std = @import("std");
const abi = @import("../roc_platform_abi.zig");
const Header = @import("../http_field.zig").Header;
const framing = @import("../http1/response_framing.zig");
const syntax = @import("../http1/syntax.zig");

pub const Limits = struct { header_bytes: usize, body_bytes: usize };
pub const Error = framing.Error || error{ InvalidStatus, InvalidHeaders, LimitExceeded, OutOfMemory };

pub const OwnedResponse = struct {
    response: abi.HttpResponse,
    roc_host: *abi.RocHost,
    allocator: std.mem.Allocator,
    headers: []Header,
    names: []u8,
    body: []const u8,

    /// Consumes one response reference, including on failure. Use a bounded
    /// scratch allocator owned by the serialized connection, with its limits.
    /// The views remain valid until deinit, even if this value moves. Submit
    /// them to the copying engine outside callbacks before releasing ownership.
    /// This is not a thread-safe queue payload or a streaming response writer.
    pub fn init(response: abi.HttpResponse, roc_host: *abi.RocHost, allocator: std.mem.Allocator, semantics: framing.RequestSemantics, limits: Limits) Error!OwnedResponse {
        errdefer response.decref(roc_host);
        if (response.status < 200 or response.status > 599) return error.InvalidStatus;
        const body = switch (response.body.tag) {
            abi.HttpResponseBodyTag.Empty => &.{},
            abi.HttpResponseBodyTag.Bytes => response.body.payload_bytes().items(),
        };
        const plan = try framing.plan(response.status, body.len, framing.ResponseConnection.keep_alive, semantics);
        if (body.len > limits.body_bytes) return error.LimitExceeded;
        const add_length = response.status != 204 and response.status != 304;
        const fields = response.headers.items();
        // Match the engine's finite response field cap, including synthetic fields.
        if (fields.len > 64 - @as(usize, @intFromBool(add_length))) return error.LimitExceeded;
        var length_buffer: [20]u8 = undefined;
        const length = if (add_length) std.fmt.bufPrint(&length_buffer, "{d}", .{body.len}) catch unreachable else "";
        var accounted: usize = 42; // :status plus the three-digit status and field overhead.
        if (add_length) accounted += 46 + length.len;
        if (accounted > limits.header_bytes) return error.LimitExceeded;
        var name_bytes: usize = length.len;
        for (fields) |field| {
            const name = field.name.asSlice();
            const value = field.value.asSlice();
            try framing.validateApplicationHeader(name);
            if (name.len == 0) return error.InvalidHeaders;
            for (name) |byte| if (!syntax.isToken(byte)) return error.InvalidHeaders;
            for ([_][]const u8{ "keep-alive", "proxy-connection", "upgrade", "te" }) |forbidden| {
                if (std.ascii.eqlIgnoreCase(name, forbidden)) return error.InvalidHeaders;
            }
            if (!syntax.isFieldValueSlice(value)) return error.InvalidHeaders;
            if (value.len > 0 and (syntax.isOptionalWhitespace(value[0]) or syntax.isOptionalWhitespace(value[value.len - 1]))) return error.InvalidHeaders;
            const size = std.math.add(usize, name.len, value.len) catch return error.LimitExceeded;
            const charged = std.math.add(usize, size, 32) catch return error.LimitExceeded;
            if (charged > limits.header_bytes - accounted) return error.LimitExceeded;
            accounted += charged;
            name_bytes = std.math.add(usize, name_bytes, name.len) catch return error.LimitExceeded;
        }
        const headers = try allocator.alloc(Header, fields.len + @intFromBool(add_length));
        errdefer allocator.free(headers);
        const names = try allocator.alloc(u8, name_bytes);
        errdefer allocator.free(names);
        var offset: usize = 0;
        for (fields, 0..) |*field, index| {
            const name = field.name.asSlice();
            const owned = names[offset..][0..name.len];
            for (name, owned) |byte, *lower| lower.* = std.ascii.toLower(byte);
            headers[index] = .{ .name = owned, .value = field.value.asSlice() };
            offset += name.len;
        }
        if (add_length) {
            @memcpy(names[offset..], length);
            headers[fields.len] = .{ .name = "content-length", .value = names[offset..] };
        }
        return .{ .response = response, .roc_host = roc_host, .allocator = allocator, .headers = headers, .names = names, .body = if (plan.transmit_body) body else &.{} };
    }

    /// Call exactly once after engine submission succeeds or fails. The engine
    /// copies fields and body, so pending socket writes need no Roc references.
    pub fn deinit(self: *OwnedResponse) void {
        self.allocator.free(self.headers);
        self.allocator.free(self.names);
        self.response.decref(self.roc_host);
        self.* = undefined;
    }
};
