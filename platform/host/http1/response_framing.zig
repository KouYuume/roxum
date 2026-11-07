const std = @import("std");
const encoder = @import("encoder.zig");
const persistence = @import("persistence.zig");

pub const Header = encoder.Header;
pub const HttpVersion = encoder.HttpVersion;
pub const ResponseConnection = persistence.ResponseConnection;

pub const RequestSemantics = enum {
    regular,
    head,
};

pub const Error = error{
    ApplicationControlsMessageFraming,
    InformationalResponseUnsupported,
    BodyNotAllowedForStatus,
};

pub const Plan = struct {
    status: u16,
    body_length: usize,
    transmit_body: bool,
    response_connection: ResponseConnection,

    pub fn syntheticHeaders(
        self: Plan,
        content_length_buffer: *[20]u8,
        output: *[2]Header,
    ) []const Header {
        var count: usize = 0;
        if (self.status != 204 and self.status != 304) {
            const content_length = std.fmt.bufPrint(
                content_length_buffer,
                "{d}",
                .{self.body_length},
            ) catch unreachable;
            output[count] = .{
                .name = "Content-Length",
                .value = content_length,
            };
            count += 1;
        }

        const connection_value: ?[]const u8 = switch (self.response_connection) {
            ResponseConnection.omit => null,
            ResponseConnection.close => "close",
            ResponseConnection.keep_alive => "keep-alive",
        };
        if (connection_value) |value| {
            output[count] = .{
                .name = "Connection",
                .value = value,
            };
            count += 1;
        }
        return output[0..count];
    }
};

pub const StreamingPlan = struct {
    zero_content_length: bool = false,
    transmit_body: bool,
    chunked: bool,
    response_connection: ResponseConnection,

    pub fn syntheticHeaders(
        self: StreamingPlan,
        output: *[2]Header,
    ) []const Header {
        var count: usize = 0;
        if (self.zero_content_length) {
            output[count] = .{ .name = "Content-Length", .value = "0" };
            count += 1;
        }
        if (self.chunked) {
            output[count] = .{
                .name = "Transfer-Encoding",
                .value = "chunked",
            };
            count += 1;
        }

        const connection_value: ?[]const u8 = switch (self.response_connection) {
            ResponseConnection.omit => null,
            ResponseConnection.close => "close",
            ResponseConnection.keep_alive => "keep-alive",
        };
        if (connection_value) |value| {
            output[count] = .{
                .name = "Connection",
                .value = value,
            };
            count += 1;
        }
        return output[0..count];
    }
};

pub fn validateApplicationHeader(name: []const u8) Error!void {
    if (std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "connection"))
    {
        return Error.ApplicationControlsMessageFraming;
    }
}

pub fn plan(
    status: u16,
    body_length: usize,
    response_connection: ResponseConnection,
    request_semantics: RequestSemantics,
) Error!Plan {
    if (status >= 100 and status < 200) return Error.InformationalResponseUnsupported;
    if (statusForbidsBody(status) and body_length != 0) return Error.BodyNotAllowedForStatus;

    return .{
        .status = status,
        .body_length = body_length,
        .transmit_body = request_semantics != RequestSemantics.head and
            !statusForbidsBody(status),
        .response_connection = response_connection,
    };
}

pub fn planStreaming(
    status: u16,
    version: encoder.HttpVersion,
    response_connection: ResponseConnection,
    request_semantics: RequestSemantics,
) Error!StreamingPlan {
    if (status >= 100 and status < 200) return Error.InformationalResponseUnsupported;

    const transmit_body = request_semantics != RequestSemantics.head and
        !statusForbidsBody(status);
    if (!transmit_body) {
        return .{
            .zero_content_length = status == 205,
            .transmit_body = false,
            .chunked = false,
            .response_connection = response_connection,
        };
    }

    return switch (version) {
        encoder.HttpVersion.http_1_1 => .{
            .transmit_body = true,
            .chunked = true,
            .response_connection = response_connection,
        },
        encoder.HttpVersion.http_1_0 => .{
            .transmit_body = true,
            .chunked = false,
            .response_connection = ResponseConnection.close,
        },
    };
}

fn statusForbidsBody(status: u16) bool {
    return status == 204 or status == 205 or status == 304;
}
