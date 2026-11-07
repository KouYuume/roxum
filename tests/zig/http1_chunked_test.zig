const std = @import("std");
const chunked = @import("http1_chunked");

const Completion = chunked.Completion;
const DecodeError = chunked.DecodeError;
const Decoder = chunked.Decoder;
const FeedResultTag = chunked.FeedResultTag;

const Output = struct {
    bytes: [256]u8 = undefined,
    length: usize = 0,

    fn append(self: *Output, bytes: []const u8) !void {
        if (bytes.len > self.bytes.len - self.length) {
            return error.OutputTooLarge;
        }
        @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
        self.length += bytes.len;
    }

    fn slice(self: *const Output) []const u8 {
        return self.bytes[0..self.length];
    }
};

const DriveResult = struct {
    consumed: usize,
    completion: ?Completion,
};

fn driveSlice(
    decoder: *Decoder,
    input: []const u8,
    output: *Output,
) !DriveResult {
    var position: usize = 0;
    while (position < input.len) {
        const result = decoder.feed(input[position..]);
        switch (result) {
            .need_more => |progress| {
                try std.testing.expect(progress.consumed > 0);
                position += progress.consumed;
            },
            .data => |data| {
                try std.testing.expect(data.consumed > 0);
                try output.append(data.bytes);
                position += data.consumed;
            },
            .complete => |completion| {
                position += completion.consumed;
                return .{
                    .consumed = position,
                    .completion = completion,
                };
            },
            .err => return error.UnexpectedDecodeError,
        }
    }
    return .{
        .consumed = position,
        .completion = null,
    };
}

fn expectDecodeError(expected: DecodeError, input: []const u8) !void {
    var decoder = Decoder{};
    var position: usize = 0;

    while (position < input.len) {
        const result = decoder.feed(input[position..]);
        switch (result) {
            .need_more => |progress| position += progress.consumed,
            .data => |data| position += data.consumed,
            .complete => return error.UnexpectedCompletion,
            .err => |actual| {
                try std.testing.expectEqual(expected, actual);
                return;
            },
        }
    }
    return error.MissingDecodeError;
}

test "Decoder decodes multiple chunks without copying syntax bytes" {
    const input = "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n";
    var decoder = Decoder{};
    var output = Output{};

    const result = try driveSlice(&decoder, input, &output);
    const completion = result.completion orelse
        return error.MissingCompletion;

    try std.testing.expectEqual(input.len, result.consumed);
    try std.testing.expectEqualStrings("Wikipedia", output.slice());
    try std.testing.expectEqual(@as(u64, 9), completion.decoded_length);
    try std.testing.expectEqual(@as(usize, 0), completion.trailer_count);
}

test "Decoder result is independent of every split position" {
    const input =
        "4; foo=bar; note=\"a,b\\\"c\"; bare\r\nWiki\r\n" ++
        "5\r\npedia\r\n" ++
        "0; finished=yes\r\n" ++
        "Digest: abc\r\n" ++
        "Host-Extra: allowed\r\n" ++
        "X-Trace:\t complete \t\r\n" ++
        "\r\n";

    for (0..input.len + 1) |split| {
        var decoder = Decoder{};
        var output = Output{};

        const first = try driveSlice(&decoder, input[0..split], &output);
        if (first.completion) |completion| {
            try std.testing.expectEqual(input.len, split);
            try std.testing.expectEqual(@as(u64, 9), completion.decoded_length);
            try std.testing.expectEqual(@as(usize, 3), completion.trailer_count);
        } else {
            const second = try driveSlice(&decoder, input[split..], &output);
            const completion = second.completion orelse
                return error.MissingCompletion;
            try std.testing.expectEqual(@as(u64, 9), completion.decoded_length);
            try std.testing.expectEqual(@as(usize, 3), completion.trailer_count);
        }

        try std.testing.expectEqualStrings("Wikipedia", output.slice());
    }
}

test "chunk size covers the u64 hexadecimal overflow boundary" {
    const Case = struct {
        input: []const u8,
        expected: u64,
    };
    const valid = [_]Case{
        .{ .input = "FFFFFFFFFFFFFFFE\r\n", .expected = std.math.maxInt(u64) - 1 },
        .{ .input = "FFFFFFFFFFFFFFFF\r\n", .expected = std.math.maxInt(u64) },
    };

    for (valid) |case| {
        var decoder = Decoder{};
        const result = decoder.feed(case.input);
        try std.testing.expectEqual(
            FeedResultTag.need_more,
            std.meta.activeTag(result),
        );
        try std.testing.expectEqual(case.expected, decoder.remainingInChunk());
    }

    try expectDecodeError(
        DecodeError.chunk_size_overflow,
        "10000000000000000\r\n",
    );
}

test "Decoder rejects malformed chunk sizes" {
    const cases = [_][]const u8{
        "\r\n",
        "x\r\n",
        "+1\r\n",
        "1G\r\n",
        "1\n",
    };

    for (cases) |input| {
        const expected = if (std.mem.endsWith(u8, input, "\n") and
            !std.mem.endsWith(u8, input, "\r\n"))
            DecodeError.invalid_line_ending
        else
            DecodeError.invalid_chunk_size;
        try expectDecodeError(expected, input);
    }
}

test "Decoder rejects decoded length overflow before exposing data" {
    var decoder = Decoder{
        .decoded_length = std.math.maxInt(u64),
    };

    const result = decoder.feed("1\r\n");
    try std.testing.expectEqual(
        FeedResultTag.err,
        std.meta.activeTag(result),
    );
    try std.testing.expectEqual(
        DecodeError.decoded_length_overflow,
        result.err,
    );
}

test "Decoder requires CRLF after every non-final chunk" {
    const cases = [_][]const u8{
        "1\r\naX",
        "1\r\na\rX",
        "1\r\na\n",
    };

    for (cases) |input| {
        try expectDecodeError(
            DecodeError.invalid_chunk_terminator,
            input,
        );
    }
}

test "Decoder validates chunk extension syntax while discarding values" {
    const cases = [_][]const u8{
        "1;\r\na\r\n0\r\n\r\n",
        "1; name=\r\na\r\n0\r\n\r\n",
        "1; name=\"unterminated\r\na\r\n0\r\n\r\n",
        "1; bad(name=x\r\na\r\n0\r\n\r\n",
        "1; name=\"bad\\\x01\"\r\na\r\n0\r\n\r\n",
        "1 \r\na\r\n0\r\n\r\n",
        "1; name \r\na\r\n0\r\n\r\n",
        "1; name=x \r\na\r\n0\r\n\r\n",
        "1; name=\"x\" \r\na\r\n0\r\n\r\n",
    };

    for (cases) |input| {
        expectDecodeError(
            DecodeError.invalid_chunk_extension,
            input,
        ) catch |err| {
            std.debug.print("unexpected chunk extension result: {x}\n", .{input});
            return err;
        };
    }
}

test "Decoder accepts BWS only when followed by its extension delimiter" {
    const valid = [_][]const u8{
        "1; bare\r\na\r\n0\r\n\r\n",
        "1; bare ; next\r\na\r\n0\r\n\r\n",
        "1 ; name = x ; next\r\na\r\n0\r\n\r\n",
        "1; name=\"quoted\"\r\na\r\n0\r\n\r\n",
    };

    for (valid) |input| {
        var decoder = Decoder{};
        var output = Output{};

        const result = try driveSlice(&decoder, input, &output);
        _ = result.completion orelse return error.MissingCompletion;
        try std.testing.expectEqualStrings("a", output.slice());
    }
}

test "Decoder rejects fields that cannot safely appear in trailers" {
    const names = [_][]const u8{
        "Transfer-Encoding",
        "Content-Length",
        "Host",
        "hOsT",
        "Trailer",
        "Connection",
        "Keep-Alive",
        "TE",
        "Upgrade",
        "Proxy-Connection",
        "Authorization",
        "Proxy-Authorization",
        "Proxy-Authenticate",
        "WWW-Authenticate",
        "Expect",
        "Max-Forwards",
        "Range",
        "If-Match",
        "If-None-Match",
        "If-Modified-Since",
        "If-Unmodified-Since",
        "If-Range",
        "Content-Encoding",
        "Content-Type",
        "Content-Range",
        "Cache-Control",
    };

    for (names) |name| {
        var buffer: [128]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &buffer,
            "0\r\n{s}: forbidden\r\n\r\n",
            .{name},
        );
        try expectDecodeError(DecodeError.forbidden_trailer, input);
    }
}

test "Decoder rejects malformed trailer lines" {
    const Case = struct {
        input: []const u8,
        expected: DecodeError,
    };
    const cases = [_]Case{
        .{
            .input = "0\r\n Bad: value\r\n\r\n",
            .expected = DecodeError.obsolete_line_folding,
        },
        .{
            .input = "0\r\nBad Name: value\r\n\r\n",
            .expected = DecodeError.invalid_trailer_name,
        },
        .{
            .input = "0\r\n: value\r\n\r\n",
            .expected = DecodeError.invalid_trailer_name,
        },
        .{
            .input = "0\r\nX: bad\x01value\r\n\r\n",
            .expected = DecodeError.invalid_trailer_value,
        },
        .{
            .input = "0\r\nX: value\n\n",
            .expected = DecodeError.invalid_line_ending,
        },
    };

    for (cases) |case| {
        try expectDecodeError(case.expected, case.input);
    }
}

test "Decoder stops before suffix and reset restores initial state" {
    const encoded = "1\r\na\r\n0\r\n\r\n";
    const input = encoded ++ "NEXT";
    var decoder = Decoder{};
    var output = Output{};

    const decoded = try driveSlice(&decoder, input, &output);
    try std.testing.expect(decoded.completion != null);
    try std.testing.expectEqual(encoded.len, decoded.consumed);
    try std.testing.expectEqualStrings("a", output.slice());

    const terminal = decoder.feed("NEXT");
    try std.testing.expectEqual(
        FeedResultTag.complete,
        std.meta.activeTag(terminal),
    );
    try std.testing.expectEqual(@as(usize, 0), terminal.complete.consumed);

    decoder.reset();
    output = Output{};
    const second = try driveSlice(&decoder, encoded, &output);
    try std.testing.expect(second.completion != null);
    try std.testing.expectEqualStrings("a", output.slice());
}
