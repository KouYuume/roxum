const std = @import("std");
const http1 = @import("http1_parser");

const maximum_input_length: usize = 16 * 1024;

const ChunkMode = enum {
    whole,
    bytewise,
    irregular,
};

const Run = struct {
    parser: http1.Parser,
    result: http1.FeedResult,
    input_length: usize,
    wire_consumed: ?usize,
};

test "HTTP parser is robust and split-independent" {
    try std.testing.fuzz(
        {},
        testInput,
        .{
            .corpus = &.{
                smithSlice(""),
                smithSlice("GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                smithSlice("GET / HTTP/1.1\r\nHost: x\r\n"),
                smithSlice("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n"),
                smithSlice("GET / HTTP/1.1\nHost: x\n\n"),
                smithSlice("GET / HTTP/1.1\r\nHost: x\r\nX-Test: \x00\r\n\r\n"),
                smithSlice(@embedFile("corpus/http1_parser/bare-lf.http")),
                smithSlice(@embedFile("corpus/http1_parser/truncated.http")),
                smithSlice(@embedFile("corpus/http1_parser/request-smuggling.http")),
            },
        },
    );
}

fn testInput(
    _: void,
    smith: *std.testing.Smith,
) !void {
    var storage: [maximum_input_length]u8 = undefined;
    const length: usize = smith.slice(&storage);
    const input = storage[0..length];

    const whole = run(input, ChunkMode.whole);
    const bytewise = run(input, ChunkMode.bytewise);
    const irregular = run(input, ChunkMode.irregular);

    expectEquivalent(&whole, &bytewise) catch |err| {
        reportFailure("bytewise", input, &whole, &bytewise);
        return err;
    };
    expectEquivalent(&whole, &irregular) catch |err| {
        reportFailure("irregular", input, &whole, &irregular);
        return err;
    };
}

fn run(
    input: []const u8,
    chunk_mode: ChunkMode,
) Run {
    var parser = http1.Parser{};

    if (input.len == 0 or chunk_mode == ChunkMode.whole) {
        const result = parser.feed(input);
        return .{
            .parser = parser,
            .result = result,
            .input_length = input.len,
            .wire_consumed = consumedAtCompletion(result, 0),
        };
    }

    var result = http1.FeedResult{ .need_more = {} };
    var offset: usize = 0;
    var wire_consumed: ?usize = null;

    while (offset < input.len) {
        const chunk_length = switch (chunk_mode) {
            ChunkMode.whole => unreachable,
            ChunkMode.bytewise => 1,
            ChunkMode.irregular => @min(
                @as(usize, input[offset] % 64) + 1,
                input.len - offset,
            ),
        };

        result = parser.feed(input[offset .. offset + chunk_length]);
        if (std.meta.activeTag(result) != http1.FeedResultTag.need_more) {
            wire_consumed = consumedAtCompletion(result, offset);
            break;
        }
        offset += chunk_length;
    }

    return .{
        .parser = parser,
        .result = result,
        .input_length = input.len,
        .wire_consumed = wire_consumed,
    };
}

fn consumedAtCompletion(
    result: http1.FeedResult,
    offset: usize,
) ?usize {
    return switch (result) {
        http1.FeedResult.head_complete => |completion| offset + completion.consumed,
        http1.FeedResult.need_more, http1.FeedResult.err => null,
    };
}

fn reportFailure(
    mode: []const u8,
    input: []const u8,
    expected: *const Run,
    actual: *const Run,
) void {
    std.debug.print(
        "incremental mismatch ({s}), whole={s}, split={s}, input={x}\n",
        .{
            mode,
            @tagName(std.meta.activeTag(expected.result)),
            @tagName(std.meta.activeTag(actual.result)),
            input,
        },
    );
}

fn expectEquivalent(
    expected: *const Run,
    actual: *const Run,
) !void {
    const expected_tag = std.meta.activeTag(expected.result);
    const actual_tag = std.meta.activeTag(actual.result);
    try std.testing.expectEqual(expected_tag, actual_tag);

    switch (expected_tag) {
        http1.FeedResultTag.need_more => {},
        http1.FeedResultTag.head_complete => {
            // `consumed` is relative to the current feed call, so it is
            // intentionally different for whole and split input.
            try std.testing.expectEqual(
                expected.result.head_complete.head_length,
                actual.result.head_complete.head_length,
            );
            try std.testing.expectEqual(
                expected.wire_consumed,
                actual.wire_consumed,
            );
            try expectValidSpans(expected);
            try expectValidSpans(actual);
        },
        http1.FeedResultTag.err => {
            try std.testing.expectEqual(
                expected.result.err,
                actual.result.err,
            );
        },
    }

    try std.testing.expectEqualDeep(
        expected.parser.requestLine(),
        actual.parser.requestLine(),
    );
    try std.testing.expectEqualDeep(
        expected.parser.headers(),
        actual.parser.headers(),
    );
    try std.testing.expectEqualDeep(
        expected.parser.bodyFraming(),
        actual.parser.bodyFraming(),
    );
}

fn expectValidSpans(run_result: *const Run) !void {
    const head_length: usize = run_result.result.head_complete.head_length;
    try std.testing.expect(head_length <= run_result.input_length);
    try std.testing.expectEqual(
        @as(?usize, head_length),
        run_result.wire_consumed,
    );

    const request_line = run_result.parser.requestLine() orelse
        return error.MissingRequestLine;

    try expectSpanWithin(request_line.method, head_length);
    try expectSpanWithin(request_line.target, head_length);
    for (run_result.parser.headers()) |header| {
        try expectSpanWithin(header.name, head_length);
        try expectSpanWithin(header.value, head_length);
    }
    try std.testing.expect(run_result.parser.bodyFraming() != null);
}

fn expectSpanWithin(span: http1.Span, limit: usize) !void {
    const start: usize = span.start;
    const length: usize = span.len;
    try std.testing.expect(start <= limit);
    try std.testing.expect(length <= limit - start);
}

fn smithSlice(comptime input: []const u8) []const u8 {
    return &[_]u8{
        @truncate(input.len),
        @truncate(input.len >> 8),
        @truncate(input.len >> 16),
        @truncate(input.len >> 24),
    } ++ input;
}
