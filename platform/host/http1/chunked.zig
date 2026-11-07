const std = @import("std");
const syntax = @import("syntax.zig");

pub const FeedResultTag = enum {
    need_more,
    data,
    complete,
    err,
};

pub const Progress = struct {
    consumed: usize,
};

pub const Data = struct {
    bytes: []const u8,
    consumed: usize,
};

pub const Completion = struct {
    consumed: usize,
    decoded_length: u64,
    trailer_count: usize,
};

pub const DecodeError = enum {
    invalid_chunk_size,
    chunk_size_overflow,
    decoded_length_overflow,
    invalid_chunk_extension,
    invalid_chunk_terminator,
    invalid_line_ending,
    invalid_trailer_name,
    invalid_trailer_value,
    obsolete_line_folding,
    forbidden_trailer,
};

pub const FeedResult = union(FeedResultTag) {
    need_more: Progress,
    data: Data,
    complete: Completion,
    err: DecodeError,
};

const State = enum {
    chunk_size,
    after_chunk_size,
    before_extension_name,
    extension_name,
    after_extension_name,
    before_extension_value,
    extension_token,
    extension_quoted,
    extension_quoted_escape,
    after_extension_value,
    extension_value_bws,
    chunk_size_lf,
    chunk_data,
    chunk_data_cr,
    chunk_data_lf,
    trailer_line_start,
    trailer_name,
    trailer_value_leading_ows,
    trailer_value,
    trailer_line_lf,
    trailer_end_lf,
    done,
    failed,
};

const forbidden_trailer_names = [_][]const u8{
    "transfer-encoding",
    "content-length",
    "host",
    "trailer",
    "connection",
    "keep-alive",
    "te",
    "upgrade",
    "proxy-connection",
    "authorization",
    "proxy-authorization",
    "proxy-authenticate",
    "www-authenticate",
    "expect",
    "max-forwards",
    "range",
    "if-match",
    "if-none-match",
    "if-modified-since",
    "if-unmodified-since",
    "if-range",
    "content-encoding",
    "content-type",
    "content-range",
    "cache-control",
};

const TrailerNameMatcher = struct {
    const all_candidates = (@as(u32, 1) << forbidden_trailer_names.len) - 1;

    candidates: u32 = all_candidates,
    length: usize = 0,

    fn reset(self: *TrailerNameMatcher) void {
        self.* = TrailerNameMatcher{};
    }

    fn consume(self: *TrailerNameMatcher, byte: u8) void {
        inline for (forbidden_trailer_names, 0..) |name, index| {
            const mask = @as(u32, 1) << index;
            if ((self.candidates & mask) != 0 and
                !matchesAt(name, self.length, byte))
            {
                self.candidates &= ~mask;
            }
        }
        self.length += 1;
    }

    fn isForbidden(self: *const TrailerNameMatcher) bool {
        inline for (forbidden_trailer_names, 0..) |name, index| {
            const mask = @as(u32, 1) << index;
            if ((self.candidates & mask) != 0 and self.length == name.len) return true;
        }
        return false;
    }
};

pub const Decoder = struct {
    state: State = State.chunk_size,
    failure: ?DecodeError = null,

    current_chunk_size: u64 = 0,
    saw_size_digit: bool = false,
    chunk_remaining: u64 = 0,
    decoded_length: u64 = 0,

    trailer_name: TrailerNameMatcher = .{},
    trailer_count: usize = 0,

    pub fn feed(self: *Decoder, bytes: []const u8) FeedResult {
        if (self.state == State.done) return self.completed(0);
        if (self.state == State.failed) return .{ .err = self.failure.? };

        var index: usize = 0;
        while (index < bytes.len) {
            if (self.state == State.chunk_data) {
                const available: u64 = bytes.len - index;
                const data_length: usize = @intCast(@min(
                    self.chunk_remaining,
                    available,
                ));
                const data = bytes[index .. index + data_length];

                self.chunk_remaining -= data_length;
                self.decoded_length += data_length;
                index += data_length;
                if (self.chunk_remaining == 0) self.state = State.chunk_data_cr;

                return .{ .data = .{
                    .bytes = data,
                    .consumed = index,
                } };
            }

            const byte = bytes[index];
            index += 1;
            if (self.consumeByte(byte)) |decode_error| {
                return self.fail(decode_error);
            }
            if (self.state == State.done) return self.completed(index);
        }

        return .{ .need_more = .{ .consumed = index } };
    }

    pub fn reset(self: *Decoder) void {
        self.* = Decoder{};
    }

    pub fn remainingInChunk(self: *const Decoder) u64 {
        return self.chunk_remaining;
    }

    fn consumeByte(self: *Decoder, byte: u8) ?DecodeError {
        switch (self.state) {
            State.chunk_size => return self.consumeChunkSize(byte),
            State.after_chunk_size => return self.consumeAfterChunkSize(byte),
            State.before_extension_name => return self.consumeBeforeExtensionName(byte),
            State.extension_name => return self.consumeExtensionName(byte),
            State.after_extension_name => return self.consumeAfterExtensionName(byte),
            State.before_extension_value => return self.consumeBeforeExtensionValue(byte),
            State.extension_token => return self.consumeExtensionToken(byte),
            State.extension_quoted => return self.consumeExtensionQuoted(byte),
            State.extension_quoted_escape => return self.consumeExtensionQuotedEscape(byte),
            State.after_extension_value => return self.consumeAfterExtensionValue(byte),
            State.extension_value_bws => return self.consumeExtensionValueBws(byte),
            State.chunk_size_lf => return self.consumeChunkSizeLf(byte),
            State.chunk_data_cr => {
                if (byte != '\r') return DecodeError.invalid_chunk_terminator;
                self.state = State.chunk_data_lf;
            },
            State.chunk_data_lf => {
                if (byte != '\n') return DecodeError.invalid_chunk_terminator;
                self.resetChunkSize();
                self.state = State.chunk_size;
            },
            State.trailer_line_start => return self.consumeTrailerLineStart(byte),
            State.trailer_name => return self.consumeTrailerName(byte),
            State.trailer_value_leading_ows => return self.consumeTrailerValueLeadingOws(byte),
            State.trailer_value => return self.consumeTrailerValue(byte),
            State.trailer_line_lf => {
                if (byte != '\n') return DecodeError.invalid_line_ending;
                self.trailer_count += 1;
                self.state = State.trailer_line_start;
            },
            State.trailer_end_lf => {
                if (byte != '\n') return DecodeError.invalid_line_ending;
                self.state = State.done;
            },
            State.chunk_data, State.done, State.failed => unreachable,
        }
        return null;
    }

    fn consumeChunkSize(self: *Decoder, byte: u8) ?DecodeError {
        if (hexValue(byte)) |digit| {
            if (self.current_chunk_size >
                (std.math.maxInt(u64) - digit) / 16)
            {
                return DecodeError.chunk_size_overflow;
            }
            self.current_chunk_size = self.current_chunk_size * 16 + digit;
            self.saw_size_digit = true;
            return null;
        }

        if (!self.saw_size_digit) return DecodeError.invalid_chunk_size;
        if (syntax.isOptionalWhitespace(byte)) {
            self.state = State.after_chunk_size;
            return null;
        }
        if (byte == ';') {
            self.state = State.before_extension_name;
            return null;
        }
        if (byte == '\r') {
            self.state = State.chunk_size_lf;
            return null;
        }
        if (byte == '\n') return DecodeError.invalid_line_ending;
        return DecodeError.invalid_chunk_size;
    }

    fn consumeAfterChunkSize(self: *Decoder, byte: u8) ?DecodeError {
        if (syntax.isOptionalWhitespace(byte)) return null;
        if (byte == ';') {
            self.state = State.before_extension_name;
            return null;
        }
        if (byte == '\n') return DecodeError.invalid_line_ending;
        return DecodeError.invalid_chunk_extension;
    }

    fn consumeBeforeExtensionName(self: *Decoder, byte: u8) ?DecodeError {
        if (syntax.isOptionalWhitespace(byte)) return null;
        if (!syntax.isToken(byte)) return DecodeError.invalid_chunk_extension;
        self.state = State.extension_name;
        return null;
    }

    fn consumeExtensionName(self: *Decoder, byte: u8) ?DecodeError {
        if (syntax.isToken(byte)) return null;
        if (syntax.isOptionalWhitespace(byte)) {
            self.state = State.after_extension_name;
            return null;
        }
        if (byte == '=') {
            self.state = State.before_extension_value;
            return null;
        }
        return self.consumeExtensionEnd(byte);
    }

    fn consumeAfterExtensionName(self: *Decoder, byte: u8) ?DecodeError {
        if (syntax.isOptionalWhitespace(byte)) return null;
        if (byte == ';') {
            self.state = State.before_extension_name;
            return null;
        }
        if (byte == '=') {
            self.state = State.before_extension_value;
            return null;
        }
        if (byte == '\n') return DecodeError.invalid_line_ending;
        return DecodeError.invalid_chunk_extension;
    }

    fn consumeBeforeExtensionValue(self: *Decoder, byte: u8) ?DecodeError {
        if (syntax.isOptionalWhitespace(byte)) return null;
        if (syntax.isToken(byte)) {
            self.state = State.extension_token;
            return null;
        }
        if (byte == '"') {
            self.state = State.extension_quoted;
            return null;
        }
        return DecodeError.invalid_chunk_extension;
    }

    fn consumeExtensionToken(self: *Decoder, byte: u8) ?DecodeError {
        if (syntax.isToken(byte)) return null;
        if (syntax.isOptionalWhitespace(byte)) {
            self.state = State.extension_value_bws;
            return null;
        }
        return self.consumeExtensionEnd(byte);
    }

    fn consumeExtensionQuoted(self: *Decoder, byte: u8) ?DecodeError {
        if (byte == '"') {
            self.state = State.after_extension_value;
            return null;
        }
        if (byte == '\\') {
            self.state = State.extension_quoted_escape;
            return null;
        }
        if (!syntax.isQuotedText(byte)) return DecodeError.invalid_chunk_extension;
        return null;
    }

    fn consumeExtensionQuotedEscape(self: *Decoder, byte: u8) ?DecodeError {
        if (!syntax.isQuotedPair(byte)) return DecodeError.invalid_chunk_extension;
        self.state = State.extension_quoted;
        return null;
    }

    fn consumeAfterExtensionValue(self: *Decoder, byte: u8) ?DecodeError {
        if (syntax.isOptionalWhitespace(byte)) {
            self.state = State.extension_value_bws;
            return null;
        }
        return self.consumeExtensionEnd(byte);
    }

    fn consumeExtensionValueBws(self: *Decoder, byte: u8) ?DecodeError {
        if (syntax.isOptionalWhitespace(byte)) return null;
        if (byte == ';') {
            self.state = State.before_extension_name;
            return null;
        }
        if (byte == '\n') return DecodeError.invalid_line_ending;
        return DecodeError.invalid_chunk_extension;
    }

    fn consumeExtensionEnd(self: *Decoder, byte: u8) ?DecodeError {
        if (byte == ';') {
            self.state = State.before_extension_name;
            return null;
        }
        if (byte == '\r') {
            self.state = State.chunk_size_lf;
            return null;
        }
        if (byte == '\n') return DecodeError.invalid_line_ending;
        return DecodeError.invalid_chunk_extension;
    }

    fn consumeChunkSizeLf(self: *Decoder, byte: u8) ?DecodeError {
        if (byte != '\n') return DecodeError.invalid_line_ending;

        if (self.current_chunk_size == 0) {
            self.state = State.trailer_line_start;
            return null;
        }
        if (self.decoded_length >
            std.math.maxInt(u64) - self.current_chunk_size)
        {
            return DecodeError.decoded_length_overflow;
        }

        self.chunk_remaining = self.current_chunk_size;
        self.state = State.chunk_data;
        return null;
    }

    fn consumeTrailerLineStart(self: *Decoder, byte: u8) ?DecodeError {
        if (byte == '\r') {
            self.state = State.trailer_end_lf;
            return null;
        }
        if (byte == '\n') return DecodeError.invalid_line_ending;
        if (byte == ' ' or byte == '\t') return DecodeError.obsolete_line_folding;
        if (!syntax.isToken(byte)) return DecodeError.invalid_trailer_name;

        self.trailer_name.reset();
        self.trailer_name.consume(byte);
        self.state = State.trailer_name;
        return null;
    }

    fn consumeTrailerName(self: *Decoder, byte: u8) ?DecodeError {
        if (byte == ':') {
            if (self.trailer_name.isForbidden()) return DecodeError.forbidden_trailer;
            self.state = State.trailer_value_leading_ows;
            return null;
        }
        if (byte == '\n') return DecodeError.invalid_line_ending;
        if (!syntax.isToken(byte)) return DecodeError.invalid_trailer_name;

        self.trailer_name.consume(byte);
        return null;
    }

    fn consumeTrailerValueLeadingOws(self: *Decoder, byte: u8) ?DecodeError {
        if (byte == '\n') return DecodeError.invalid_line_ending;
        if (byte == '\r') {
            self.state = State.trailer_line_lf;
            return null;
        }
        if (!syntax.isFieldValue(byte)) return DecodeError.invalid_trailer_value;
        if (syntax.isOptionalWhitespace(byte)) return null;

        self.state = State.trailer_value;
        return null;
    }

    fn consumeTrailerValue(self: *Decoder, byte: u8) ?DecodeError {
        if (byte == '\n') return DecodeError.invalid_line_ending;
        if (byte == '\r') {
            self.state = State.trailer_line_lf;
            return null;
        }
        if (!syntax.isFieldValue(byte)) return DecodeError.invalid_trailer_value;
        return null;
    }

    fn resetChunkSize(self: *Decoder) void {
        self.current_chunk_size = 0;
        self.saw_size_digit = false;
    }

    fn completed(self: *const Decoder, consumed: usize) FeedResult {
        return .{ .complete = .{
            .consumed = consumed,
            .decoded_length = self.decoded_length,
            .trailer_count = self.trailer_count,
        } };
    }

    fn fail(self: *Decoder, decode_error: DecodeError) FeedResult {
        self.state = State.failed;
        self.failure = decode_error;
        return .{ .err = decode_error };
    }
};

fn hexValue(byte: u8) ?u64 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

fn matchesAt(expected: []const u8, index: usize, byte: u8) bool {
    return index < expected.len and
        std.ascii.toLower(byte) == expected[index];
}
