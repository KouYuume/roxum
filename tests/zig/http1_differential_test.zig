const std = @import("std");
const http1 = @import("http1_parser");

const fixture = @embedFile("fixtures/http1_differential.tsv");

test "roxum outcomes match the pinned differential fixture" {
    var lines = std.mem.splitScalar(u8, fixture, '\n');
    var line_number: usize = 0;

    while (lines.next()) |line| {
        line_number += 1;
        if (line.len == 0 or line[0] == '#') continue;

        var columns = std.mem.splitScalar(u8, line, '\t');
        const name = columns.next() orelse return error.InvalidFixture;
        _ = columns.next() orelse return error.InvalidFixture;
        const expected = columns.next() orelse return error.InvalidFixture;
        _ = columns.next() orelse return error.InvalidFixture;
        const encoded = columns.next() orelse return error.InvalidFixture;
        if (columns.next() != null) return error.InvalidFixture;

        var input_storage: [16 * 1024]u8 = undefined;
        const input = try decodeHex(encoded, &input_storage);
        const result = http1.parseAll(input);

        expectOutcome(expected, result) catch |err| {
            std.debug.print(
                "differential fixture {d} ({s}) failed\n",
                .{ line_number, name },
            );
            return err;
        };
    }
}

fn expectOutcome(
    expected: []const u8,
    result: http1.FeedResult,
) !void {
    const tag = std.meta.activeTag(result);

    if (std.mem.eql(u8, expected, "complete")) {
        try std.testing.expectEqual(
            http1.FeedResultTag.head_complete,
            tag,
        );
        return;
    }
    if (std.mem.eql(u8, expected, "partial")) {
        try std.testing.expectEqual(
            http1.FeedResultTag.need_more,
            tag,
        );
        return;
    }

    const reject_prefix = "reject:";
    if (!std.mem.startsWith(u8, expected, reject_prefix)) {
        return error.InvalidFixture;
    }

    try std.testing.expectEqual(http1.FeedResultTag.err, tag);
    try std.testing.expectEqualStrings(
        expected[reject_prefix.len..],
        @tagName(result.err),
    );
}

fn decodeHex(
    encoded: []const u8,
    output: []u8,
) ![]const u8 {
    if (encoded.len % 2 != 0) return error.InvalidFixture;
    const decoded_length = encoded.len / 2;
    if (decoded_length > output.len) return error.InvalidFixture;

    for (0..decoded_length) |index| {
        output[index] = try std.fmt.parseInt(
            u8,
            encoded[index * 2 .. index * 2 + 2],
            16,
        );
    }
    return output[0..decoded_length];
}

test "decodeHex covers empty, byte, and invalid boundaries" {
    var storage: [2]u8 = undefined;

    try std.testing.expectEqual(
        @as(usize, 0),
        (try decodeHex("", &storage)).len,
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{0xff},
        try decodeHex("ff", &storage),
    );
    try std.testing.expectError(
        error.InvalidFixture,
        decodeHex("f", &storage),
    );
    try std.testing.expectError(
        error.InvalidCharacter,
        decodeHex("gg", &storage),
    );
    try std.testing.expectError(
        error.InvalidFixture,
        decodeHex("000000", &storage),
    );
}
