const std = @import("std");
const framing = @import("framing.zig");
const request_target = @import("request_target.zig");
const syntax = @import("syntax.zig");
const types = @import("types.zig");

pub const default_max_headers: usize = 128;

pub const Span = types.Span;
pub const HttpVersion = types.HttpVersion;
pub const TargetForm = types.TargetForm;
pub const RequestLine = types.RequestLine;
pub const Header = types.Header;
pub const FeedResultTag = types.FeedResultTag;
pub const FeedResult = types.FeedResult;
pub const ParseError = types.ParseError;
pub const HeadCompletion = types.HeadCompletion;
pub const BodyFraming = framing.BodyFraming;

const State = enum {
    method,
    leading_line_lf,
    target_start,
    target,
    version,
    request_line_lf,
    header_line_start,
    header_name,
    header_value_leading_ows,
    header_value,
    header_line_lf,
    head_end_lf,
    done,
    failed,
};

const MethodKind = request_target.MethodKind;
const TargetTracker = request_target.Tracker;
const TargetResult = request_target.Result;

const VersionResult = union(enum) {
    version: HttpVersion,
    err: ParseError,
};

pub const Parser = ParserWithCapacity(default_max_headers);

pub fn ParserWithCapacity(comptime max_headers: usize) type {
    return struct {
        const Self = @This();

        state: State = State.method,
        offset: u32 = 0,
        failure: ?ParseError = null,

        parsed_request_line: ?RequestLine = null,
        parsed_body_framing: ?BodyFraming = null,
        parsed_headers: [max_headers]Header = undefined,
        parsed_header_count: usize = 0,

        method_start: u32 = 0,
        leading_line_skipped: bool = false,
        method_length: u32 = 0,
        method_maybe_connect: bool = true,
        method_maybe_options: bool = true,
        method_kind: MethodKind = MethodKind.other,

        target_start: u32 = 0,
        target_tracker: TargetTracker = .{},
        pending_target_form: ?TargetForm = null,

        version_bytes: [8]u8 = undefined,
        version_length: u8 = 0,
        pending_version: ?HttpVersion = null,

        header_name_start: u32 = 0,
        header_name_length: u32 = 0,
        header_value_start: u32 = 0,
        header_value_end: u32 = 0,
        pending_header: Header = undefined,
        message_framing: framing.Tracker = .{},

        pub fn feed(self: *Self, bytes: []const u8) FeedResult {
            if (self.state == State.done) {
                return FeedResult{ .head_complete = .{
                    .head_length = self.offset,
                    .consumed = 0,
                } };
            }

            if (self.state == State.failed) return FeedResult{ .err = self.failure.? };

            var index: usize = 0;
            while (index < bytes.len) {
                const parse_error = switch (self.state) {
                    State.method => self.consumeMethodRun(bytes, &index),
                    State.target => self.consumeTargetRun(bytes, &index),
                    State.version => self.consumeVersionRun(bytes, &index),
                    State.header_name => self.consumeHeaderNameRun(bytes, &index),
                    State.header_value => self.consumeHeaderValueVector(
                        bytes,
                        &index,
                    ),
                    State.leading_line_lf,
                    State.target_start,
                    State.request_line_lf,
                    State.header_line_start,
                    State.header_value_leading_ows,
                    State.header_line_lf,
                    State.head_end_lf,
                    => self.consumeSingle(bytes, &index),
                    State.done, State.failed => unreachable,
                };

                if (parse_error) |err| return self.fail(err);
                if (self.state == State.done) {
                    return FeedResult{ .head_complete = .{
                        .head_length = self.offset,
                        .consumed = index,
                    } };
                }
            }

            return FeedResult{ .need_more = {} };
        }

        fn consumeStateRun(
            self: *Self,
            bytes: []const u8,
            index: *usize,
            comptime expected_state: State,
            comptime consume: anytype,
        ) ?ParseError {
            while (index.* < bytes.len and self.state == expected_state) {
                const position = self.offset;
                if (!self.advanceOffset()) return ParseError.input_too_large;

                const byte = bytes[index.*];
                index.* += 1;
                if (consume(self, byte, position)) |parse_error| return parse_error;
            }
            return null;
        }

        /// The bytes from `index` that can advance the offset before it
        /// reaches its limit; the next byte after them fails as
        /// `advanceOffset` would.
        fn offsetBudget(self: *const Self, bytes: []const u8, index: usize) []const u8 {
            const rest = bytes[index..];
            return rest[0..@min(rest.len, std.math.maxInt(u32) - self.offset)];
        }

        /// Takes `length` bytes that a run consumer has already accepted.
        fn skipAccepted(self: *Self, index: *usize, length: usize) void {
            self.offset += @intCast(length);
            index.* += length;
        }

        // The run loops below take plain bytes in one step and pass every
        // other byte to the same per-byte function as before, so the result
        // of a feed does not depend on how the input was split.

        /// A whole method and its space in this input take one step; anything
        /// else, such as a method split across reads, goes byte by byte.
        fn consumeMethodRun(self: *Self, bytes: []const u8, index: *usize) ?ParseError {
            if (self.method_length == 0) {
                const run = self.offsetBudget(bytes, index.*);
                const length = syntax.tokenRun(run);
                if (length != 0 and length < run.len and run[length] == ' ') {
                    const method = run[0..length];
                    self.method_start = self.offset;
                    self.method_length = @intCast(length);
                    self.method_maybe_connect = std.mem.eql(u8, method, "CONNECT");
                    self.method_maybe_options = std.mem.eql(u8, method, "OPTIONS");
                    self.method_kind = self.finishMethodKind();
                    self.skipAccepted(index, length + 1);
                    self.state = State.target_start;
                    return null;
                }
            }
            return self.consumeStateRun(bytes, index, State.method, consumeMethod);
        }

        /// `HTTP/1.1` or `HTTP/1.0` and its CR in this input take one step.
        fn consumeVersionRun(self: *Self, bytes: []const u8, index: *usize) ?ParseError {
            const run = self.offsetBudget(bytes, index.*);
            if (self.version_length == 0 and run.len >= "HTTP/1.1\r".len and
                std.mem.eql(u8, run[0.."HTTP/1.".len], "HTTP/1.") and run["HTTP/1.1".len] == '\r')
            {
                const version = switch (run["HTTP/1.".len]) {
                    '1' => HttpVersion.http_1_1,
                    '0' => HttpVersion.http_1_0,
                    else => null,
                };
                if (version) |known| {
                    @memcpy(self.version_bytes[0..], run[0..self.version_bytes.len]);
                    self.version_length = self.version_bytes.len;
                    self.pending_version = known;
                    self.skipAccepted(index, "HTTP/1.1\r".len);
                    self.state = State.request_line_lf;
                    return null;
                }
            }
            return self.consumeStateRun(bytes, index, State.version, consumeVersion);
        }

        fn consumeTargetRun(self: *Self, bytes: []const u8, index: *usize) ?ParseError {
            while (index.* < bytes.len and self.state == State.target) {
                self.skipAccepted(index, self.target_tracker.consumePlainRun(self.offsetBudget(bytes, index.*)));
                if (index.* == bytes.len) break;
                if (self.consumeSingleWith(bytes, index, consumeTarget)) |parse_error| return parse_error;
            }
            return null;
        }

        fn consumeHeaderNameRun(self: *Self, bytes: []const u8, index: *usize) ?ParseError {
            while (index.* < bytes.len and self.state == State.header_name) {
                const run = self.offsetBudget(bytes, index.*);
                const length = syntax.tokenRun(run);
                self.message_framing.consumeHeaderNameRun(run[0..length]);
                self.header_name_length += @intCast(length);
                self.skipAccepted(index, length);
                if (index.* == bytes.len) break;
                if (self.consumeSingleWith(bytes, index, consumeHeaderName)) |parse_error| return parse_error;
            }
            return null;
        }

        fn consumeScalarHeaderValue(self: *Self, bytes: []const u8, index: *usize) ?ParseError {
            while (index.* < bytes.len and self.state == State.header_value) {
                const length = self.message_framing.consumeValueRun(self.offsetBudget(bytes, index.*));
                if (length != 0) {
                    // Every byte a value run accepts is visible ASCII.
                    self.skipAccepted(index, length);
                    self.header_value_end = self.offset;
                    if (index.* == bytes.len) break;
                }
                if (self.consumeSingleWith(bytes, index, consumeHeaderValue)) |parse_error| return parse_error;
            }
            return null;
        }

        fn consumeSingleWith(self: *Self, bytes: []const u8, index: *usize, comptime consume: anytype) ?ParseError {
            const position = self.offset;
            if (!self.advanceOffset()) return ParseError.input_too_large;

            const byte = bytes[index.*];
            index.* += 1;
            return consume(self, byte, position);
        }

        fn consumeSingle(
            self: *Self,
            bytes: []const u8,
            index: *usize,
        ) ?ParseError {
            return self.consumeSingleWith(bytes, index, consumeByte);
        }

        fn consumeHeaderValueVector(
            self: *Self,
            bytes: []const u8,
            index: *usize,
        ) ?ParseError {
            if (self.message_framing.needsScalarValue()) return self.consumeScalarHeaderValue(bytes, index);

            const vector_length = 16;
            const ByteVector = @Vector(vector_length, u8);
            const position_aware_block_count = 1;

            // A short field value commonly ends in its first vector block.
            // Keep that block position-aware, then use the smaller bulk loop.
            var position_aware_blocks: usize = 0;
            while (bytes.len - index.* >= vector_length and
                position_aware_blocks < position_aware_block_count)
            {
                const block_bytes = bytes[index.*..][0..vector_length];
                const block: ByteVector = block_bytes.*;
                const below_space = block < @as(ByteVector, @splat(0x20));
                const not_tab = block != @as(ByteVector, @splat('\t'));
                const is_delete = block == @as(ByteVector, @splat(0x7f));
                const special = (below_space & not_tab) | is_delete;

                if (@reduce(std.builtin.ReduceOp.Or, special)) {
                    const special_index = std.simd.firstTrue(special).?;
                    const safe_length: u32 = special_index;
                    if (self.offset > std.math.maxInt(u32) - safe_length) return ParseError.input_too_large;

                    var last_non_ows = special_index;
                    while (last_non_ows > 0) {
                        last_non_ows -= 1;
                        const byte = block_bytes[last_non_ows];
                        if (byte != ' ' and byte != '\t') {
                            self.header_value_end = self.offset +
                                @as(u32, last_non_ows) + 1;
                            break;
                        }
                    }

                    self.offset += safe_length;
                    index.* += special_index;
                    break;
                }

                if (self.offset > std.math.maxInt(u32) - vector_length) return ParseError.input_too_large;

                const non_ows = (block != @as(ByteVector, @splat(' '))) &
                    (block != @as(ByteVector, @splat('\t')));
                if (std.simd.lastTrue(non_ows)) |last_non_ows| {
                    self.header_value_end = self.offset + last_non_ows + 1;
                }

                self.offset += vector_length;
                index.* += vector_length;
                position_aware_blocks += 1;
            }

            while (bytes.len - index.* >= vector_length) {
                const block: ByteVector = bytes[index.*..][0..vector_length].*;
                const below_space = block < @as(ByteVector, @splat(0x20));
                const not_tab = block != @as(ByteVector, @splat('\t'));
                const is_delete = block == @as(ByteVector, @splat(0x7f));
                const special = (below_space & not_tab) | is_delete;
                if (@reduce(std.builtin.ReduceOp.Or, special)) break;

                if (self.offset > std.math.maxInt(u32) - vector_length) return ParseError.input_too_large;

                const non_ows = (block != @as(ByteVector, @splat(' '))) &
                    (block != @as(ByteVector, @splat('\t')));
                if (std.simd.lastTrue(non_ows)) |last_non_ows| {
                    self.header_value_end = self.offset + last_non_ows + 1;
                }

                self.offset += vector_length;
                index.* += vector_length;
            }

            // Fewer than a block's bytes remain, or a block held CR or another
            // control byte.
            while (index.* < bytes.len and self.state == State.header_value) {
                const run = self.offsetBudget(bytes, index.*);
                const length = syntax.fieldValueRun(run);
                if (length != 0) {
                    if (syntax.lastNonWhitespace(run[0..length])) |last| {
                        self.header_value_end = self.offset + @as(u32, @intCast(last)) + 1;
                    }
                    self.skipAccepted(index, length);
                    if (index.* == bytes.len) break;
                }
                if (self.consumeSingleWith(bytes, index, consumeHeaderValue)) |parse_error| return parse_error;
            }
            return null;
        }

        /// Starts a new head. The header array is written before it is read,
        /// so it is left as it is: a safe build would fill all of it.
        pub fn reset(self: *Self) void {
            const info = @typeInfo(Self).@"struct";
            inline for (info.field_names, 0..) |name, i| {
                if (comptime !std.mem.eql(u8, name, "parsed_headers")) {
                    @field(self, name) = info.field_attrs[i].defaultValue(info.field_types[i]).?;
                }
            }
        }

        /// Whether a whole head has been parsed without error.
        pub fn isComplete(self: *const Self) bool {
            return self.state == State.done;
        }

        /// Takes over `other`'s state, copying only the headers it holds.
        pub fn copyFrom(self: *Self, other: *const Self) void {
            inline for (@typeInfo(Self).@"struct".field_names) |name| {
                if (comptime !std.mem.eql(u8, name, "parsed_headers")) {
                    @field(self, name) = @field(other, name);
                }
            }
            const count = other.parsed_header_count;
            @memcpy(self.parsed_headers[0..count], other.parsed_headers[0..count]);
        }

        pub fn requestLine(self: *const Self) ?RequestLine {
            return self.parsed_request_line;
        }

        /// Bytes of the request-target read so far. Lets a caller reject an
        /// over-long target before the rest of the head arrives.
        pub fn targetLength(self: *const Self) usize {
            return self.target_tracker.length;
        }

        pub fn headers(self: *const Self) []const Header {
            return self.parsed_headers[0..self.parsed_header_count];
        }

        pub fn bodyFraming(self: *const Self) ?BodyFraming {
            return self.parsed_body_framing;
        }

        fn consumeByte(
            self: *Self,
            byte: u8,
            position: u32,
        ) ?ParseError {
            switch (self.state) {
                State.leading_line_lf => {
                    if (byte != '\n') return ParseError.invalid_line_ending;
                    self.state = State.method;
                },
                State.target_start => return self.consumeTargetStart(byte, position),
                State.request_line_lf => {
                    if (byte != '\n') return ParseError.invalid_line_ending;
                    self.completeRequestLine();
                    self.state = State.header_line_start;
                },
                State.header_line_start => return self.consumeHeaderLineStart(byte, position),
                State.header_value_leading_ows => return self.consumeHeaderValueLeadingOws(byte, position),
                State.header_line_lf => {
                    if (byte != '\n') return ParseError.invalid_line_ending;
                    self.parsed_headers[self.parsed_header_count] = self.pending_header;
                    self.parsed_header_count += 1;
                    self.state = State.header_line_start;
                },
                State.head_end_lf => {
                    if (byte != '\n') return ParseError.invalid_line_ending;
                    const version = self.parsed_request_line.?.version;
                    switch (self.message_framing.finishHead(version)) {
                        framing.Tracker.HeadResult.framing => |body_framing| {
                            self.parsed_body_framing = body_framing;
                        },
                        framing.Tracker.HeadResult.err => |parse_error| return parse_error,
                    }
                    self.state = State.done;
                },
                // `feed` runs these states through `consumeStateRun` or the
                // vector loop, never one byte at a time.
                State.method,
                State.target,
                State.version,
                State.header_name,
                State.header_value,
                => unreachable,
                State.done, State.failed => unreachable,
            }

            return null;
        }

        fn consumeMethod(
            self: *Self,
            byte: u8,
            position: u32,
        ) ?ParseError {
            // RFC 9112 §2.2: a server SHOULD ignore at least one empty line
            // before the request-line, which some clients send after a body.
            // One CRLF is skipped; more are an invalid method.
            if (self.method_length == 0 and byte == '\r' and !self.leading_line_skipped) {
                self.leading_line_skipped = true;
                self.state = State.leading_line_lf;
                return null;
            }
            if (self.method_length == 0) self.method_start = position;
            if (byte == ' ') {
                if (self.method_length == 0) return ParseError.invalid_method;
                self.method_kind = self.finishMethodKind();
                self.state = State.target_start;
                return null;
            }

            if (byte == '\n') return ParseError.invalid_line_ending;
            if (!syntax.isToken(byte)) return ParseError.invalid_method;

            const index: usize = self.method_length;
            const connect = "CONNECT";
            const options = "OPTIONS";

            self.method_maybe_connect = self.method_maybe_connect and
                index < connect.len and byte == connect[index];
            self.method_maybe_options = self.method_maybe_options and
                index < options.len and byte == options[index];
            self.method_length += 1;

            return null;
        }

        fn finishMethodKind(self: *const Self) MethodKind {
            if (self.method_maybe_connect and self.method_length == "CONNECT".len) return MethodKind.connect;
            if (self.method_maybe_options and self.method_length == "OPTIONS".len) return MethodKind.options;
            return MethodKind.other;
        }

        fn consumeTargetStart(
            self: *Self,
            byte: u8,
            position: u32,
        ) ?ParseError {
            if (byte == '\n') return ParseError.invalid_line_ending;
            if (byte == ' ' or byte == '\r') return ParseError.invalid_request_target;
            self.target_tracker.start(self.method_kind);
            if (!self.target_tracker.consume(byte)) return ParseError.invalid_request_target;

            self.state = State.target;
            self.target_start = position;

            return null;
        }

        fn consumeTarget(
            self: *Self,
            byte: u8,
            position: u32,
        ) ?ParseError {
            _ = position;
            if (byte == ' ') {
                const target_form = switch (self.target_tracker.finish(self.method_kind)) {
                    TargetResult.form => |form| form,
                    TargetResult.err => |parse_error| return parse_error,
                };

                self.pending_target_form = target_form;
                self.state = State.version;

                return null;
            }

            if (byte == '\n') return ParseError.invalid_line_ending;
            if (byte == '\r') return ParseError.invalid_request_target;
            if (!self.target_tracker.consume(byte)) return ParseError.invalid_request_target;

            return null;
        }

        fn consumeVersion(
            self: *Self,
            byte: u8,
            position: u32,
        ) ?ParseError {
            _ = position;
            if (byte == '\n') return ParseError.invalid_line_ending;
            if (byte == '\r') {
                switch (self.finishVersion()) {
                    VersionResult.version => |version| self.pending_version = version,
                    VersionResult.err => |parse_error| return parse_error,
                }
                self.state = State.request_line_lf;
                return null;
            }

            if (self.version_length >= self.version_bytes.len) return ParseError.invalid_http_version;

            self.version_bytes[self.version_length] = byte;
            self.version_length += 1;

            return null;
        }

        fn finishVersion(self: *const Self) VersionResult {
            if (self.version_length != self.version_bytes.len) {
                return VersionResult{ .err = ParseError.invalid_http_version };
            }

            const version = self.version_bytes[0..self.version_length];
            if (std.mem.eql(u8, version, "HTTP/1.0")) return VersionResult{ .version = HttpVersion.http_1_0 };
            if (std.mem.eql(u8, version, "HTTP/1.1")) return VersionResult{ .version = HttpVersion.http_1_1 };

            if (std.mem.eql(u8, version[0..5], "HTTP/") and
                version[5] >= '0' and version[5] <= '9' and
                version[6] == '.' and
                version[7] >= '0' and version[7] <= '9')
            {
                return VersionResult{ .err = ParseError.unsupported_http_version };
            }

            return VersionResult{ .err = ParseError.invalid_http_version };
        }

        fn completeRequestLine(self: *Self) void {
            self.parsed_request_line = RequestLine{
                .method = .{
                    .start = self.method_start,
                    .len = self.method_length,
                },
                .target = .{
                    .start = self.target_start,
                    .len = self.target_tracker.length,
                },
                .target_form = self.pending_target_form orelse unreachable,
                .version = self.pending_version orelse unreachable,
            };
            self.pending_target_form = null;
            self.pending_version = null;
        }

        fn consumeHeaderLineStart(
            self: *Self,
            byte: u8,
            position: u32,
        ) ?ParseError {
            if (byte == '\r') {
                self.state = State.head_end_lf;
                return null;
            }

            if (byte == '\n') return ParseError.invalid_line_ending;
            if (byte == ' ' or byte == '\t') return ParseError.obsolete_line_folding;
            if (!syntax.isToken(byte)) return ParseError.invalid_header_name;

            self.header_name_start = position;
            self.header_name_length = 1;
            self.message_framing.startHeader(byte);
            self.state = State.header_name;

            return null;
        }

        fn consumeHeaderName(
            self: *Self,
            byte: u8,
            position: u32,
        ) ?ParseError {
            _ = position;
            if (byte == ':') {
                if (self.message_framing.finishHeaderName()) |err| return err;
                self.state = State.header_value_leading_ows;
                return null;
            }

            if (byte == '\n') return ParseError.invalid_line_ending;
            if (!syntax.isToken(byte)) return ParseError.invalid_header_name;

            self.header_name_length += 1;
            self.message_framing.consumeHeaderName(byte);

            return null;
        }

        fn consumeHeaderValueLeadingOws(
            self: *Self,
            byte: u8,
            position: u32,
        ) ?ParseError {
            if (byte == '\n') return ParseError.invalid_line_ending;
            if (byte == '\r') return self.prepareHeader(position, position);
            if (!syntax.isFieldValue(byte)) return ParseError.invalid_header_value;
            if (self.message_framing.consumeValue(byte)) |err| return err;
            if (syntax.isOptionalWhitespace(byte)) return null;

            self.header_value_start = position;
            self.header_value_end = position + 1;
            self.state = State.header_value;

            return null;
        }

        fn consumeHeaderValue(
            self: *Self,
            byte: u8,
            position: u32,
        ) ?ParseError {
            if (byte == '\n') return ParseError.invalid_line_ending;
            if (byte == '\r') {
                return self.prepareHeader(
                    self.header_value_start,
                    self.header_value_end,
                );
            }
            if (!syntax.isFieldValue(byte)) return ParseError.invalid_header_value;
            if (self.message_framing.consumeValue(byte)) |err| return err;

            if (!syntax.isOptionalWhitespace(byte)) {
                self.header_value_end = position + 1;
            }

            return null;
        }

        fn prepareHeader(
            self: *Self,
            value_start: u32,
            value_end: u32,
        ) ?ParseError {
            if (self.parsed_header_count == max_headers) return ParseError.too_many_headers;
            if (self.message_framing.finishHeader()) |err| return err;

            self.pending_header = .{
                .name = .{
                    .start = self.header_name_start,
                    .len = self.header_name_length,
                },
                .value = .{
                    .start = value_start,
                    .len = value_end - value_start,
                },
            };
            self.state = State.header_line_lf;

            return null;
        }

        fn advanceOffset(self: *Self) bool {
            if (self.offset == std.math.maxInt(u32)) return false;
            self.offset += 1;
            return true;
        }

        fn fail(
            self: *Self,
            parse_error: ParseError,
        ) FeedResult {
            self.state = State.failed;
            self.failure = parse_error;
            return FeedResult{ .err = parse_error };
        }
    };
}

pub fn parseAll(bytes: []const u8) FeedResult {
    var parser = Parser{};
    return parser.feed(bytes);
}
