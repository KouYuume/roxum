const std = @import("std");
const types = @import("types.zig");

pub const Kind = enum {
    bad_request,
    request_timeout,
    content_too_large,
    uri_too_long,
    header_fields_too_large,
    expectation_failed,
    not_implemented,
    internal_server_error,
    service_unavailable,
    http_version_not_supported,
};

pub const Buffer = [192]u8;

/// The seconds a 503 asks the client to wait before trying again:
/// the worker is busy for now, and usually not for long.
pub const retry_after_seconds = 1;

/// The status code of the response for `kind`.
pub fn statusCode(kind: Kind) u16 {
    return switch (kind) {
        Kind.bad_request => 400,
        Kind.request_timeout => 408,
        Kind.content_too_large => 413,
        Kind.uri_too_long => 414,
        Kind.header_fields_too_large => 431,
        Kind.expectation_failed => 417,
        Kind.not_implemented => 501,
        Kind.internal_server_error => 500,
        Kind.service_unavailable => 503,
        Kind.http_version_not_supported => 505,
    };
}

pub fn render(
    kind: Kind,
    version: types.HttpVersion,
    buffer: *Buffer,
) []const u8 {
    return renderWithDate(kind, version, buffer, null);
}

pub fn renderWithDate(kind: Kind, version: types.HttpVersion, buffer: *Buffer, date: ?[]const u8) []const u8 {
    const status = switch (kind) {
        Kind.bad_request => "400 Bad Request",
        Kind.request_timeout => "408 Request Timeout",
        Kind.content_too_large => "413 Content Too Large",
        Kind.uri_too_long => "414 URI Too Long",
        Kind.header_fields_too_large => "431 Request Header Fields Too Large",
        Kind.expectation_failed => "417 Expectation Failed",
        Kind.not_implemented => "501 Not Implemented",
        Kind.internal_server_error => "500 Internal Server Error",
        Kind.service_unavailable => "503 Service Unavailable",
        Kind.http_version_not_supported => "505 HTTP Version Not Supported",
    };
    const protocol = switch (version) {
        types.HttpVersion.http_1_0 => "HTTP/1.0",
        types.HttpVersion.http_1_1 => "HTTP/1.1",
    };

    // A 503 means the server is overloaded or stopping: say when to
    // try again, as load balancers and HTTP clients read it.
    const retry_after = if (kind == Kind.service_unavailable)
        std.fmt.comptimePrint("Retry-After: {d}\r\n", .{retry_after_seconds})
    else
        "";
    return std.fmt.bufPrint(
        buffer,
        "{s} {s}\r\n{s}{s}{s}{s}" ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{ protocol, status, if (date != null) "Date: " else "", date orelse "", if (date != null) "\r\n" else "", retry_after },
    ) catch unreachable;
}

test "fixed error responses cover every status and HTTP version" {
    const cases = [_]struct {
        kind: Kind,
        status: []const u8,
    }{
        .{ .kind = Kind.bad_request, .status = "400 Bad Request" },
        .{ .kind = Kind.request_timeout, .status = "408 Request Timeout" },
        .{ .kind = Kind.content_too_large, .status = "413 Content Too Large" },
        .{ .kind = Kind.uri_too_long, .status = "414 URI Too Long" },
        .{
            .kind = Kind.header_fields_too_large,
            .status = "431 Request Header Fields Too Large",
        },
        .{ .kind = Kind.expectation_failed, .status = "417 Expectation Failed" },
        .{ .kind = Kind.not_implemented, .status = "501 Not Implemented" },
        .{
            .kind = Kind.internal_server_error,
            .status = "500 Internal Server Error",
        },
        .{
            .kind = Kind.service_unavailable,
            .status = "503 Service Unavailable",
        },
        .{
            .kind = Kind.http_version_not_supported,
            .status = "505 HTTP Version Not Supported",
        },
    };
    const versions = [_]types.HttpVersion{
        types.HttpVersion.http_1_0,
        types.HttpVersion.http_1_1,
    };

    for (versions) |version| {
        for (cases) |case| {
            var buffer: Buffer = undefined;
            const response = render(case.kind, version, &buffer);
            try std.testing.expect(
                std.mem.indexOf(u8, response, case.status) != null,
            );
            try std.testing.expectEqual(try std.fmt.parseInt(u16, case.status[0..3], 10), statusCode(case.kind));
            try std.testing.expect(
                std.mem.endsWith(
                    u8,
                    response,
                    "Content-Length: 0\r\n" ++
                        "Connection: close\r\n\r\n",
                ),
            );
            const retries = std.mem.indexOf(u8, response, "Retry-After: 1\r\n") != null;
            try std.testing.expectEqual(case.kind == Kind.service_unavailable, retries);
        }
    }
}
