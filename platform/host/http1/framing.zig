const std = @import("std");
const authority = @import("authority.zig");
const syntax = @import("syntax.zig");
const types = @import("types.zig");

const HttpVersion = types.HttpVersion;
const ParseError = types.ParseError;

pub const BodyFraming = union(enum) {
    none,
    content_length: u64,
    chunked,
};

const HeaderKind = enum {
    other,
    host,
    content_length,
    transfer_encoding,
};

const HeaderNameCandidate = enum {
    undetermined,
    host,
    content_length,
    transfer_encoding,
    other,
};

const HeaderNameMatcher = struct {
    length: usize = 0,
    candidate: HeaderNameCandidate = HeaderNameCandidate.undetermined,

    fn reset(self: *HeaderNameMatcher) void {
        self.* = HeaderNameMatcher{};
    }

    fn consume(self: *HeaderNameMatcher, byte: u8) void {
        const index = self.length;
        self.candidate = switch (self.candidate) {
            HeaderNameCandidate.undetermined => switch (std.ascii.toLower(byte)) {
                'h' => HeaderNameCandidate.host,
                'c' => HeaderNameCandidate.content_length,
                't' => HeaderNameCandidate.transfer_encoding,
                else => HeaderNameCandidate.other,
            },
            HeaderNameCandidate.host => if (matchesAt("host", index, byte))
                HeaderNameCandidate.host
            else
                HeaderNameCandidate.other,
            HeaderNameCandidate.content_length => if (matchesAt("content-length", index, byte))
                HeaderNameCandidate.content_length
            else
                HeaderNameCandidate.other,
            HeaderNameCandidate.transfer_encoding => if (matchesAt("transfer-encoding", index, byte))
                HeaderNameCandidate.transfer_encoding
            else
                HeaderNameCandidate.other,
            HeaderNameCandidate.other => HeaderNameCandidate.other,
        };
        self.length += 1;
    }

    /// `consume` for each byte; once no framing name can match, only counts.
    fn consumeSlice(self: *HeaderNameMatcher, bytes: []const u8) void {
        for (bytes, 0..) |byte, index| {
            if (self.candidate == HeaderNameCandidate.other) {
                self.length += bytes.len - index;
                return;
            }
            self.consume(byte);
        }
    }

    fn finish(self: *const HeaderNameMatcher) HeaderKind {
        return switch (self.candidate) {
            HeaderNameCandidate.host => if (self.length == "host".len)
                HeaderKind.host
            else
                HeaderKind.other,
            HeaderNameCandidate.content_length => if (self.length == "content-length".len)
                HeaderKind.content_length
            else
                HeaderKind.other,
            HeaderNameCandidate.transfer_encoding => if (self.length == "transfer-encoding".len)
                HeaderKind.transfer_encoding
            else
                HeaderKind.other,
            HeaderNameCandidate.undetermined,
            HeaderNameCandidate.other,
            => HeaderKind.other,
        };
    }
};

const HostValueState = enum {
    leading_ows,
    value,
    trailing_ows,
    failed,
};

const HostValueTracker = struct {
    state: HostValueState = HostValueState.leading_ows,
    authority: authority.Tracker = .{},

    fn consume(self: *HostValueTracker, byte: u8) ?ParseError {
        self.state = switch (self.state) {
            HostValueState.leading_ows => if (syntax.isOptionalWhitespace(byte))
                HostValueState.leading_ows
            else if (self.authority.consume(byte))
                HostValueState.value
            else
                HostValueState.failed,
            HostValueState.value => if (syntax.isOptionalWhitespace(byte))
                HostValueState.trailing_ows
            else if (self.authority.consume(byte))
                HostValueState.value
            else
                HostValueState.failed,
            HostValueState.trailing_ows => if (syntax.isOptionalWhitespace(byte))
                HostValueState.trailing_ows
            else
                HostValueState.failed,
            HostValueState.failed => HostValueState.failed,
        };
        if (self.state == HostValueState.failed) return ParseError.invalid_host;
        return null;
    }

    /// Consumes a leading run of host bytes with the same result as `consume`
    /// on each. Returns how many bytes it took.
    fn consumeRun(self: *HostValueTracker, bytes: []const u8) usize {
        if (self.state != HostValueState.value) return 0;
        return self.authority.consumeRegNameRun(bytes);
    }

    fn finish(self: *const HostValueTracker) ?ParseError {
        if (self.state == HostValueState.failed or
            !self.authority.finish(true, false))
        {
            return ParseError.invalid_host;
        }
        return null;
    }
};

const ContentLengthTracker = struct {
    value: u64 = 0,
    saw_digit: bool = false,
    trailing_ows: bool = false,

    fn consume(self: *ContentLengthTracker, byte: u8) ?ParseError {
        if (byte >= '0' and byte <= '9') {
            if (self.trailing_ows) return ParseError.invalid_content_length;

            const digit: u64 = byte - '0';
            if (self.value > (std.math.maxInt(u64) - digit) / 10) return ParseError.content_length_overflow;
            self.value = self.value * 10 + digit;
            self.saw_digit = true;
            return null;
        }

        if (syntax.isOptionalWhitespace(byte)) {
            if (self.saw_digit) self.trailing_ows = true;
            return null;
        }

        return ParseError.invalid_content_length;
    }

    fn finish(self: *const ContentLengthTracker) ?ParseError {
        if (!self.saw_digit) return ParseError.invalid_content_length;
        return null;
    }
};

const TransferState = enum {
    before_coding,
    coding,
    after_coding,
};

const TransferEncodingTracker = struct {
    state: TransferState = TransferState.before_coding,
    coding_length: usize = 0,
    coding_maybe_chunked: bool = true,
    saw_coding: bool = false,

    fn beginField(self: *TransferEncodingTracker) ?ParseError {
        if (self.saw_coding) return ParseError.invalid_transfer_encoding;
        self.state = TransferState.before_coding;
        return null;
    }

    fn consume(self: *TransferEncodingTracker, byte: u8) ?ParseError {
        switch (self.state) {
            TransferState.before_coding => {
                if (syntax.isOptionalWhitespace(byte)) return null;
                if (!syntax.isToken(byte)) return ParseError.invalid_transfer_encoding;
                self.startCoding(byte);
            },
            TransferState.coding => {
                if (syntax.isToken(byte)) {
                    self.consumeCodingByte(byte);
                } else if (syntax.isOptionalWhitespace(byte)) {
                    if (self.finishCoding()) |err| return err;
                    self.state = TransferState.after_coding;
                } else {
                    if (self.finishCoding()) |err| return err;
                    return ParseError.invalid_transfer_encoding;
                }
            },
            TransferState.after_coding => {
                if (syntax.isOptionalWhitespace(byte)) return null;
                return ParseError.invalid_transfer_encoding;
            },
        }
        return null;
    }

    fn finishField(self: *TransferEncodingTracker) ?ParseError {
        switch (self.state) {
            TransferState.coding => {
                if (self.finishCoding()) |err| return err;
            },
            TransferState.after_coding => {},
            else => return ParseError.invalid_transfer_encoding,
        }
        return null;
    }

    fn finish(self: *const TransferEncodingTracker) ?ParseError {
        if (!self.saw_coding) return ParseError.invalid_transfer_encoding;
        return null;
    }

    fn startCoding(self: *TransferEncodingTracker, byte: u8) void {
        self.state = TransferState.coding;
        self.coding_length = 0;
        self.coding_maybe_chunked = true;
        self.consumeCodingByte(byte);
    }

    fn consumeCodingByte(self: *TransferEncodingTracker, byte: u8) void {
        self.coding_maybe_chunked = self.coding_maybe_chunked and
            matchesAt("chunked", self.coding_length, byte);
        self.coding_length += 1;
    }

    fn finishCoding(self: *TransferEncodingTracker) ?ParseError {
        const is_chunked = self.coding_maybe_chunked and
            self.coding_length == "chunked".len;
        if (!is_chunked) return ParseError.unsupported_transfer_coding;
        self.saw_coding = true;
        return null;
    }
};

pub const Tracker = struct {
    header_name: HeaderNameMatcher = .{},
    current_header: HeaderKind = HeaderKind.other,
    host_count: usize = 0,
    current_host: HostValueTracker = .{},
    content_length: ?u64 = null,
    current_content_length: ContentLengthTracker = .{},
    transfer_encoding_seen: bool = false,
    transfer_encoding: TransferEncodingTracker = .{},

    pub fn startHeader(self: *Tracker, first_byte: u8) void {
        self.header_name.reset();
        self.header_name.consume(first_byte);
        self.current_header = HeaderKind.other;
    }

    pub fn consumeHeaderName(self: *Tracker, byte: u8) void {
        self.header_name.consume(byte);
    }

    pub fn consumeHeaderNameRun(self: *Tracker, bytes: []const u8) void {
        self.header_name.consumeSlice(bytes);
    }

    pub fn finishHeaderName(self: *Tracker) ?ParseError {
        self.current_header = self.header_name.finish();
        switch (self.current_header) {
            HeaderKind.host => {
                if (self.host_count != 0) return ParseError.duplicate_host;
                self.host_count += 1;
                self.current_host = HostValueTracker{};
            },
            HeaderKind.content_length => {
                if (self.content_length != null) return ParseError.duplicate_content_length;
                if (self.transfer_encoding_seen) return ParseError.conflicting_message_framing;
                self.current_content_length = ContentLengthTracker{};
            },
            HeaderKind.transfer_encoding => {
                if (self.content_length != null) return ParseError.conflicting_message_framing;
                if (self.transfer_encoding.beginField()) |err| return err;
                self.transfer_encoding_seen = true;
            },
            HeaderKind.other => {},
        }
        return null;
    }

    pub fn needsScalarValue(self: *const Tracker) bool {
        return self.current_header == HeaderKind.host or
            self.current_header == HeaderKind.content_length or
            self.current_header == HeaderKind.transfer_encoding;
    }

    pub fn consumeValue(self: *Tracker, byte: u8) ?ParseError {
        return switch (self.current_header) {
            HeaderKind.host => self.current_host.consume(byte),
            HeaderKind.content_length => self.current_content_length.consume(byte),
            HeaderKind.transfer_encoding => self.transfer_encoding.consume(byte),
            HeaderKind.other => null,
        };
    }

    /// Consumes a leading run of value bytes that `consumeValue` would accept
    /// without a state change it must see byte by byte. Returns how many it
    /// took: only part of a Host value, so far; none for other fields.
    pub fn consumeValueRun(self: *Tracker, bytes: []const u8) usize {
        return switch (self.current_header) {
            HeaderKind.host => self.current_host.consumeRun(bytes),
            HeaderKind.content_length, HeaderKind.transfer_encoding, HeaderKind.other => 0,
        };
    }

    pub fn finishHeader(self: *Tracker) ?ParseError {
        switch (self.current_header) {
            HeaderKind.host => {
                if (self.current_host.finish()) |err| return err;
            },
            HeaderKind.content_length => {
                if (self.current_content_length.finish()) |err| return err;
                self.content_length = self.current_content_length.value;
            },
            HeaderKind.transfer_encoding => {
                if (self.transfer_encoding.finishField()) |err| return err;
            },
            HeaderKind.other => {},
        }
        return null;
    }

    pub const HeadResult = union(enum) { framing: BodyFraming, err: ParseError };

    pub fn finishHead(
        self: *const Tracker,
        version: HttpVersion,
    ) HeadResult {
        if (version == HttpVersion.http_1_1 and self.host_count == 0) {
            return HeadResult{ .err = ParseError.missing_host };
        }
        if (version == HttpVersion.http_1_0 and self.transfer_encoding_seen) {
            return HeadResult{ .err = ParseError.transfer_encoding_on_http_1_0 };
        }
        if (self.transfer_encoding_seen) {
            if (self.transfer_encoding.finish()) |err| return HeadResult{ .err = err };
            return HeadResult{ .framing = BodyFraming.chunked };
        }
        if (self.content_length) |length| {
            return HeadResult{ .framing = BodyFraming{ .content_length = length } };
        }
        return HeadResult{ .framing = BodyFraming.none };
    }
};

fn matchesAt(expected: []const u8, index: usize, byte: u8) bool {
    return index < expected.len and
        std.ascii.toLower(byte) == expected[index];
}
