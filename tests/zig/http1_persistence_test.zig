const std = @import("std");
const persistence = @import("http1_persistence");

const Decision = persistence.Decision;
const ResponseConnection = persistence.ResponseConnection;
const Tracker = persistence.Tracker;

fn decide(
    version: persistence.HttpVersion,
    values: []const []const u8,
) !Decision {
    var tracker = Tracker{};
    for (values) |value| {
        try tracker.observe("Connection", value);
    }
    return tracker.finish(version);
}

test "HTTP version defaults and explicit connection options form the persistence matrix" {
    const HttpVersion = persistence.HttpVersion;
    const cases = [_]struct {
        version: HttpVersion,
        values: []const []const u8,
        reuse_connection: bool,
        response_connection: ResponseConnection,
    }{
        .{
            .version = HttpVersion.http_1_0,
            .values = &.{},
            .reuse_connection = false,
            .response_connection = ResponseConnection.close,
        },
        .{
            .version = HttpVersion.http_1_0,
            .values = &.{"keep-alive"},
            .reuse_connection = true,
            .response_connection = ResponseConnection.keep_alive,
        },
        .{
            .version = HttpVersion.http_1_1,
            .values = &.{},
            .reuse_connection = true,
            .response_connection = ResponseConnection.omit,
        },
        .{
            .version = HttpVersion.http_1_1,
            .values = &.{"close"},
            .reuse_connection = false,
            .response_connection = ResponseConnection.close,
        },
    };

    for (cases) |case| {
        const actual = try decide(case.version, case.values);
        try std.testing.expectEqual(
            case.reuse_connection,
            actual.reuse_connection,
        );
        try std.testing.expectEqual(
            case.response_connection,
            actual.response_connection,
        );
    }
}

test "Connection options are case insensitive comma lists across repeated fields" {
    const HttpVersion = persistence.HttpVersion;
    const actual = try decide(
        HttpVersion.http_1_0,
        &.{ " upgrade , KEEP-ALIVE\t", "Close" },
    );

    try std.testing.expect(!actual.reuse_connection);
    try std.testing.expectEqual(
        ResponseConnection.close,
        actual.response_connection,
    );
}

test "Connection ignores empty elements at list and field boundaries" {
    const values = [_][]const u8{ ",close", "close,,keep-alive", "close,", "close, \t" };
    for (values) |value| {
        const actual = try decide(persistence.HttpVersion.http_1_1, &.{ "", value, " \t" });
        try std.testing.expect(!actual.reuse_connection);
    }
    for ([_]persistence.HttpVersion{ persistence.HttpVersion.http_1_0, persistence.HttpVersion.http_1_1 }) |version| {
        const actual = try decide(version, &.{ "", " \t", ",,", ", \t," });
        const expected = try decide(version, &.{});
        try std.testing.expectEqual(expected, actual);
    }
}

test "Connection list rejects non-token elements" {
    const invalid_values = [_][]const u8{
        "close / keep-alive",
        "close, /,",
        "\"close\"",
        "close;keep-alive",
    };

    for (invalid_values) |value| {
        var tracker = Tracker{};
        try std.testing.expectError(
            error.InvalidConnectionHeader,
            tracker.observe("Connection", value),
        );
    }
}

test "unrelated headers and unknown connection options do not change defaults" {
    const HttpVersion = persistence.HttpVersion;
    var tracker = Tracker{};
    try tracker.observe("X-Connection", "close");
    try tracker.observe("Connection", "upgrade");

    const actual = tracker.finish(HttpVersion.http_1_1);
    try std.testing.expect(actual.reuse_connection);
    try std.testing.expectEqual(
        ResponseConnection.omit,
        actual.response_connection,
    );
}
