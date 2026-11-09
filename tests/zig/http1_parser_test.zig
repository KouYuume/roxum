const std = @import("std");
const http1 = @import("http1_parser");

const FeedResult = http1.FeedResult;
const FeedResultTag = http1.FeedResultTag;
const HttpVersion = http1.HttpVersion;
const ParseError = http1.ParseError;
const Parser = http1.Parser;
const TargetForm = http1.TargetForm;

fn expectNeedMore(result: FeedResult) !void {
    try std.testing.expectEqual(
        FeedResultTag.need_more,
        std.meta.activeTag(result),
    );
}

fn expectError(expected: ParseError, result: FeedResult) !void {
    try std.testing.expectEqual(
        FeedResultTag.err,
        std.meta.activeTag(result),
    );
    try std.testing.expectEqual(expected, result.err);
}

fn expectHeadComplete(
    expected_head_length: u32,
    expected_consumed: usize,
    result: FeedResult,
) !void {
    try std.testing.expectEqual(
        FeedResultTag.head_complete,
        std.meta.activeTag(result),
    );
    try std.testing.expectEqual(
        expected_head_length,
        result.head_complete.head_length,
    );
    try std.testing.expectEqual(
        expected_consumed,
        result.head_complete.consumed,
    );
}

fn expectRequestLine(
    parser: anytype,
    input: []const u8,
    method: []const u8,
    target: []const u8,
    target_form: TargetForm,
    version: HttpVersion,
) !void {
    const request_line = parser.requestLine() orelse
        return error.MissingRequestLine;

    try std.testing.expectEqualStrings(
        method,
        request_line.method.slice(input),
    );
    try std.testing.expectEqualStrings(
        target,
        request_line.target.slice(input),
    );
    try std.testing.expectEqual(target_form, request_line.target_form);
    try std.testing.expectEqual(version, request_line.version);
}

fn isExpectedToken(byte: u8) bool {
    return switch (byte) {
        '0'...'9',
        'A'...'Z',
        'a'...'z',
        '!',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '*',
        '+',
        '-',
        '.',
        '^',
        '_',
        '`',
        '|',
        '~',
        => true,
        else => false,
    };
}

fn isExpectedFieldValue(byte: u8) bool {
    return byte == '\t' or byte == ' ' or
        (byte >= 0x21 and byte <= 0x7e) or
        byte >= 0x80;
}

fn expectAcceptance(expected: bool, result: FeedResult) !void {
    const actual = std.meta.activeTag(result) == FeedResultTag.head_complete;
    try std.testing.expectEqual(expected, actual);
}

test "Parser parses all four request-target forms losslessly" {
    const Case = struct {
        input: []const u8,
        method: []const u8,
        target: []const u8,
        form: TargetForm,
    };
    const cases = [_]Case{
        .{
            .input = "GET /where?q=now HTTP/1.1\r\nHost: x\r\n\r\n",
            .method = "GET",
            .target = "/where?q=now",
            .form = TargetForm.origin,
        },
        .{
            .input = "GET http://example.com/a%2Fb?q=1 HTTP/1.1\r\nHost: x\r\n\r\n",
            .method = "GET",
            .target = "http://example.com/a%2Fb?q=1",
            .form = TargetForm.absolute,
        },
        .{
            .input = "GET custom://user:pass@[::1]/a?q=1 HTTP/1.1\r\nHost: x\r\n\r\n",
            .method = "GET",
            .target = "custom://user:pass@[::1]/a?q=1",
            .form = TargetForm.absolute,
        },
        .{
            .input = "GET urn:example:animal:ferret:nose HTTP/1.1\r\nHost: x\r\n\r\n",
            .method = "GET",
            .target = "urn:example:animal:ferret:nose",
            .form = TargetForm.absolute,
        },
        .{
            .input = "CONNECT example.com:443 HTTP/1.1\r\nHost: x\r\n\r\n",
            .method = "CONNECT",
            .target = "example.com:443",
            .form = TargetForm.authority,
        },
        .{
            .input = "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n",
            .method = "OPTIONS",
            .target = "*",
            .form = TargetForm.asterisk,
        },
    };

    for (cases) |case| {
        var parser = Parser{};
        try expectHeadComplete(
            @intCast(case.input.len),
            case.input.len,
            parser.feed(case.input),
        );
        try expectRequestLine(
            &parser,
            case.input,
            case.method,
            case.target,
            case.form,
            HttpVersion.http_1_1,
        );
    }
}

test "Parser accepts bracketed authority and HTTP 1.0" {
    const input = "CONNECT [::1]:8080 HTTP/1.0\r\n\r\n";
    var parser = Parser{};

    try expectHeadComplete(
        @intCast(input.len),
        input.len,
        parser.feed(input),
    );
    try expectRequestLine(
        &parser,
        input,
        "CONNECT",
        "[::1]:8080",
        TargetForm.authority,
        HttpVersion.http_1_0,
    );
}

test "Parser enforces method-specific target forms" {
    const cases = [_][]const u8{
        "GET * HTTP/1.1\r\n\r\n",
        "CONNECT /path HTTP/1.1\r\n\r\n",
        "CONNECT example.com HTTP/1.1\r\n\r\n",
        "CONNECT :443 HTTP/1.1\r\n\r\n",
        "CONNECT example.com: HTTP/1.1\r\n\r\n",
        "CONNECT [::1]443 HTTP/1.1\r\n\r\n",
        "CONNECT [gg]:443 HTTP/1.1\r\n\r\n",
        "CONNECT [v.example]:443 HTTP/1.1\r\n\r\n",
    };

    for (cases) |input| {
        try expectError(
            ParseError.invalid_target_form,
            http1.parseAll(input),
        );
    }
}

test "Parser rejects malformed request line boundaries" {
    const Case = struct {
        input: []const u8,
        expected: ParseError,
    };
    const cases = [_]Case{
        .{ .input = " / HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_method },
        .{ .input = "G@T / HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_method },
        .{ .input = "GET  HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET / HTTP/1.1 extra\r\n\r\n", .expected = ParseError.invalid_http_version },
        .{ .input = "GET /\n", .expected = ParseError.invalid_line_ending },
        .{ .input = "GET /bad#fragment HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET /bad%2 HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET /a[b] HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET /a?b[c] HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET http://[gg]/ HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET http://a[b]/ HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET http://a@b@c/ HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET http://user@example.com/ HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET http:///path HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET http:/path HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET http: HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET https:/path HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "CONNECT a%2:443 HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_request_target },
        .{ .input = "GET relative HTTP/1.1\r\n\r\n", .expected = ParseError.invalid_target_form },
    };

    for (cases) |case| {
        try expectError(case.expected, http1.parseAll(case.input));
    }
}

test "Parser ignores one empty line before the request-line" {
    // Zero and one leading CRLF are accepted; the method span starts after it.
    const plain = "GET / HTTP/1.1\r\nHost: a\r\n\r\n";
    try expectHeadComplete(plain.len, plain.len, http1.parseAll(plain));

    const one = "\r\n" ++ plain;
    var parser = Parser{};
    try expectHeadComplete(one.len, one.len, parser.feed(one));
    const line = parser.requestLine().?;
    try std.testing.expectEqualStrings("GET", one[line.method.start..][0..line.method.len]);

    // A second empty line, a bare LF, or CR without LF is rejected.
    try expectError(ParseError.invalid_method, http1.parseAll("\r\n\r\n" ++ plain));
    try expectError(ParseError.invalid_line_ending, http1.parseAll("\n" ++ plain));
    try expectError(ParseError.invalid_line_ending, http1.parseAll("\rGET / HTTP/1.1\r\n\r\n"));
}

test "Parser keeps the skipped empty line across incremental feeds" {
    const input = "\r\nGET / HTTP/1.1\r\nHost: a\r\n\r\n";
    var parser = Parser{};
    try expectNeedMore(parser.feed(input[0..1]));
    try expectNeedMore(parser.feed(input[1..2]));
    try expectHeadComplete(input.len, input.len - 2, parser.feed(input[2..]));
    try std.testing.expectEqual(@as(u32, 2), parser.requestLine().?.method.start);
}

test "Parser distinguishes malformed and unsupported HTTP versions" {
    const malformed = [_][]const u8{
        "GET / http/1.1\r\n\r\n",
        "GET / HTTP/1\r\n\r\n",
        "GET / HTTP/1.10\r\n\r\n",
        "GET / HTTP/1.x\r\n\r\n",
    };
    for (malformed) |input| {
        try expectError(
            ParseError.invalid_http_version,
            http1.parseAll(input),
        );
    }

    const unsupported = [_][]const u8{
        "GET / HTTP/0.9\r\n\r\n",
        "GET / HTTP/2.0\r\n\r\n",
        "GET / HTTP/9.9\r\n\r\n",
    };
    for (unsupported) |input| {
        try expectError(
            ParseError.unsupported_http_version,
            http1.parseAll(input),
        );
    }
}

test "Parser publishes request line only after valid CRLF" {
    const valid = "GET / HTTP/1.1\r\n";
    var parser = Parser{};

    try expectNeedMore(parser.feed(valid[0 .. valid.len - 1]));
    try std.testing.expect(parser.requestLine() == null);

    try expectNeedMore(parser.feed(valid[valid.len - 1 ..]));
    try expectRequestLine(
        &parser,
        valid,
        "GET",
        "/",
        TargetForm.origin,
        HttpVersion.http_1_1,
    );

    parser.reset();
    try expectNeedMore(parser.feed("GET / HTTP/1.1\r"));
    try expectError(
        ParseError.invalid_line_ending,
        parser.feed("X"),
    );
    try std.testing.expect(parser.requestLine() == null);
}

test "Parser extracts header spans and trims only outer OWS" {
    const input =
        "GET / HTTP/1.1\r\n" ++
        "Host:\t example.com \t\r\n" ++
        "X-Empty:\t \r\n" ++
        "X-Inner: a \t b\r\n" ++
        "\r\n";
    var parser = Parser{};

    try expectHeadComplete(
        @intCast(input.len),
        input.len,
        parser.feed(input),
    );

    const headers = parser.headers();
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("Host", headers[0].name.slice(input));
    try std.testing.expectEqualStrings("example.com", headers[0].value.slice(input));
    try std.testing.expectEqualStrings("X-Empty", headers[1].name.slice(input));
    try std.testing.expectEqualStrings("", headers[1].value.slice(input));
    try std.testing.expectEqualStrings("X-Inner", headers[2].name.slice(input));
    try std.testing.expectEqualStrings("a \t b", headers[2].value.slice(input));
}

test "Parser accepts complete token punctuation in a header name" {
    const input = "GET / HTTP/1.0\r\n!#$%&'*+-.^_`|~: value\r\n\r\n";
    var parser = Parser{};

    try expectHeadComplete(
        @intCast(input.len),
        input.len,
        parser.feed(input),
    );
    try std.testing.expectEqualStrings(
        "!#$%&'*+-.^_`|~",
        parser.headers()[0].name.slice(input),
    );
}

test "Parser rejects invalid header names around token boundaries" {
    const cases = [_][]const u8{
        "GET / HTTP/1.1\r\n: empty\r\n\r\n",
        "GET / HTTP/1.1\r\nBad Name: value\r\n\r\n",
        "GET / HTTP/1.1\r\nBad\tName: value\r\n\r\n",
        "GET / HTTP/1.1\r\nBad(Name: value\r\n\r\n",
        "GET / HTTP/1.1\r\nBad\x7fName: value\r\n\r\n",
        "GET / HTTP/1.1\r\nName : value\r\n\r\n",
    };

    for (cases) |input| {
        try expectError(
            ParseError.invalid_header_name,
            http1.parseAll(input),
        );
    }
}

test "Parser rejects obs-fold beginning with SP or HTAB" {
    const cases = [_][]const u8{
        "GET / HTTP/1.1\r\nX: first\r\n second\r\n\r\n",
        "GET / HTTP/1.1\r\nX: first\r\n\tsecond\r\n\r\n",
        "GET / HTTP/1.1\r\n value-before-field\r\n\r\n",
    };

    for (cases) |input| {
        try expectError(
            ParseError.obsolete_line_folding,
            http1.parseAll(input),
        );
    }
}

test "Parser validates field value byte-class boundaries" {
    const valid_bytes = [_]u8{ 0x09, 0x20, 0x21, 0x7e, 0x80, 0xff };
    for (valid_bytes) |byte| {
        var input = [_]u8{
            'G', 'E', 'T', ' ',  '/',  ' ',  'H',  'T',  'T', 'P', '/', '1', '.', '0', '\r', '\n',
            'X', ':', ' ', byte, '\r', '\n', '\r', '\n',
        };
        try std.testing.expectEqual(
            FeedResultTag.head_complete,
            std.meta.activeTag(http1.parseAll(input[0..])),
        );
    }

    const invalid_bytes = [_]u8{ 0x00, 0x08, 0x0b, 0x1f, 0x7f };
    for (invalid_bytes) |byte| {
        var input = [_]u8{
            'G', 'E', 'T', ' ',  '/',  ' ',  'H',  'T',  'T', 'P', '/', '1', '.', '0', '\r', '\n',
            'X', ':', ' ', byte, '\r', '\n', '\r', '\n',
        };
        try expectError(
            ParseError.invalid_header_value,
            http1.parseAll(input[0..]),
        );
    }
}

test "Parser header capacity covers below boundary and rejects above" {
    const SmallParser = http1.ParserWithCapacity(2);
    var parser = SmallParser{};
    const below_boundary = "GET / HTTP/1.0\r\nA: 1\r\n\r\n";
    const at_boundary = "GET / HTTP/1.0\r\nA: 1\r\nB: 2\r\n\r\n";

    try expectHeadComplete(
        @intCast(below_boundary.len),
        below_boundary.len,
        parser.feed(below_boundary),
    );
    try std.testing.expectEqual(@as(usize, 1), parser.headers().len);

    parser.reset();
    try expectHeadComplete(
        @intCast(at_boundary.len),
        at_boundary.len,
        parser.feed(at_boundary),
    );
    try std.testing.expectEqual(@as(usize, 2), parser.headers().len);

    parser.reset();
    try expectError(
        ParseError.too_many_headers,
        parser.feed("GET / HTTP/1.0\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n"),
    );
}

test "Parser semantic result is independent of every split position" {
    const input =
        "GET /a%2Fb?q=1 HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Test: a \t b\r\n" ++
        "\r\n";
    try expectSameResultAtEverySplit(input, 2);
    // Values shorter and longer than a vector block, and a Host with a port,
    // cross the boundaries between multi-byte runs and per-byte bytes.
    try expectSameResultAtEverySplit(
        "GET /r57/items/42?x=%41&y HTTP/1.1\r\n" ++
            "accept: */*\r\n" ++
            "accept-encoding: gzip, compress, deflate, br\r\n" ++
            "user-agent: oha/1.16.0  \r\n" ++
            "host: 127.0.0.1:49281\r\n" ++
            "\r\n",
        4,
    );
}

fn expectSameResultAtEverySplit(input: []const u8, header_count: usize) !void {
    var whole = Parser{};
    try expectHeadComplete(@intCast(input.len), input.len, whole.feed(input));
    for (0..input.len + 1) |split| {
        var parser = Parser{};
        const first = parser.feed(input[0..split]);
        if (split != input.len) {
            try expectNeedMore(first);
            try expectHeadComplete(@intCast(input.len), input.len - split, parser.feed(input[split..]));
        }
        try std.testing.expectEqualDeep(whole.requestLine(), parser.requestLine());
        try std.testing.expectEqual(header_count, parser.headers().len);
        try std.testing.expectEqualSlices(http1.Header, whole.headers(), parser.headers());
        try std.testing.expectEqualDeep(whole.bodyFraming(), parser.bodyFraming());
    }
}

test "Parser semantic result splits like the original input" {
    const input =
        "GET /a%2Fb?q=1 HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Test: a \t b\r\n" ++
        "\r\n";

    for (0..input.len + 1) |split| {
        var parser = Parser{};
        const first = parser.feed(input[0..split]);

        if (split == input.len) {
            try expectHeadComplete(@intCast(input.len), input.len, first);
        } else {
            try expectNeedMore(first);
            try expectHeadComplete(
                @intCast(input.len),
                input.len - split,
                parser.feed(input[split..]),
            );
        }

        try expectRequestLine(
            &parser,
            input,
            "GET",
            "/a%2Fb?q=1",
            TargetForm.origin,
            HttpVersion.http_1_1,
        );
        try std.testing.expectEqual(@as(usize, 2), parser.headers().len);
    }
}

test "absolute target authority remains valid across every split position" {
    const input =
        "GET custom://user:pass@[2001:db8::1]:8080/a%2Fb?q=1 HTTP/1.1\r\n" ++
        "Host: ignored.example\r\n" ++
        "\r\n";
    const target = "custom://user:pass@[2001:db8::1]:8080/a%2Fb?q=1";

    for (0..input.len + 1) |split| {
        var parser = Parser{};
        const first = parser.feed(input[0..split]);

        if (split == input.len) {
            try expectHeadComplete(@intCast(input.len), input.len, first);
        } else {
            try expectNeedMore(first);
            try expectHeadComplete(
                @intCast(input.len),
                input.len - split,
                parser.feed(input[split..]),
            );
        }

        try expectRequestLine(
            &parser,
            input,
            "GET",
            target,
            TargetForm.absolute,
            HttpVersion.http_1_1,
        );
    }
}

test "vectorized field validation covers its block boundary" {
    const cases = .{
        "GET / HTTP/1.0\r\nX: " ++ (&@as([15]u8, @splat('a'))) ++ "\r\n\r\n",
        "GET / HTTP/1.0\r\nX: " ++ (&@as([16]u8, @splat('a'))) ++ "\r\n\r\n",
        "GET / HTTP/1.0\r\nX: " ++ (&@as([17]u8, @splat('a'))) ++ "\r\n\r\n",
    };

    inline for (cases, .{ 15, 16, 17 }) |input, expected_length| {
        var parser = Parser{};
        try expectHeadComplete(
            @intCast(input.len),
            input.len,
            parser.feed(input),
        );
        try std.testing.expectEqual(
            @as(u32, expected_length),
            parser.headers()[0].value.len,
        );
    }

    // Position 0 is consumed while entering the value state. Positions 1,
    // 16, and 17 are the first vector lane, its last lane, and the first lane
    // of the following block.
    inline for (.{ 0, 1, 16, 17 }) |control_position| {
        const valid =
            "GET / HTTP/1.0\r\nX: " ++ (&@as([17]u8, @splat('a'))) ++ "\r\n\r\n";
        var input = valid.*;
        const value_start = "GET / HTTP/1.0\r\nX: ".len;
        input[value_start + control_position] = 0x01;

        var parser = Parser{};
        try expectError(
            ParseError.invalid_header_value,
            parser.feed(&input),
        );
    }
}

test "vectorized field validation trims OWS across its block boundary" {
    const cases = .{
        "GET / HTTP/1.0\r\nX: x" ++ (&@as([14]u8, @splat(' '))) ++ "\r\n\r\n",
        "GET / HTTP/1.0\r\nX: x" ++ (&@as([15]u8, @splat(' '))) ++ "\r\n\r\n",
        "GET / HTTP/1.0\r\nX: x" ++ (&@as([16]u8, @splat(' '))) ++ "\r\n\r\n",
    };

    inline for (cases) |input| {
        var parser = Parser{};
        try expectHeadComplete(
            @intCast(input.len),
            input.len,
            parser.feed(input),
        );
        try std.testing.expectEqualStrings(
            "x",
            parser.headers()[0].value.slice(input),
        );
    }
}

test "Parser leaves bytes after the head unconsumed" {
    const head = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    const input = head ++ "BODY";
    var parser = Parser{};

    try expectHeadComplete(
        @intCast(head.len),
        head.len,
        parser.feed(input),
    );
}

test "Parser keeps terminal states and reset restores a fresh parser" {
    var parser = Parser{};

    try expectError(
        ParseError.invalid_line_ending,
        parser.feed("GET / HTTP/1.1\n"),
    );
    try expectError(
        ParseError.invalid_line_ending,
        parser.feed("GET / HTTP/1.1\r\n\r\n"),
    );

    parser.reset();
    const valid = "GET / HTTP/1.0\r\n\r\n";
    try expectHeadComplete(
        @intCast(valid.len),
        valid.len,
        parser.feed(valid),
    );
    try expectHeadComplete(
        @intCast(valid.len),
        0,
        parser.feed("BODY"),
    );
}

test "Parser reaches completion when fed one byte at a time" {
    const head = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    var parser = Parser{};

    for (head, 0..) |byte, index| {
        const result = parser.feed(&.{byte});
        if (index + 1 == head.len) {
            try expectHeadComplete(@intCast(head.len), 1, result);
        } else {
            try expectNeedMore(result);
        }
    }
}

test "Parser enforces the u32 offset boundary" {
    var parser = Parser{
        .offset = std.math.maxInt(u32) - 1,
    };

    try expectNeedMore(parser.feed("G"));
    try std.testing.expectEqual(std.math.maxInt(u32), parser.offset);
    try expectError(ParseError.input_too_large, parser.feed("E"));
    try std.testing.expectEqual(std.math.maxInt(u32), parser.offset);
}

test "multi-byte runs stop at the u32 offset boundary" {
    // A target, header name, Host value or field value taken as one run must
    // reach the offset limit exactly where per-byte parsing would: a run that
    // fits (one below, at the limit) is accepted, one byte more is too large.
    const prefixes = [_][]const u8{
        "GET /",
        "GET / HTTP/1.1\r\nX",
        "GET / HTTP/1.1\r\nHost: e",
        "GET / HTTP/1.1\r\nX: v",
    };
    const run = "abcdefgh";
    for (prefixes) |prefix| {
        for ([_]usize{ run.len + 1, run.len, run.len - 1 }) |remaining| {
            var parser = Parser{};
            try expectNeedMore(parser.feed(prefix));
            parser.offset = std.math.maxInt(u32) - @as(u32, @intCast(remaining));
            const result = parser.feed(run);
            if (remaining >= run.len) {
                try expectNeedMore(result);
                try std.testing.expectEqual(std.math.maxInt(u32) - @as(u32, @intCast(remaining - run.len)), parser.offset);
            } else {
                try expectError(ParseError.input_too_large, result);
                try std.testing.expectEqual(std.math.maxInt(u32), parser.offset);
            }
        }
    }
}

test "a method or version taken in one step stops at the u32 offset boundary" {
    // The method with its space, and the version with its CR, end at the
    // limit (accepted), one byte before it, or one byte past it (too large).
    const cases = [_]struct { prefix: []const u8, run: []const u8 }{
        .{ .prefix = "", .run = "GET " },
        .{ .prefix = "GET / ", .run = "HTTP/1.1\r" },
    };
    for (cases) |case| {
        for ([_]usize{ case.run.len + 1, case.run.len, case.run.len - 1 }) |remaining| {
            var parser = Parser{};
            if (case.prefix.len != 0) try expectNeedMore(parser.feed(case.prefix));
            parser.offset = std.math.maxInt(u32) - @as(u32, @intCast(remaining));
            const result = parser.feed(case.run);
            if (remaining >= case.run.len) {
                try expectNeedMore(result);
                try std.testing.expectEqual(std.math.maxInt(u32) - @as(u32, @intCast(remaining - case.run.len)), parser.offset);
            } else {
                try expectError(ParseError.input_too_large, result);
            }
        }
    }
}

test "Parser completes at the u32 boundary without counting suffix bytes" {
    var parser = Parser{};
    try expectNeedMore(parser.feed("GET / HTTP/1.1\r\nHost: x\r\n"));

    parser.offset = std.math.maxInt(u32) - 2;
    const input = "\r\nBODY";
    try expectHeadComplete(
        std.math.maxInt(u32),
        2,
        parser.feed(input),
    );
}

test "Parser method classification covers every byte" {
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        var input = "X / HTTP/1.0\r\n\r\n".*;
        input[0] = byte;

        try expectAcceptance(
            isExpectedToken(byte),
            http1.parseAll(&input),
        );
    }
}

test "Parser header name classification covers every byte" {
    const name_offset = "GET / HTTP/1.0\r\n".len;

    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        var input = "GET / HTTP/1.0\r\nX: value\r\n\r\n".*;
        input[name_offset] = byte;

        try expectAcceptance(
            isExpectedToken(byte),
            http1.parseAll(&input),
        );
    }
}

test "Parser field value classification covers every byte" {
    const value_offset = "GET / HTTP/1.0\r\nX: ".len;

    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        var input = "GET / HTTP/1.0\r\nX: X\r\n\r\n".*;
        input[value_offset] = byte;

        try expectAcceptance(
            isExpectedFieldValue(byte),
            http1.parseAll(&input),
        );
    }
}

test "Parser handles a 64KiB field value and rejects a corrupt final byte" {
    const prefix = "GET / HTTP/1.0\r\nX: ";
    const suffix = "\r\n\r\n";
    const value_length = 64 * 1024;
    var input = (prefix ++ (&@as([value_length]u8, @splat('a'))) ++ suffix).*;

    try expectHeadComplete(
        @intCast(input.len),
        input.len,
        http1.parseAll(&input),
    );

    input[prefix.len + value_length - 1] = 0;
    try expectError(
        ParseError.invalid_header_value,
        http1.parseAll(&input),
    );
}

test "Parser copies a finished parse and starts over after reset" {
    const head = "GET /a HTTP/1.1\r\nHost: x\r\nAccept: */*\r\n\r\n";
    var parser = Parser{};
    _ = parser.feed(head);
    try std.testing.expect(parser.isComplete());

    var copy = Parser{};
    copy.copyFrom(&parser);
    try std.testing.expect(copy.isComplete());
    try std.testing.expectEqual(@as(usize, 2), copy.headers().len);
    try std.testing.expectEqualStrings("Accept", copy.headers()[1].name.slice(head));
    try expectHeadComplete(head.len, 0, copy.feed(head));

    parser.reset();
    try std.testing.expect(!parser.isComplete());
    try std.testing.expectEqual(@as(usize, 0), parser.headers().len);
    try expectHeadComplete(head.len, head.len, parser.feed(head));
    try std.testing.expectEqual(@as(usize, 2), parser.headers().len);
}
