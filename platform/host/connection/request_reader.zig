const std = @import("std");
const raw_bytes = @import("../raw_bytes.zig");
const chunked = @import("../http1/chunked.zig");
const http1 = @import("../http1/parser.zig");
const request_limits = @import("../http1/request_limits.zig");
const net = @import("../net.zig");

pub const maximum_head_bytes = request_limits.maximum_head_bytes;
pub const maximum_wire_bytes = request_limits.maximum_wire_bytes;
pub const BodyFraming = http1.BodyFraming;

pub const Timeouts = struct {
    first_byte_milliseconds: u64,
    head_milliseconds: u64,
    /// Absolute head deadline started by whoever read the first bytes. When
    /// set and bytes are already buffered, it replaces a fresh head timeout,
    /// so a request handed over by the event loop keeps its original limit.
    head_deadline: ?net.Deadline = null,
};

pub const Error = net.Error || error{
    OutOfMemory,
    IncompleteRequest,
    InvalidRequest,
    RequestHeadTooLarge,
    RequestTargetTooLong,
    RequestBodyTooLarge,
    UnsupportedHttpVersion,
    IncompleteBody,
    InvalidChunkedBody,
    MissingRequestLine,
    MissingBodyFraming,
    IdleTimeout,
    RequestHeadTimeout,
    RequestBodyTimeout,
};

pub const Request = struct {
    head_bytes: []const u8,
    request_line: http1.RequestLine,
    headers: []const http1.Header,
    body: []const u8,
};

pub const Head = struct {
    request_line: http1.RequestLine,
    headers: []const http1.Header,
    framing: http1.BodyFraming,
    length: usize,
};

pub const maximum_stream_chunk_bytes: usize = 16 * 1024;

pub const StreamRead = union(enum) {
    chunk: []const u8,
    end,
};

pub const RecoveryOutcome = union(enum) {
    recovered: usize,
    incomplete,
    limit_exceeded,
    timed_out,
};

/// Sent before the first read that waits for the client, when the request
/// expects it and the event loop has not sent it.
pub const continue_response = "HTTP/1.1 100 Continue\r\n\r\n";

/// How a body is read: `whole`, into memory, under the limit for
/// such bodies and the deadline for the whole body; or `streamed`, under its
/// own limit, each wait for bytes up to the idle timeout.
pub const ReadMode = enum { whole, streamed };

/// A body's limits. `maxInt` is no limit.
pub const BodyLimits = struct {
    whole_bytes: u64 = std.math.maxInt(u64),
    streamed_bytes: u64 = std.math.maxInt(u64),
    /// How long a streamed read waits for bytes.
    idle_timeout_milliseconds: u64 = 30_000,
};

/// The start of a chunked body the event loop decoded before it handed the
/// request over: `length` decoded bytes follow the head, and
/// `decoder` goes on from where it stopped.
pub const Predecoded = struct {
    decoder: chunked.Decoder,
    length: usize,
    /// Wire bytes the loop consumed, framing included.
    wire: u64,
};

pub const StreamOptions = struct {
    deadline: net.Deadline,
    limits: BodyLimits = .{},
    send_continue: bool = false,
    predecoded: ?Predecoded = null,
};

/// Whether a request with this framing has body bytes to read.
pub fn hasBody(framing: http1.BodyFraming) bool {
    return switch (framing) {
        http1.BodyFraming.none => false,
        http1.BodyFraming.content_length => |length| length != 0,
        http1.BodyFraming.chunked => true,
    };
}

pub const BodyStream = struct {
    reader: *Reader,
    socket: net.Socket,
    framing: http1.BodyFraming,
    wire_offset: usize,
    content_remaining: usize,
    /// A Content-Length body's length.
    content_length: usize = 0,
    decoder: chunked.Decoder = .{},
    /// Decoded bytes at `wire_offset` the event loop left to read first.
    predecoded_remaining: usize = 0,
    /// A chunked body's wire bytes so far, framing included.
    body_wire: u64 = 0,
    /// The deadline for the whole body, for `whole` reads.
    deadline: net.Deadline,
    limits: BodyLimits = .{},
    /// `100 Continue` is still to be sent before waiting for the client.
    send_continue: bool = false,
    complete: bool = false,
    failure: ?Error = null,

    /// Reads the next part of the body as a whole body is read.
    pub fn read(
        self: *BodyStream,
        maximum_bytes: usize,
    ) Error!StreamRead {
        return self.readAs(maximum_bytes, ReadMode.whole);
    }

    pub fn readAs(
        self: *BodyStream,
        maximum_bytes: usize,
        mode: ReadMode,
    ) Error!StreamRead {
        std.debug.assert(maximum_bytes > 0);
        std.debug.assert(maximum_bytes <= maximum_stream_chunk_bytes);
        if (self.failure) |err| return err;
        if (self.complete) return StreamRead.end;

        const limit = switch (mode) {
            ReadMode.whole => self.limits.whole_bytes,
            ReadMode.streamed => self.limits.streamed_bytes,
        };
        return switch (self.framing) {
            http1.BodyFraming.none => unreachable,
            http1.BodyFraming.content_length => self.readContentLength(
                maximum_bytes,
                mode,
                limit,
            ) catch |err| {
                self.failure = err;
                return err;
            },
            http1.BodyFraming.chunked => self.readChunked(
                maximum_bytes,
                mode,
                limit,
            ) catch |err| {
                self.failure = err;
                return err;
            },
        };
    }

    /// The rest of a Content-Length body read whole, in one chunk of any
    /// length, when all of it has been received; null when some must still
    /// be read from the socket, which `readAs` does in parts. The limit is the
    /// one `readAs` checks for `ReadMode.whole`.
    pub fn readBufferedWhole(self: *BodyStream) Error!?StreamRead {
        if (self.failure) |err| return err;
        if (self.complete) return StreamRead.end;
        switch (self.framing) {
            http1.BodyFraming.content_length => {},
            http1.BodyFraming.none, http1.BodyFraming.chunked => return null,
        }
        if (self.content_length > self.limits.whole_bytes) {
            self.failure = error.RequestBodyTooLarge;
            return error.RequestBodyTooLarge;
        }
        const length = self.content_remaining;
        if (length == 0 or self.reader.end - self.wire_offset < length) return null;
        const bytes = self.reader.wire_buffer[self.wire_offset..][0..length];
        self.wire_offset += length;
        self.content_remaining = 0;
        self.finishAt(self.wire_offset);
        return .{ .chunk = bytes };
    }

    pub fn isFullyConsumed(self: *const BodyStream) bool {
        return self.complete and self.failure == null;
    }

    pub fn markFailed(self: *BodyStream) void {
        self.failure = error.OutOfMemory;
    }

    /// Discards the unread body only when its complete wire representation is
    /// already buffered. This function never reads from the socket.
    pub fn discardBuffered(self: *BodyStream) Error!RecoveryOutcome {
        if (self.failure) |err| return err;
        if (self.complete) return RecoveryOutcome{ .recovered = 0 };

        return switch (self.framing) {
            http1.BodyFraming.none => unreachable,
            http1.BodyFraming.content_length => {
                if (self.reader.end - self.wire_offset < self.content_remaining) {
                    return RecoveryOutcome.incomplete;
                }
                const discarded = self.content_remaining;
                self.wire_offset += discarded;
                self.content_remaining = 0;
                self.finishAt(self.wire_offset);
                return RecoveryOutcome{ .recovered = discarded };
            },
            http1.BodyFraming.chunked => self.recoverChunked(
                std.math.maxInt(usize),
                null,
            ),
        };
    }

    /// Discards at most `maximum_bytes` of unread decoded body. Socket reads
    /// use a fresh deadline so handler time does not reduce the recovery budget.
    pub fn drainBounded(
        self: *BodyStream,
        maximum_bytes: usize,
        timeout_milliseconds: u64,
    ) Error!RecoveryOutcome {
        if (self.failure) |err| return err;
        if (self.complete) return RecoveryOutcome{ .recovered = 0 };

        const recovery_deadline = try net.Deadline.afterMilliseconds(
            timeout_milliseconds,
        );
        return switch (self.framing) {
            http1.BodyFraming.none => unreachable,
            http1.BodyFraming.content_length => {
                if (self.content_remaining > maximum_bytes) return RecoveryOutcome.limit_exceeded;
                const discarded = self.content_remaining;
                while (self.content_remaining != 0) {
                    if (self.wire_offset == self.reader.end) {
                        _ = self.receiveMoreUntil(recovery_deadline) catch |err| switch (err) {
                            error.RequestBodyTimeout => return RecoveryOutcome.timed_out,
                            error.IncompleteBody => return RecoveryOutcome.incomplete,
                            else => |receive_error| return receive_error,
                        };
                    }
                    const length = @min(
                        self.content_remaining,
                        self.reader.end - self.wire_offset,
                    );
                    self.wire_offset += length;
                    self.content_remaining -= length;
                }
                self.finishAt(self.wire_offset);
                return RecoveryOutcome{ .recovered = discarded };
            },
            http1.BodyFraming.chunked => self.recoverChunked(
                maximum_bytes,
                recovery_deadline,
            ),
        };
    }

    fn readContentLength(
        self: *BodyStream,
        maximum_bytes: usize,
        mode: ReadMode,
        limit: u64,
    ) Error!StreamRead {
        if (self.content_length > limit) return error.RequestBodyTooLarge;
        if (self.content_remaining == 0) {
            self.finishAt(self.wire_offset);
            return StreamRead.end;
        }

        while (self.wire_offset == self.reader.end) try self.receiveMore(mode);
        const available = self.reader.end - self.wire_offset;
        const length = @min(
            maximum_bytes,
            @min(available, self.content_remaining),
        );
        const bytes = self.reader.wire_buffer[self.wire_offset..][0..length];
        self.wire_offset += length;
        self.content_remaining -= length;
        if (self.content_remaining == 0) self.finishAt(self.wire_offset);
        return .{ .chunk = bytes };
    }

    fn readChunked(
        self: *BodyStream,
        maximum_bytes: usize,
        mode: ReadMode,
        limit: u64,
    ) Error!StreamRead {
        if (self.decoder.decoded_length > limit) return error.RequestBodyTooLarge;
        if (self.predecoded_remaining != 0) {
            const length = @min(maximum_bytes, self.predecoded_remaining);
            const bytes = self.reader.wire_buffer[self.wire_offset..][0..length];
            self.wire_offset += length;
            self.predecoded_remaining -= length;
            return .{ .chunk = bytes };
        }
        while (true) {
            if (self.wire_offset == self.reader.end) try self.receiveMore(mode);

            const available = self.reader.end - self.wire_offset;
            const feed_length = @min(maximum_bytes, available);
            const pending = self.reader.wire_buffer[self.wire_offset..][0..feed_length];
            switch (self.decoder.feed(pending)) {
                chunked.FeedResult.need_more => |progress| {
                    if (progress.consumed == 0) return error.InvalidChunkedBody;
                    try self.countWire(progress.consumed);
                    self.wire_offset += progress.consumed;
                },
                chunked.FeedResult.data => |data| {
                    if (data.consumed == 0) return error.InvalidChunkedBody;
                    if (self.decoder.decoded_length > limit) return error.RequestBodyTooLarge;
                    try self.countWire(data.consumed);
                    self.wire_offset += data.consumed;
                    if (data.bytes.len == 0) continue;
                    return .{ .chunk = data.bytes };
                },
                chunked.FeedResult.complete => |completion| {
                    try self.countWire(completion.consumed);
                    self.wire_offset += completion.consumed;
                    if (completion.decoded_length > limit) return error.RequestBodyTooLarge;
                    self.finishAt(self.wire_offset);
                    return StreamRead.end;
                },
                chunked.FeedResult.err => return error.InvalidChunkedBody,
            }
        }
    }

    fn countWire(self: *BodyStream, consumed: usize) Error!void {
        self.body_wire +|= consumed;
        if (request_limits.framingIsExcessive(self.body_wire, self.decoder.decoded_length)) return error.RequestBodyTooLarge;
    }

    /// Waits for more of the body: until the whole body's deadline, or for
    /// a streamed read, up to the idle timeout from now. Sends `100
    /// Continue` first if the client waits for it.
    fn receiveMore(self: *BodyStream, mode: ReadMode) Error!void {
        const deadline = switch (mode) {
            ReadMode.whole => self.deadline,
            ReadMode.streamed => try net.Deadline.afterMilliseconds(self.limits.idle_timeout_milliseconds),
        };
        if (self.send_continue) {
            self.send_continue = false;
            net.sendAllUntil(self.socket, continue_response, deadline) catch |err| switch (err) {
                error.SendTimeout => return error.RequestBodyTimeout,
                else => |send_error| return send_error,
            };
        }
        _ = try self.receiveMoreUntil(deadline);
    }

    /// Reads more wire bytes. A full wire buffer grows up to its limit before
    /// dropping bytes before `wire_offset` (the head and body already handed
    /// out). The head was copied into Roc values and each chunk is copied
    /// before the next read, so nothing still points at them. Returns how far
    /// the remaining bytes moved, for callers that hold their own offset.
    fn receiveMoreUntil(
        self: *BodyStream,
        deadline: net.Deadline,
    ) Error!usize {
        var shift: usize = 0;
        if (self.reader.end == self.reader.wire_buffer.len and !try self.reader.growForMore()) {
            shift = self.wire_offset;
            if (shift == 0) return error.RequestBodyTooLarge;
            const remaining = self.reader.end - self.wire_offset;
            std.mem.copyForwards(
                u8,
                self.reader.wire_buffer[0..remaining],
                self.reader.wire_buffer[self.wire_offset..self.reader.end],
            );
            self.reader.start = 0;
            self.reader.end = remaining;
            self.wire_offset = 0;
        }
        const received = net.receiveUntil(
            self.socket,
            self.reader.wire_buffer[self.reader.end..],
            deadline,
        ) catch |err| switch (err) {
            error.ReceiveTimeout => return error.RequestBodyTimeout,
            else => |receive_error| return receive_error,
        };
        if (received == 0) return error.IncompleteBody;
        self.reader.end += received;
        return shift;
    }

    fn recoverChunked(
        self: *BodyStream,
        maximum_bytes: usize,
        recovery_deadline: ?net.Deadline,
    ) Error!RecoveryOutcome {
        var decoder = self.decoder;
        // The bytes the event loop decoded are only skipped.
        var wire_offset = self.wire_offset + self.predecoded_remaining;
        const decoded_at_start = decoder.decoded_length;

        while (true) {
            if (wire_offset == self.reader.end) {
                const deadline = recovery_deadline orelse
                    return RecoveryOutcome.incomplete;
                // Bytes the local decoder consumed stay buffered until it
                // commits, so follow them if the buffer is compacted.
                wire_offset -= self.receiveMoreUntil(deadline) catch |err| switch (err) {
                    error.RequestBodyTimeout => return RecoveryOutcome.timed_out,
                    error.IncompleteBody => return RecoveryOutcome.incomplete,
                    else => |receive_error| return receive_error,
                };
            }

            const discarded = decoder.decoded_length - decoded_at_start;
            const remaining_budget = maximum_bytes -| discarded;
            const available = self.reader.end - wire_offset;
            const feed_length = if (remaining_budget == 0)
                @min(available, 1)
            else
                @min(available, remaining_budget);
            const pending = self.reader.wire_buffer[wire_offset..][0..feed_length];
            switch (decoder.feed(pending)) {
                chunked.FeedResult.need_more => |progress| {
                    if (progress.consumed == 0) return error.InvalidChunkedBody;
                    wire_offset += progress.consumed;
                },
                chunked.FeedResult.data => |data| {
                    if (data.consumed == 0) return error.InvalidChunkedBody;
                    if (decoder.decoded_length - decoded_at_start > maximum_bytes) {
                        return RecoveryOutcome.limit_exceeded;
                    }
                    wire_offset += data.consumed;
                },
                chunked.FeedResult.complete => |completion| {
                    if (completion.decoded_length - decoded_at_start > maximum_bytes) {
                        return RecoveryOutcome.limit_exceeded;
                    }
                    wire_offset += completion.consumed;
                    self.decoder = decoder;
                    self.wire_offset = wire_offset;
                    self.predecoded_remaining = 0;
                    self.finishAt(wire_offset);
                    return RecoveryOutcome{
                        .recovered = completion.decoded_length - decoded_at_start,
                    };
                },
                chunked.FeedResult.err => return error.InvalidChunkedBody,
            }
        }
    }

    fn finishAt(self: *BodyStream, wire_end: usize) void {
        self.reader.consumed_length = wire_end - self.reader.start;
        self.reader.head_pending = false;
        self.complete = true;
    }
};

/// A reader's buffer starts this small and grows, up to
/// `maximum_wire_bytes`, only for a request that needs more. A request
/// waiting on a fiber keeps its reader, so a fixed full-size buffer would
/// cost every waiting request 128 KiB.
pub const initial_wire_bytes: usize = 4 * 1024;
/// The largest buffer a finished request's reader keeps for the next one.
pub const retained_wire_bytes: usize = 64 * 1024;

pub const Reader = struct {
    wire_buffer: []u8 = &.{},
    start: usize = 0,
    end: usize = 0,
    consumed_length: usize = 0,
    head_pending: bool = false,
    /// The parser holds a finished parse of the seeded head; see `seed`.
    head_parsed: bool = false,
    parser: http1.Parser = .{},

    /// Reads and validates only the request head. Returned spans and headers
    /// remain valid until the next call to `nextHead`.
    pub fn nextHead(
        self: *Reader,
        socket: net.Socket,
        timeouts: Timeouts,
    ) Error!?Head {
        std.debug.assert(!self.head_pending);
        self.discardConsumed();
        if (self.head_parsed) {
            self.head_parsed = false;
        } else {
            self.parser.reset();
        }

        const head_length = (try self.readHead(
            socket,
            timeouts,
        )) orelse return null;
        const request_line = self.parser.requestLine() orelse
            return error.MissingRequestLine;
        const framing = self.parser.bodyFraming() orelse
            return error.MissingBodyFraming;
        switch (framing) {
            // The handler's reads apply the body's limits.
            http1.BodyFraming.content_length => |length| {
                if (std.math.cast(usize, length) == null) return error.RequestBodyTooLarge;
            },
            http1.BodyFraming.none, http1.BodyFraming.chunked => {},
        }
        self.head_pending = true;

        return .{
            .request_line = request_line,
            .headers = self.parser.headers(),
            .framing = framing,
            .length = head_length,
        };
    }

    /// Completes a request without a body. A request with a body is read
    /// through `beginBodyStream`, so the reader never buffers a whole body.
    pub fn finish(self: *Reader, head: Head) Request {
        std.debug.assert(self.head_pending);
        std.debug.assert(!hasBody(head.framing));
        self.consumed_length = head.length;
        self.head_pending = false;
        return .{
            .head_bytes = self.wire_buffer[self.start..][0..head.length],
            .request_line = head.request_line,
            .headers = head.headers,
            .body = &.{},
        };
    }

    pub fn headBytes(self: *const Reader, head: Head) []const u8 {
        std.debug.assert(self.head_pending);
        return self.wire_buffer[self.start..][0..head.length];
    }

    /// Starts a body stream after the head has been copied into Roc-owned
    /// values. The returned state borrows this Reader until the handler ends.
    pub fn beginBodyStream(
        self: *Reader,
        socket: net.Socket,
        head: Head,
        body_timeout_milliseconds: u64,
    ) Error!BodyStream {
        return self.beginBodyStreamUntil(
            socket,
            head,
            try net.Deadline.afterMilliseconds(body_timeout_milliseconds),
        );
    }

    /// Like `beginBodyStream` with an absolute deadline, such as one the
    /// event loop started when the head was complete.
    pub fn beginBodyStreamUntil(
        self: *Reader,
        socket: net.Socket,
        head: Head,
        deadline: net.Deadline,
    ) Error!BodyStream {
        return self.beginBodyStreamWith(socket, head, .{ .deadline = deadline });
    }

    /// Like `beginBodyStream`, with the body's limits, whether `100
    /// Continue` is still to be sent, and the start of a chunked body the
    /// event loop decoded.
    pub fn beginBodyStreamWith(
        self: *Reader,
        socket: net.Socket,
        head: Head,
        options: StreamOptions,
    ) Error!BodyStream {
        std.debug.assert(self.head_pending);
        std.debug.assert(head.framing != http1.BodyFraming.none);

        if (self.start != 0) self.compact();
        const content_length: usize = switch (head.framing) {
            http1.BodyFraming.content_length => |length| std.math.cast(usize, length) orelse
                return error.RequestBodyTooLarge,
            http1.BodyFraming.none, http1.BodyFraming.chunked => 0,
        };
        var stream = BodyStream{
            .reader = self,
            .socket = socket,
            .framing = head.framing,
            .wire_offset = head.length,
            .content_remaining = content_length,
            .content_length = content_length,
            .deadline = options.deadline,
            .limits = options.limits,
            .send_continue = options.send_continue,
        };
        if (options.predecoded) |predecoded| {
            std.debug.assert(head.framing == http1.BodyFraming.chunked);
            stream.decoder = predecoded.decoder;
            stream.predecoded_remaining = predecoded.length;
            stream.body_wire = predecoded.wire;
        }
        return stream;
    }

    /// Replaces all reader state with bytes read elsewhere, such as by the
    /// event loop before it handed the connection over. Any state left by an
    /// earlier connection, including a head abandoned on an error path, is
    /// discarded. `parsed` is a finished parse of the head at the start of
    /// `bytes`, which the next `nextHead` uses rather than parsing again; its
    /// limits are still checked.
    pub fn seed(self: *Reader, bytes: []const u8, parsed: ?*const http1.Parser) error{OutOfMemory}!void {
        std.debug.assert(bytes.len <= maximum_wire_bytes);
        if (bytes.len > self.wire_buffer.len) try self.growTo(bytes.len);
        @memcpy(self.wire_buffer[0..bytes.len], bytes);
        self.seedTaken(bytes.len, parsed);
    }

    /// The state after the first `length` bytes of the buffer were seeded.
    fn seedTaken(self: *Reader, length: usize, parsed: ?*const http1.Parser) void {
        self.start = 0;
        self.end = length;
        self.consumed_length = 0;
        self.head_pending = false;
        if (parsed) |finished| {
            std.debug.assert(finished.isComplete());
            self.parser.copyFrom(finished);
            self.head_parsed = true;
        } else {
            self.parser.reset();
            self.head_parsed = false;
        }
    }

    /// Like `seed`, for bytes the caller holds in `buffer`, a `raw_bytes`
    /// allocation, of which the first `length.*` are valid. Up to
    /// `initial_wire_bytes` are copied and stay with the caller. More, as for
    /// a prebuffered body, are taken without a copy: the reader keeps
    /// `buffer` and hands back its own buffer if it is no larger than
    /// `initial_wire_bytes`, or an empty one, so a large buffer never moves to
    /// the caller; `length.*` becomes 0.
    pub fn seedFrom(self: *Reader, buffer: *[]u8, length: *usize, parsed: ?*const http1.Parser) error{OutOfMemory}!void {
        const taken = length.*;
        std.debug.assert(taken <= buffer.len);
        if (taken <= initial_wire_bytes) return self.seed(buffer.*[0..taken], parsed);
        std.debug.assert(taken <= maximum_wire_bytes);
        const own = self.wire_buffer;
        self.wire_buffer = buffer.*;
        if (own.len <= initial_wire_bytes) {
            buffer.* = own;
        } else {
            raw_bytes.free(own);
            buffer.* = &.{};
        }
        length.* = 0;
        self.seedTaken(taken, parsed);
    }

    /// Bytes received after the last completed request, such as a pipelined
    /// request. Valid until the next call that changes the buffer.
    pub fn pendingBytes(self: *Reader) []const u8 {
        std.debug.assert(!self.head_pending);
        self.discardConsumed();
        return self.wire_buffer[self.start..self.end];
    }

    pub fn requestVersion(self: *const Reader) ?http1.HttpVersion {
        const request_line = self.parser.requestLine() orelse return null;
        return request_line.version;
    }

    /// Grows the buffer, keeping its bytes, to at least `minimum`: doubling,
    /// from `initial_wire_bytes`, up to `maximum_wire_bytes`.
    fn growTo(self: *Reader, minimum: usize) error{OutOfMemory}!void {
        std.debug.assert(minimum <= maximum_wire_bytes);
        var length = @max(self.wire_buffer.len, initial_wire_bytes);
        while (length < minimum) length *= 2;
        length = @min(length, maximum_wire_bytes);
        if (length == self.wire_buffer.len) return;
        const grown = try raw_bytes.alloc(length);
        @memcpy(grown[0..self.end], self.wire_buffer[0..self.end]);
        raw_bytes.free(self.wire_buffer);
        self.wire_buffer = grown;
    }

    /// Room for more bytes at `end`, growing before the buffer reaches its
    /// limit. False when it is at the limit.
    fn growForMore(self: *Reader) error{OutOfMemory}!bool {
        if (self.wire_buffer.len >= maximum_wire_bytes) return false;
        try self.growTo(@min(self.wire_buffer.len * 2, maximum_wire_bytes));
        return true;
    }

    /// Gives back a buffer grown past the initial size once no bytes are
    /// pending, as between requests.
    pub fn shrinkIdle(self: *Reader) void {
        if (self.start != self.end or self.head_pending) return;
        if (self.wire_buffer.len <= initial_wire_bytes) return;
        raw_bytes.free(self.wire_buffer);
        self.wire_buffer = &.{};
        self.start = 0;
        self.end = 0;
    }

    /// Forgets the bytes of a finished request, whose connection kept what
    /// it needs; the next request seeds it. A buffer grown up to
    /// `retained_wire_bytes` is kept: freeing and growing it again for every
    /// request with a body of tens of KiB halved such requests' rate on
    /// Linux. Only a larger one is given back.
    pub fn forget(self: *Reader) void {
        self.start = 0;
        self.end = 0;
        self.consumed_length = 0;
        self.head_pending = false;
        if (self.wire_buffer.len <= retained_wire_bytes) return;
        self.shrinkIdle();
    }

    pub fn deinit(self: *Reader) void {
        raw_bytes.free(self.wire_buffer);
        self.wire_buffer = &.{};
    }

    fn discardConsumed(self: *Reader) void {
        std.debug.assert(self.consumed_length <= self.end - self.start);
        self.start += self.consumed_length;
        self.consumed_length = 0;
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }
    }

    fn compact(self: *Reader) void {
        if (self.start == 0) return;
        const remaining = self.end - self.start;
        std.mem.copyForwards(
            u8,
            self.wire_buffer[0..remaining],
            self.wire_buffer[self.start..self.end],
        );
        self.start = 0;
        self.end = remaining;
    }

    fn readHead(
        self: *Reader,
        socket: net.Socket,
        timeouts: Timeouts,
    ) Error!?usize {
        var fed_length: usize = 0;
        var saw_request_byte = self.end != self.start;
        var receive_deadline = if (saw_request_byte and timeouts.head_deadline != null)
            timeouts.head_deadline.?
        else
            try net.Deadline.afterMilliseconds(
                if (saw_request_byte)
                    timeouts.head_milliseconds
                else
                    timeouts.first_byte_milliseconds,
            );

        while (true) {
            const buffered_length = self.end - self.start;
            if (fed_length < buffered_length) {
                const bytes = self.wire_buffer[self.start + fed_length .. self.end];
                switch (self.parser.feed(bytes)) {
                    http1.FeedResult.need_more => {
                        // Answer 414 as soon as the target is too long,
                        // rather than 431 once the head limit is reached.
                        if (!request_limits.requestTargetLengthIsAllowed(
                            self.parser.targetLength(),
                        )) return error.RequestTargetTooLong;
                        fed_length = buffered_length;
                    },
                    http1.FeedResult.head_complete => |completion| {
                        // The target limit is checked first so an over-long
                        // target is 414 whether or not the head also
                        // exceeds its limit.
                        const request_line = self.parser.requestLine() orelse
                            return error.MissingRequestLine;
                        if (!request_limits.requestTargetLengthIsAllowed(
                            request_line.target.len,
                        )) return error.RequestTargetTooLong;
                        if (!request_limits.headLengthIsAllowed(
                            completion.head_length,
                        )) return error.RequestHeadTooLarge;
                        return completion.head_length;
                    },
                    http1.FeedResult.err => |parse_error| switch (parse_error) {
                        http1.ParseError.too_many_headers,
                        http1.ParseError.input_too_large,
                        => return error.RequestHeadTooLarge,
                        http1.ParseError.unsupported_http_version => return error.UnsupportedHttpVersion,
                        else => return error.InvalidRequest,
                    },
                }
            }
            if (buffered_length >= maximum_head_bytes) return error.RequestHeadTooLarge;

            if (self.end == self.wire_buffer.len) {
                if (self.start != 0) {
                    self.compact();
                } else if (!try self.growForMore()) {
                    return error.RequestHeadTooLarge;
                }
            }
            const received = net.receiveUntil(
                socket,
                self.wire_buffer[self.end..],
                receive_deadline,
            ) catch |err| switch (err) {
                error.ReceiveTimeout => if (saw_request_byte)
                    return error.RequestHeadTimeout
                else
                    return error.IdleTimeout,
                else => |receive_error| return receive_error,
            };
            if (received == 0) {
                if (self.end == self.start) return null;
                return error.IncompleteRequest;
            }
            self.end += received;
            if (!saw_request_byte) {
                saw_request_byte = true;
                receive_deadline = try net.Deadline.afterMilliseconds(
                    timeouts.head_milliseconds,
                );
            }
        }
    }
};

test "seeding copies a small head and takes a larger buffer without a copy" {
    // Up to `initial_wire_bytes` are copied and stay with the caller; one
    // byte more is taken. The caller then gets the reader's own buffer only
    // if it is no larger than `initial_wire_bytes`.
    const Case = struct { length: usize, reader_buffer: usize, taken: bool, returned: usize };
    for ([_]Case{
        .{ .length = initial_wire_bytes - 1, .reader_buffer = 0, .taken = false, .returned = 0 },
        .{ .length = initial_wire_bytes, .reader_buffer = 0, .taken = false, .returned = 0 },
        .{ .length = initial_wire_bytes + 1, .reader_buffer = 0, .taken = true, .returned = 0 },
        .{ .length = initial_wire_bytes + 1, .reader_buffer = initial_wire_bytes, .taken = true, .returned = initial_wire_bytes },
        .{ .length = initial_wire_bytes + 1, .reader_buffer = initial_wire_bytes + 1, .taken = true, .returned = 0 },
    }) |case| {
        var reader = Reader{};
        defer reader.deinit();
        if (case.reader_buffer != 0) reader.wire_buffer = try raw_bytes.alloc(case.reader_buffer);
        var buffer = try raw_bytes.alloc(case.length + 7);
        defer raw_bytes.free(buffer);
        for (buffer, 0..) |*byte, index| byte.* = @truncate(index);
        const original = buffer.ptr;
        var length = case.length;

        try reader.seedFrom(&buffer, &length, null);

        try std.testing.expectEqual(case.length, reader.end);
        for (reader.wire_buffer[0..case.length], 0..) |byte, index| try std.testing.expectEqual(@as(u8, @truncate(index)), byte);
        try std.testing.expectEqual(case.taken, reader.wire_buffer.ptr == original);
        if (case.taken) {
            try std.testing.expectEqual(@as(usize, 0), length);
            try std.testing.expectEqual(case.returned, buffer.len);
        } else {
            try std.testing.expectEqual(case.length, length);
            try std.testing.expectEqual(original, buffer.ptr);
        }
    }
}
