const std = @import("std");
const syntax = @import("syntax.zig");
const types = @import("types.zig");

pub const HttpVersion = types.HttpVersion;

pub const ResponseConnection = enum {
    omit,
    close,
    keep_alive,
};

pub const Decision = struct {
    reuse_connection: bool,
    response_connection: ResponseConnection,
};

pub const Error = error{
    InvalidConnectionHeader,
};

pub const Tracker = struct {
    saw_close: bool = false,
    saw_keep_alive: bool = false,

    pub fn observe(
        self: *Tracker,
        name: []const u8,
        value: []const u8,
    ) Error!void {
        if (!std.ascii.eqlIgnoreCase(name, "connection")) return;
        try self.observeConnectionValue(value);
    }

    pub fn finish(
        self: Tracker,
        version: types.HttpVersion,
    ) Decision {
        if (self.saw_close) {
            return .{
                .reuse_connection = false,
                .response_connection = ResponseConnection.close,
            };
        }

        return switch (version) {
            types.HttpVersion.http_1_1 => .{
                .reuse_connection = true,
                .response_connection = ResponseConnection.omit,
            },
            types.HttpVersion.http_1_0 => if (self.saw_keep_alive)
                .{
                    .reuse_connection = true,
                    .response_connection = ResponseConnection.keep_alive,
                }
            else
                .{
                    .reuse_connection = false,
                    .response_connection = ResponseConnection.close,
                },
        };
    }

    fn observeConnectionValue(
        self: *Tracker,
        value: []const u8,
    ) Error!void {
        var elements = std.mem.splitScalar(u8, value, ',');
        while (elements.next()) |element| {
            const token = std.mem.trim(u8, element, " \t");
            if (token.len == 0) continue;
            for (token) |byte| {
                if (!syntax.isToken(byte)) return Error.InvalidConnectionHeader;
            }
            if (std.ascii.eqlIgnoreCase(token, "close")) {
                self.saw_close = true;
            } else if (std.ascii.eqlIgnoreCase(token, "keep-alive")) {
                self.saw_keep_alive = true;
            }
        }
    }
};

pub fn decideParsed(
    version: types.HttpVersion,
    headers: []const types.Header,
    head_bytes: []const u8,
) Error!Decision {
    var tracker = Tracker{};
    for (headers) |header| {
        try tracker.observe(
            header.name.slice(head_bytes),
            header.value.slice(head_bytes),
        );
    }
    return tracker.finish(version);
}
