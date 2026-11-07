const std = @import("std");
const http1 = @import("http1_parser");

const HttparseOutcome = union(enum) {
    complete: usize,
    partial,
    reject,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;

    const fixture = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        std.Io.Limit.limited(16 * 1024 * 1024),
    );

    var verified: usize = 0;
    var lines = std.mem.splitScalar(u8, fixture, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        var columns = std.mem.splitScalar(u8, line, '\t');
        const httparse_outcome_text = columns.next() orelse
            return error.InvalidFixture;
        const httparse_outcome = try parseHttparseOutcome(
            httparse_outcome_text,
        );
        const encoded = columns.next() orelse
            return error.InvalidFixture;
        if (columns.next() != null) return error.InvalidFixture;

        var input_storage: [16 * 1024]u8 = undefined;
        const input = try decodeHex(encoded, &input_storage);
        const roxum_result = http1.parseAll(input);
        const roxum_tag = std.meta.activeTag(roxum_result);

        const unsafe_difference = switch (httparse_outcome) {
            HttparseOutcome.complete => |httparse_consumed| switch (roxum_result) {
                http1.FeedResult.head_complete => |roxum_completion| roxum_completion.head_length != httparse_consumed,
                http1.FeedResult.need_more, http1.FeedResult.err => false,
            },
            HttparseOutcome.partial => roxum_tag == http1.FeedResultTag.head_complete,
            HttparseOutcome.reject => roxum_tag != http1.FeedResultTag.err,
        };
        if (unsafe_difference) {
            std.debug.print(
                "unsafe differential: httparse={s}, roxum={s}, input={x}\n",
                .{ httparse_outcome_text, @tagName(roxum_tag), input },
            );
            return error.UnsafeParserDifference;
        }
        verified += 1;
    }

    std.debug.print("verified {d} generated differential mutations\n", .{verified});
}

fn parseHttparseOutcome(text: []const u8) !HttparseOutcome {
    const complete_prefix = "complete:";
    if (std.mem.startsWith(u8, text, complete_prefix)) {
        const consumed = std.fmt.parseInt(
            usize,
            text[complete_prefix.len..],
            10,
        ) catch return error.InvalidFixture;
        return HttparseOutcome{ .complete = consumed };
    }
    if (std.mem.eql(u8, text, "partial")) return HttparseOutcome.partial;
    if (std.mem.eql(u8, text, "reject")) return HttparseOutcome.reject;
    return error.InvalidFixture;
}

fn decodeHex(encoded: []const u8, output: []u8) ![]const u8 {
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
