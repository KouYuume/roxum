const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../roc_platform_abi.zig");
const http1 = @import("../http1/encoder.zig");
const response_framing = @import("../http1/response_framing.zig");

pub const HttpResponse = abi.HttpResponse;
pub const HttpResponseBody = abi.HttpResponseBody;
pub const HttpResponseBodyTag = abi.HttpResponseBodyTag;
pub const HttpResponseHeader = abi.HttpResponseHeader;
pub const HttpResponseHeaderList = abi.RocList(abi.HttpResponseHeader);
pub const RocStr = abi.RocStr;
pub const RocByteList = abi.RocListWith(u8, false);
pub const RocHost = abi.RocHost;

pub const Encoder = http1.Encoder;
pub const EncodeError = http1.EncodeError || response_framing.Error;
pub const HttpVersion = http1.HttpVersion;
pub const ResponseConnection = response_framing.ResponseConnection;
pub const RequestSemantics = response_framing.RequestSemantics;
pub const AdvanceError = http1.AdvanceError;
pub const ResponseBuffer = http1.ResponseBuffer;

/// Room for the headers the host adds to a head while it is encoded. A
/// caller keeps one across responses: on the stack, a safe build would fill
/// these arrays for every response.
pub const HeadScratch = struct {
    content_length: [20]u8 = undefined,
    framing_headers: [2]http1.Header = undefined,
    synthetic_headers: [synthetic_header_capacity]http1.Header = undefined,
};
pub const IovecBuffer = http1.IovecBuffer;

pub const WriteError = error{
    WriteFailed,
    WriteZero,
    WriteBeyondEnd,
};

pub const WriteFn = *const fn (
    context: *anyopaque,
    iovecs: []const std.posix.iovec_const,
) WriteError!usize;

pub const OwnedResponseEncoder = struct {
    encoder: http1.Encoder,
    response: abi.HttpResponse,
    roc_host: *abi.RocHost,
    released: bool = false,

    /// Consumes one owned response reference, including when encoding fails.
    /// Test only: it adds no message framing and does not reject application
    /// `Content-Length`, `Transfer-Encoding`, or `Connection` fields, so a
    /// response sent through it could desynchronize the connection.
    pub fn init(
        response: abi.HttpResponse,
        roc_host: *abi.RocHost,
        response_buffer: *http1.ResponseBuffer,
    ) EncodeError!OwnedResponseEncoder {
        if (!builtin.is_test) @compileError("OwnedResponseEncoder.init skips message framing; use initForRequestWithExtra");
        errdefer response.decref(roc_host);

        const body = try bufferedBody(response);
        const encoder = try http1.Encoder.initAdapted(
            abi.HttpResponseHeader,
            response.status,
            response.headers.items(),
            body,
            response_buffer,
            responseHeaderView,
        );

        return .{
            .encoder = encoder,
            .response = response,
            .roc_host = roc_host,
        };
    }

    /// Consumes one owned response and adds host-owned message framing.
    pub fn initForRequest(
        response: abi.HttpResponse,
        roc_host: *abi.RocHost,
        response_buffer: *http1.ResponseBuffer,
        version: HttpVersion,
        response_connection: ResponseConnection,
        request_semantics: RequestSemantics,
        date: ?[]const u8,
    ) EncodeError!OwnedResponseEncoder {
        var scratch: HeadScratch = .{};
        return initForRequestWithExtra(
            response,
            roc_host,
            response_buffer,
            &scratch,
            version,
            response_connection,
            request_semantics,
            date,
            &.{},
        );
    }

    /// Like `initForRequest`, and also writes host diagnostic fields
    /// (`extra`, at most `maximum_extra_headers`) into the head.
    pub fn initForRequestWithExtra(
        response: abi.HttpResponse,
        roc_host: *abi.RocHost,
        response_buffer: *http1.ResponseBuffer,
        scratch: *HeadScratch,
        version: HttpVersion,
        response_connection: ResponseConnection,
        request_semantics: RequestSemantics,
        date: ?[]const u8,
        extra: []const http1.Header,
    ) EncodeError!OwnedResponseEncoder {
        errdefer response.decref(roc_host);

        const body = try bufferedBody(response);
        const framing_plan = try response_framing.plan(
            response.status,
            body.len,
            response_connection,
            request_semantics,
        );
        try validateApplicationHeaders(response);

        const framing_headers = framing_plan.syntheticHeaders(
            &scratch.content_length,
            &scratch.framing_headers,
        );
        const synthetic_headers = withDate(response.headers.items(), framing_headers, date, extra, &scratch.synthetic_headers);
        const encoder = try http1.Encoder.initAdaptedWithExtra(
            abi.HttpResponseHeader,
            version,
            response.status,
            response.headers.items(),
            synthetic_headers,
            if (framing_plan.transmit_body) body else &.{},
            response_buffer,
            responseHeaderView,
        );

        return .{
            .encoder = encoder,
            .response = response,
            .roc_host = roc_host,
        };
    }

    /// Releases the consumed response. Call exactly once unless `sendAll` is used.
    pub fn deinit(self: *OwnedResponseEncoder) void {
        std.debug.assert(!self.released);
        self.response.decref(self.roc_host);
        self.released = true;
    }

    pub fn remainingIovecs(
        self: *const OwnedResponseEncoder,
        output: *http1.IovecBuffer,
    ) []const std.posix.iovec_const {
        std.debug.assert(!self.released);
        return self.encoder.remainingIovecs(output);
    }

    pub fn advance(
        self: *OwnedResponseEncoder,
        written: usize,
    ) http1.AdvanceError!void {
        std.debug.assert(!self.released);
        return self.encoder.advance(written);
    }

    pub fn isComplete(self: *const OwnedResponseEncoder) bool {
        std.debug.assert(!self.released);
        return self.encoder.isComplete();
    }

    /// Sends the complete response and releases its ownership on every exit path.
    pub fn sendAll(
        self: *OwnedResponseEncoder,
        context: *anyopaque,
        write_fn: WriteFn,
    ) (WriteError || http1.AdvanceError)!void {
        defer self.deinit();

        try sendEncoder(&self.encoder, context, write_fn);
    }
};

pub const chunked_terminator = "0\r\n\r\n";

/// The body of a response that is not streamed.
fn bufferedBody(response: abi.HttpResponse) EncodeError![]const u8 {
    return switch (response.body.tag) {
        abi.HttpResponseBodyTag.Bytes => response.body.payload_bytes().items(),
        abi.HttpResponseBodyTag.Empty => &.{},
    };
}

/// The host sets message framing itself; an application field named
/// `content-length`, `transfer-encoding`, or `connection` is an error.
fn validateApplicationHeaders(response: abi.HttpResponse) EncodeError!void {
    for (response.headers.items()) |*header| {
        try response_framing.validateApplicationHeader(header.name.asSlice());
    }
}

/// The head of a response whose body the handler writes as it goes,
/// and how its body is framed.
pub const WrittenHead = struct {
    encoder: http1.Encoder,
    /// HTTP/1.1: each part is a chunk, and the body ends with the terminator.
    chunked: bool,
    /// False for a `HEAD` request and for 204, 205, and 304: only the head
    /// is sent.
    transmit_body: bool,
    /// HTTP/1.0 ends the body by closing the connection.
    force_connection_close: bool,

    /// Encodes the head from `response`'s status and headers; the body is
    /// ignored and `response` is left for the caller to release. A body of
    /// a known `content_length`, such as a file's, is sent as it is
    /// with `Content-Length`; otherwise it is chunked (HTTP/1.1) or ends
    /// with the connection (HTTP/1.0).
    pub fn init(
        response: *const abi.HttpResponse,
        response_buffer: *http1.ResponseBuffer,
        scratch: *HeadScratch,
        version: HttpVersion,
        response_connection: ResponseConnection,
        request_semantics: RequestSemantics,
        date: ?[]const u8,
        extra: []const http1.Header,
        content_length: ?u64,
    ) EncodeError!WrittenHead {
        if (content_length) |length| return initSized(response, response_buffer, scratch, version, response_connection, request_semantics, date, extra, length);
        const plan = try response_framing.planStreaming(
            response.status,
            version,
            response_connection,
            request_semantics,
        );
        try validateApplicationHeaders(response.*);
        const framing_headers = plan.syntheticHeaders(&scratch.framing_headers);
        const synthetic_headers = withDate(response.headers.items(), framing_headers, date, extra, &scratch.synthetic_headers);
        return .{
            .encoder = try http1.Encoder.initAdaptedWithExtra(
                abi.HttpResponseHeader,
                version,
                response.status,
                response.headers.items(),
                synthetic_headers,
                &.{},
                response_buffer,
                responseHeaderView,
            ),
            .chunked = plan.chunked,
            .transmit_body = plan.transmit_body,
            .force_connection_close = plan.transmit_body and !plan.chunked,
        };
    }

    fn initSized(
        response: *const abi.HttpResponse,
        response_buffer: *http1.ResponseBuffer,
        scratch: *HeadScratch,
        version: HttpVersion,
        response_connection: ResponseConnection,
        request_semantics: RequestSemantics,
        date: ?[]const u8,
        extra: []const http1.Header,
        content_length: u64,
    ) EncodeError!WrittenHead {
        const length = std.math.cast(usize, content_length) orelse return error.MessageTooLarge;
        // A 304 has no body, whatever the representation's length.
        const forbids_body = response.status == 204 or response.status == 304;
        const plan = try response_framing.plan(
            response.status,
            if (forbids_body) 0 else length,
            response_connection,
            request_semantics,
        );
        try validateApplicationHeaders(response.*);
        const framing_headers = plan.syntheticHeaders(&scratch.content_length, &scratch.framing_headers);
        const synthetic_headers = withDate(response.headers.items(), framing_headers, date, extra, &scratch.synthetic_headers);
        return .{
            .encoder = try http1.Encoder.initAdaptedWithExtra(
                abi.HttpResponseHeader,
                version,
                response.status,
                response.headers.items(),
                synthetic_headers,
                &.{},
                response_buffer,
                responseHeaderView,
            ),
            .chunked = false,
            .transmit_body = plan.transmit_body,
            .force_connection_close = false,
        };
    }

    pub fn send(self: *WrittenHead, context: *anyopaque, write_fn: WriteFn) (WriteError || http1.AdvanceError)!void {
        try sendEncoder(&self.encoder, context, write_fn);
    }
};

/// Writes one part of a written body: as a chunk when `chunked`, else as
/// it is. Empty bytes write nothing (an empty chunk would end the body).
pub fn writeBodyPart(context: *anyopaque, write_fn: WriteFn, bytes: []const u8, chunked: bool) WriteError!void {
    if (bytes.len == 0) return;
    if (!chunked) return writeSlices(context, write_fn, &.{bytes});
    var size_buffer: [@sizeOf(usize) * 2 + 2]u8 = undefined;
    const prefix = std.fmt.bufPrint(&size_buffer, "{x}\r\n", .{bytes.len}) catch unreachable;
    try writeSlices(context, write_fn, &.{ prefix, bytes, "\r\n" });
}

pub fn writeBodyEnd(context: *anyopaque, write_fn: WriteFn) WriteError!void {
    try writeSlices(context, write_fn, &.{chunked_terminator});
}

fn sendEncoder(
    encoder: *http1.Encoder,
    context: *anyopaque,
    write_fn: WriteFn,
) (WriteError || http1.AdvanceError)!void {
    var iovec_buffer: http1.IovecBuffer = undefined;
    while (!encoder.isComplete()) {
        const iovecs = encoder.remainingIovecs(&iovec_buffer);
        const written = try write_fn(context, iovecs);
        if (written == 0) return WriteError.WriteZero;
        try encoder.advance(written);
    }
}

fn writeSlices(
    context: *anyopaque,
    write_fn: WriteFn,
    slices: []const []const u8,
) WriteError!void {
    var iovecs: [3]std.posix.iovec_const = undefined;
    std.debug.assert(slices.len <= iovecs.len);
    var count: usize = 0;
    for (slices) |slice| {
        if (slice.len == 0) continue;
        iovecs[count] = .{ .base = slice.ptr, .len = slice.len };
        count += 1;
    }

    var remaining = iovecs[0..count];
    while (remaining.len > 0) {
        var written = try write_fn(context, remaining);
        if (written == 0) return WriteError.WriteZero;
        var available: usize = 0;
        for (remaining) |iovec| available += iovec.len;
        if (written > available) return WriteError.WriteBeyondEnd;
        while (written > 0) {
            if (written < remaining[0].len) {
                remaining[0].base += written;
                remaining[0].len -= written;
                written = 0;
            } else {
                written -= remaining[0].len;
                remaining = remaining[1..];
            }
        }
    }
}

fn responseHeaderView(
    header: *const abi.HttpResponseHeader,
) http1.Header {
    return .{
        .name = header.name.asSlice(),
        .value = header.value.asSlice(),
    };
}

/// Host diagnostic fields a response head can carry (debug mode's `dbg`
/// capture).
pub const maximum_extra_headers: usize = 17;

/// Head bytes and fields the encoder has left for host diagnostic fields
/// once the response's own fields are written.
pub const ExtraRoom = struct {
    bytes: usize,
    fields: usize,
};

/// Status line, framing fields, Date, and the blank line, estimated from
/// above: `HTTP/1.1 599 \r\n` (15), `Content-Length: <20 digits>\r\n` (38)
/// or `Transfer-Encoding: chunked\r\n` (28), `Connection: keep-alive\r\n`
/// (24), `Date: <29>\r\n` (37), and `\r\n` (2).
const host_head_reserve_bytes: usize = 128;
const host_head_reserve_fields: usize = 3;

/// What is left of the head limits after `response`'s own fields and the
/// host's framing and Date fields.
pub fn extraRoom(response: abi.HttpResponse) ExtraRoom {
    var bytes: usize = host_head_reserve_bytes;
    for (response.headers.items()) |*header| {
        bytes +|= header.name.asSlice().len + header.value.asSlice().len + 4;
    }
    return .{
        .bytes = http1.maximum_head_bytes -| bytes,
        .fields = http1.maximum_header_count -| (response.headers.items().len + host_head_reserve_fields),
    };
}
pub const ExtraHeader = http1.Header;
/// Framing (2) + Date + extra fields.
const synthetic_header_capacity: usize = 3 + maximum_extra_headers;

fn withDate(
    headers: []const abi.HttpResponseHeader,
    framing: []const http1.Header,
    date: ?[]const u8,
    extra: []const http1.Header,
    output: *[synthetic_header_capacity]http1.Header,
) []const http1.Header {
    std.debug.assert(extra.len <= maximum_extra_headers);
    @memcpy(output[0..framing.len], framing);
    var count = framing.len;
    if (date) |value| {
        const application_date = for (headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name.asSlice(), "date")) break true;
        } else false;
        if (!application_date) {
            output[count] = .{ .name = "Date", .value = value };
            count += 1;
        }
    }
    @memcpy(output[count..][0..extra.len], extra);
    return output[0 .. count + extra.len];
}
