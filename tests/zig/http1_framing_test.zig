const std = @import("std");
const http1 = @import("http1_parser");

const BodyFraming = http1.BodyFraming;
const FeedResult = http1.FeedResult;
const FeedResultTag = http1.FeedResultTag;
const ParseError = http1.ParseError;
const Parser = http1.Parser;

fn expectError(expected: ParseError, result: FeedResult) !void {
    try std.testing.expectEqual(
        FeedResultTag.err,
        std.meta.activeTag(result),
    );
    try std.testing.expectEqual(expected, result.err);
}

fn expectComplete(result: FeedResult) !void {
    try std.testing.expectEqual(
        FeedResultTag.head_complete,
        std.meta.activeTag(result),
    );
}

fn expectNoBody(parser: *const Parser) !void {
    const body_framing = parser.bodyFraming() orelse
        return error.MissingBodyFraming;
    switch (body_framing) {
        BodyFraming.none => {},
        else => return error.UnexpectedBodyFraming,
    }
}

fn expectContentLength(parser: *const Parser, expected: u64) !void {
    const body_framing = parser.bodyFraming() orelse
        return error.MissingBodyFraming;
    switch (body_framing) {
        BodyFraming.content_length => |actual| {
            try std.testing.expectEqual(expected, actual);
        },
        else => return error.UnexpectedBodyFraming,
    }
}

fn expectChunked(parser: *const Parser) !void {
    const body_framing = parser.bodyFraming() orelse
        return error.MissingBodyFraming;
    switch (body_framing) {
        BodyFraming.chunked => {},
        else => return error.UnexpectedBodyFraming,
    }
}

test "HTTP 1.1 requires exactly one Host while HTTP 1.0 does not" {
    try expectError(
        ParseError.missing_host,
        http1.parseAll("GET / HTTP/1.1\r\n\r\n"),
    );

    var http_1_0 = Parser{};
    try expectComplete(http_1_0.feed("GET / HTTP/1.0\r\n\r\n"));
    try expectNoBody(&http_1_0);

    var http_1_1 = Parser{};
    try expectComplete(http_1_1.feed(
        "GET / HTTP/1.1\r\nhOsT: example.com\r\n\r\n",
    ));
    try expectNoBody(&http_1_1);

    try expectError(
        ParseError.duplicate_host,
        http1.parseAll(
            "GET / HTTP/1.1\r\n" ++
                "Host: first\r\n" ++
                "HOST: second\r\n\r\n",
        ),
    );
}

test "Host validates authority syntax and outer OWS" {
    const valid = [_][]const u8{
        "",
        "example.com",
        "example.com:8080",
        "a%2Eb",
        "[::1]",
        "[2001:db8::1]:443",
        "[v1.host:part]:443",
        "\t example.com:443 \t",
    };

    for (valid) |value| {
        var buffer: [160]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &buffer,
            "GET / HTTP/1.1\r\nHost:{s}\r\n\r\n",
            .{value},
        );
        try expectComplete(http1.parseAll(input));
    }

    const invalid = [_][]const u8{
        "example.com bad",
        "a%2",
        "a%xx",
        "[gg]:443",
        "[v.example]:443",
        "[]:443",
        "user@example.com",
        "example.com/path",
    };

    for (invalid) |value| {
        var buffer: [160]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &buffer,
            "GET / HTTP/1.1\r\nHost: {s}\r\n\r\n",
            .{value},
        );
        try expectError(ParseError.invalid_host, http1.parseAll(input));
    }
}

test "Content-Length accepts zero and the u64 maximum" {
    const Case = struct {
        text: []const u8,
        expected: u64,
    };
    const cases = [_]Case{
        .{ .text = "0", .expected = 0 },
        .{ .text = "1", .expected = 1 },
        .{
            .text = "18446744073709551614",
            .expected = std.math.maxInt(u64) - 1,
        },
        .{
            .text = "18446744073709551615",
            .expected = std.math.maxInt(u64),
        },
    };

    for (cases) |case| {
        var buffer: [160]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &buffer,
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length:\t {s} \t\r\n\r\n",
            .{case.text},
        );
        var parser = Parser{};
        try expectComplete(parser.feed(input));
        try expectContentLength(&parser, case.expected);
    }

    try expectError(
        ParseError.content_length_overflow,
        http1.parseAll(
            "POST / HTTP/1.1\r\nHost: x\r\n" ++
                "Content-Length: 18446744073709551616\r\n\r\n",
        ),
    );
}

test "Content-Length rejects invalid syntax and every multiple-value form" {
    const invalid_values = [_][]const u8{
        "",
        "+1",
        "-1",
        "1 2",
        "1,1",
        "1, 1",
        "1,2",
    };

    for (invalid_values) |value| {
        var buffer: [128]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &buffer,
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: {s}\r\n\r\n",
            .{value},
        );
        try expectError(
            ParseError.invalid_content_length,
            http1.parseAll(input),
        );
    }

    const duplicates = [_][]const u8{
        "Content-Length: 5\r\nContent-Length: 5\r\n",
        "Content-Length: 5\r\nContent-Length: 6\r\n",
    };
    for (duplicates) |headers| {
        var buffer: [160]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &buffer,
            "POST / HTTP/1.1\r\nHost: x\r\n{s}\r\n",
            .{headers},
        );
        try expectError(
            ParseError.duplicate_content_length,
            http1.parseAll(input),
        );
    }
}

test "Content-Length and Transfer-Encoding conflict in either order" {
    const cases = [_][]const u8{
        "Content-Length: 5\r\nTransfer-Encoding: chunked\r\n",
        "Transfer-Encoding: chunked\r\nContent-Length: 5\r\n",
    };

    for (cases) |headers| {
        var buffer: [160]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &buffer,
            "POST / HTTP/1.1\r\nHost: x\r\n{s}\r\n",
            .{headers},
        );
        try expectError(
            ParseError.conflicting_message_framing,
            http1.parseAll(input),
        );
    }
}

test "Transfer-Encoding accepts a final chunked coding" {
    const values = [_][]const u8{
        "chunked",
        "CHUNKED",
    };

    for (values) |value| {
        var buffer: [192]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &buffer,
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: {s}\r\n\r\n",
            .{value},
        );
        var parser = Parser{};
        try expectComplete(parser.feed(input));
        try expectChunked(&parser);
    }
}

test "Transfer-Encoding rejects non-final or malformed chunked coding" {
    const Case = struct {
        value: []const u8,
        expected: ParseError,
    };
    const cases = [_]Case{
        .{
            .value = "gzip",
            .expected = ParseError.unsupported_transfer_coding,
        },
        .{
            .value = "gzip, chunked",
            .expected = ParseError.unsupported_transfer_coding,
        },
        .{
            .value = "gzip; level=1, chunked",
            .expected = ParseError.unsupported_transfer_coding,
        },
        .{
            .value = "custom; note=\"a,b\", chunked",
            .expected = ParseError.unsupported_transfer_coding,
        },
        .{
            .value = "chunked, gzip",
            .expected = ParseError.invalid_transfer_encoding,
        },
        .{
            .value = "chunked, chunked",
            .expected = ParseError.invalid_transfer_encoding,
        },
        .{
            .value = "chunked; x=1",
            .expected = ParseError.invalid_transfer_encoding,
        },
        .{
            .value = "",
            .expected = ParseError.invalid_transfer_encoding,
        },
        .{
            .value = ", chunked",
            .expected = ParseError.invalid_transfer_encoding,
        },
        .{
            .value = "gzip,",
            .expected = ParseError.unsupported_transfer_coding,
        },
    };

    for (cases) |case| {
        var buffer: [160]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &buffer,
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: {s}\r\n\r\n",
            .{case.value},
        );
        try expectError(case.expected, http1.parseAll(input));
    }
}

test "HTTP 1.0 rejects Transfer-Encoding" {
    try expectError(
        ParseError.transfer_encoding_on_http_1_0,
        http1.parseAll(
            "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n",
        ),
    );
}

test "framing semantics are independent of every feed split" {
    const input =
        "POST / HTTP/1.1\r\n" ++
        "hOsT: example.com\r\n" ++
        "Transfer-Encoding: CHUNKED\r\n" ++
        "\r\n";

    for (0..input.len + 1) |split| {
        var parser = Parser{};
        const first = parser.feed(input[0..split]);
        if (split == input.len) {
            try expectComplete(first);
        } else {
            try std.testing.expectEqual(
                FeedResultTag.need_more,
                std.meta.activeTag(first),
            );
            try expectComplete(parser.feed(input[split..]));
        }
        try expectChunked(&parser);
    }
}

test "body framing is published only after the complete head" {
    var parser = Parser{};
    try std.testing.expectEqual(
        FeedResultTag.need_more,
        std.meta.activeTag(parser.feed(
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n",
        )),
    );
    try std.testing.expect(parser.bodyFraming() == null);

    try expectComplete(parser.feed("\r\n"));
    try expectContentLength(&parser, 5);
}
