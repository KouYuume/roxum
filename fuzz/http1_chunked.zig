const std = @import("std");
const chunked = @import("http1_chunked");

const maximum_input_length: usize = 16 * 1024;

const ChunkMode = enum {
    whole,
    bytewise,
    irregular,
};

const OutcomeTag = enum {
    need_more,
    complete,
    err,
};

const Outcome = struct {
    tag: OutcomeTag,
    decode_error: ?chunked.DecodeError = null,
    data_length: usize,
    decoded_length: ?u64 = null,
    trailer_count: ?usize = null,
    remaining_in_chunk: u64,
    wire_consumed: ?usize = null,
};

const Run = struct {
    outcome: Outcome,
    decoded_bytes: [maximum_input_length]u8,
};

test "chunked decoder is robust and split-independent" {
    try std.testing.fuzz(
        {},
        testInput,
        .{
            .corpus = &.{
                smithSlice(""),
                smithSlice("0\r\n\r\n"),
                smithSlice("4\r\nWiki\r\n0\r\n\r\n"),
                smithSlice("1 ; name = value\r\na\r\n0\r\n\r\n"),
                smithSlice("1 \r\na\r\n0\r\n\r\n"),
                smithSlice("FFFFFFFFFFFFFFFF\r\n"),
                smithSlice("0\r\nHost: forbidden\r\n\r\n"),
            },
        },
    );
}

fn testInput(
    _: void,
    smith: *std.testing.Smith,
) !void {
    var storage: [maximum_input_length]u8 = undefined;
    const length = smith.slice(&storage);
    const input = storage[0..length];

    const whole = try drive(input, ChunkMode.whole);
    const bytewise = try drive(input, ChunkMode.bytewise);
    const irregular = try drive(input, ChunkMode.irregular);

    try expectEquivalent(&whole, &bytewise);
    try expectEquivalent(&whole, &irregular);
}

fn drive(input: []const u8, mode: ChunkMode) !Run {
    var decoder = chunked.Decoder{};
    var decoded_bytes: [maximum_input_length]u8 = undefined;
    var data_length: usize = 0;
    var offset: usize = 0;

    while (offset < input.len) {
        const outer_length = switch (mode) {
            ChunkMode.whole => input.len - offset,
            ChunkMode.bytewise => 1,
            ChunkMode.irregular => @min(
                @as(usize, input[offset] % 64) + 1,
                input.len - offset,
            ),
        };
        const outer = input[offset .. offset + outer_length];
        var inner_offset: usize = 0;

        while (inner_offset < outer.len) {
            const result = decoder.feed(outer[inner_offset..]);
            switch (result) {
                chunked.FeedResult.need_more => |progress| {
                    try expectProgress(progress.consumed, outer.len - inner_offset);
                    inner_offset += progress.consumed;
                },
                chunked.FeedResult.data => |data| {
                    try expectProgress(data.consumed, outer.len - inner_offset);
                    try std.testing.expect(
                        data_length <= maximum_input_length - data.bytes.len,
                    );
                    @memcpy(
                        decoded_bytes[data_length .. data_length + data.bytes.len],
                        data.bytes,
                    );
                    data_length += data.bytes.len;
                    inner_offset += data.consumed;
                },
                chunked.FeedResult.complete => |completion| {
                    try std.testing.expect(
                        completion.consumed <= outer.len - inner_offset,
                    );
                    try std.testing.expectEqual(
                        @as(u64, @intCast(data_length)),
                        completion.decoded_length,
                    );
                    return Run{
                        .outcome = .{
                            .tag = OutcomeTag.complete,
                            .data_length = data_length,
                            .decoded_length = completion.decoded_length,
                            .trailer_count = completion.trailer_count,
                            .remaining_in_chunk = decoder.remainingInChunk(),
                            .wire_consumed = offset + inner_offset + completion.consumed,
                        },
                        .decoded_bytes = decoded_bytes,
                    };
                },
                chunked.FeedResult.err => |decode_error| return Run{
                    .outcome = .{
                        .tag = OutcomeTag.err,
                        .decode_error = decode_error,
                        .data_length = data_length,
                        .remaining_in_chunk = decoder.remainingInChunk(),
                    },
                    .decoded_bytes = decoded_bytes,
                },
            }
        }
        offset += outer_length;
    }

    return Run{
        .outcome = .{
            .tag = OutcomeTag.need_more,
            .data_length = data_length,
            .remaining_in_chunk = decoder.remainingInChunk(),
        },
        .decoded_bytes = decoded_bytes,
    };
}

fn expectEquivalent(expected: *const Run, actual: *const Run) !void {
    try std.testing.expectEqualDeep(expected.outcome, actual.outcome);
    try std.testing.expectEqualSlices(
        u8,
        expected.decoded_bytes[0..expected.outcome.data_length],
        actual.decoded_bytes[0..actual.outcome.data_length],
    );
}

fn expectProgress(consumed: usize, available: usize) !void {
    try std.testing.expect(consumed > 0);
    try std.testing.expect(consumed <= available);
}

fn smithSlice(comptime input: []const u8) []const u8 {
    return &[_]u8{
        @truncate(input.len),
        @truncate(input.len >> 8),
        @truncate(input.len >> 16),
        @truncate(input.len >> 24),
    } ++ input;
}
