const std = @import("std");
const parser = @import("parser.zig");

pub const Decision = enum {
    none,
    send_continue,
    unsupported,
};

pub fn decide(
    version: parser.HttpVersion,
    headers: []const parser.Header,
    head_bytes: []const u8,
    framing: parser.BodyFraming,
) Decision {
    var found = false;

    for (headers) |header| {
        const name = header.name.slice(head_bytes);
        if (!std.ascii.eqlIgnoreCase(name, "expect")) continue;

        const field_has_continue = parseContinueList(header.value.slice(head_bytes)) orelse
            return Decision.unsupported;
        found = found or field_has_continue;
    }

    if (!found) return Decision.none;
    if (version != parser.HttpVersion.http_1_1) return Decision.none;
    if (!hasRequestContent(framing)) return Decision.none;
    return Decision.send_continue;
}

// null denotes an unsupported nonempty expectation; false is an empty list.
fn parseContinueList(value: []const u8) ?bool {
    var found = false;
    var elements = std.mem.splitScalar(u8, value, ',');
    while (elements.next()) |element| {
        const item = std.mem.trim(u8, element, " \t");
        if (item.len == 0) continue;
        if (!std.ascii.eqlIgnoreCase(item, "100-continue")) return null;
        found = true;
    }
    return found;
}

fn hasRequestContent(framing: parser.BodyFraming) bool {
    return switch (framing) {
        parser.BodyFraming.none => false,
        parser.BodyFraming.content_length => |length| length != 0,
        parser.BodyFraming.chunked => true,
    };
}

test "expectation decisions cover request content boundaries" {
    const cases = [_]struct {
        request: []const u8,
        expected: Decision,
    }{
        .{
            .request = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n",
            .expected = Decision.none,
        },
        .{
            .request = "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 0\r\n\r\n",
            .expected = Decision.none,
        },
        .{
            .request = "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n",
            .expected = Decision.send_continue,
        },
        .{
            .request = "POST / HTTP/1.1\r\nHost: x\r\nExpect: custom\r\nContent-Length: 1\r\n\r\n",
            .expected = Decision.unsupported,
        },
        .{
            .request = "POST / HTTP/1.0\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n",
            .expected = Decision.none,
        },
        .{
            .request = "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nTransfer-Encoding: chunked\r\n\r\n",
            .expected = Decision.send_continue,
        },
    };

    for (cases) |case| {
        var request_parser = parser.Parser{};
        const result = request_parser.feed(case.request);
        const completion = switch (result) {
            parser.FeedResult.head_complete => |value| value,
            else => return error.UnexpectedParseResult,
        };
        try std.testing.expectEqual(
            case.expected,
            decide(
                request_parser.requestLine().?.version,
                request_parser.headers(),
                case.request[0..completion.head_length],
                request_parser.bodyFraming().?,
            ),
        );
    }
}

test "expectation accepts case and repeated-list variants" {
    const values = [_][]const u8{
        "100-continue",
        "100-CONTINUE",
        "100-continue, 100-continue",
        ",100-continue,",
        "100-continue,, 100-continue",
    };

    for (values) |value| {
        try std.testing.expectEqual(@as(?bool, true), parseContinueList(value));
    }
    try std.testing.expectEqual(@as(?bool, false), parseContinueList(""));
    try std.testing.expectEqual(@as(?bool, true), parseContinueList("100-continue,"));
    try std.testing.expectEqual(@as(?bool, null), parseContinueList("100-continue, custom"));
}
