const std = @import("std");
const http1 = @import("http1_encoder");

const Encoder = http1.Encoder;
const Header = http1.Header;
const IovecBuffer = http1.IovecBuffer;
const ResponseBuffer = http1.ResponseBuffer;

fn appendRemaining(
    encoder: *const Encoder,
    output: []u8,
) !usize {
    var length: usize = 0;
    var iovec_buffer: IovecBuffer = undefined;
    for (encoder.remainingIovecs(&iovec_buffer)) |iovec| {
        if (iovec.len > output.len - length) return error.OutputTooSmall;
        @memcpy(output[length..][0..iovec.len], iovec.base[0..iovec.len]);
        length += iovec.len;
    }
    return length;
}

test "Encoder coalesces a small body into the caller response buffer" {
    const headers = [_]Header{
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "Content-Length", .value = "5" },
    };
    var response_buffer = ResponseBuffer{};
    var encoder = try Encoder.init(200, &headers, "hello", &response_buffer);
    var output: [128]u8 = undefined;
    const length = try appendRemaining(&encoder, &output);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 \r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "hello",
        output[0..length],
    );
    var iovec_buffer: IovecBuffer = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        encoder.remainingIovecs(&iovec_buffer).len,
    );
    try std.testing.expectEqual(length, encoder.remainingBytes());
    try std.testing.expect(!encoder.isComplete());
}

test "versioned adapted encoding appends host-owned headers" {
    const application_headers = [_]Header{
        .{ .name = "Content-Type", .value = "text/plain" },
    };
    const host_headers = [_]Header{
        .{ .name = "Content-Length", .value = "5" },
        .{ .name = "Connection", .value = "keep-alive" },
    };
    var response_buffer = ResponseBuffer{};
    var encoder = try Encoder.initAdaptedWithExtra(
        Header,
        http1.HttpVersion.http_1_0,
        200,
        &application_headers,
        &host_headers,
        "hello",
        &response_buffer,
        struct {
            fn view(header: *const Header) Header {
                return header.*;
            }
        }.view,
    );
    var output: [192]u8 = undefined;
    const length = try appendRemaining(&encoder, &output);

    try std.testing.expectEqualStrings(
        "HTTP/1.0 200 \r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 5\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n" ++
            "hello",
        output[0..length],
    );
}

test "status validation covers both accepted boundaries" {
    var response_buffer = ResponseBuffer{};
    const valid = [_]u16{ 100, 101, 598, 599 };
    for (valid) |status| {
        _ = try Encoder.init(status, &.{}, "", &response_buffer);
    }

    try std.testing.expectError(
        error.InvalidStatus,
        Encoder.init(99, &.{}, "", &response_buffer),
    );
    try std.testing.expectError(
        error.InvalidStatus,
        Encoder.init(600, &.{}, "", &response_buffer),
    );
}

test "Encoder accepts the complete token punctuation set" {
    const headers = [_]Header{
        .{
            .name = "!#$%&'*+-.^_`|~",
            .value = "\t visible \x80",
        },
    };
    var response_buffer = ResponseBuffer{};
    _ = try Encoder.init(204, &headers, "", &response_buffer);
}

test "Encoder rejects empty and non-token header names" {
    const invalid_names = [_][]const u8{
        "",
        "Bad Name",
        "Bad\tName",
        "Bad(Name",
        "Bad:Name",
        "Bad\x7fName",
        "Bad\rName",
        "Bad\nName",
    };

    for (invalid_names) |name| {
        const headers = [_]Header{
            .{ .name = name, .value = "value" },
        };
        var response_buffer = ResponseBuffer{};
        try std.testing.expectError(
            error.InvalidHeaderName,
            Encoder.init(200, &headers, "", &response_buffer),
        );
    }
}

test "Encoder rejects control bytes including CR and LF in values" {
    const invalid_values = [_][]const u8{
        "bad\x00value",
        "bad\x08value",
        "bad\nvalue",
        "bad\rvalue",
        "bad\x1fvalue",
        "bad\x7fvalue",
    };

    for (invalid_values) |value| {
        const headers = [_]Header{
            .{ .name = "X-Test", .value = value },
        };
        var response_buffer = ResponseBuffer{};
        try std.testing.expectError(
            error.InvalidHeaderValue,
            Encoder.init(200, &headers, "", &response_buffer),
        );
    }
}

test "ResponseBuffer has the complete configured head capacity" {
    const response_buffer = ResponseBuffer{};

    try std.testing.expectEqual(
        http1.maximum_head_bytes,
        response_buffer.bytes.len,
    );
}

test "header count covers below at and above maximum" {
    const below = @as([(http1.maximum_header_count - 1)]Header, @splat(.{ .name = "X", .value = "" }));
    const boundary = @as([http1.maximum_header_count]Header, @splat(.{ .name = "X", .value = "" }));
    const above = @as([(http1.maximum_header_count + 1)]Header, @splat(.{ .name = "X", .value = "" }));
    var response_buffer = ResponseBuffer{};

    _ = try Encoder.init(200, &below, "", &response_buffer);
    _ = try Encoder.init(200, &boundary, "", &response_buffer);
    try std.testing.expectError(
        error.TooManyHeaders,
        Encoder.init(200, &above, "", &response_buffer),
    );
}

test "combined application and host header count covers its boundary" {
    const host_headers = [_]Header{
        .{ .name = "Content-Length", .value = "0" },
        .{ .name = "Connection", .value = "close" },
    };
    const below = @as([(http1.maximum_header_count - host_headers.len - 1)]Header, @splat(.{ .name = "X", .value = "" }));
    const boundary = @as([(http1.maximum_header_count - host_headers.len)]Header, @splat(.{ .name = "X", .value = "" }));
    const above = @as([(http1.maximum_header_count - host_headers.len + 1)]Header, @splat(.{ .name = "X", .value = "" }));
    var response_buffer = ResponseBuffer{};

    const View = struct {
        fn header(source: *const Header) Header {
            return source.*;
        }
    };
    _ = try Encoder.initAdaptedWithExtra(
        Header,
        http1.HttpVersion.http_1_1,
        200,
        &below,
        &host_headers,
        "",
        &response_buffer,
        View.header,
    );
    _ = try Encoder.initAdaptedWithExtra(
        Header,
        http1.HttpVersion.http_1_1,
        200,
        &boundary,
        &host_headers,
        "",
        &response_buffer,
        View.header,
    );
    try std.testing.expectError(
        error.TooManyHeaders,
        Encoder.initAdaptedWithExtra(
            Header,
            http1.HttpVersion.http_1_1,
            200,
            &above,
            &host_headers,
            "",
            &response_buffer,
            View.header,
        ),
    );
}

test "large header values are copied into the caller response buffer" {
    var value = @as([4096]u8, @splat('x'));
    const headers = [_]Header{
        .{ .name = "X-Large", .value = &value },
    };
    var response_buffer = ResponseBuffer{};
    const encoder = try Encoder.init(200, &headers, "body", &response_buffer);
    var iovec_buffer: IovecBuffer = undefined;
    const iovecs = encoder.remainingIovecs(&iovec_buffer);

    try std.testing.expectEqual(@as(usize, 1), iovecs.len);
    try std.testing.expect(iovecs[0].base != value[0..].ptr);

    value[0] = '\r';
    try std.testing.expectEqual(@as(u8, 'x'), iovecs[0].base[25]);
    try std.testing.expectEqualStrings(
        "body",
        iovecs[0].base[iovecs[0].len - 4 .. iovecs[0].len],
    );
}

test "body coalescing covers below at and above its boundary" {
    const body = @as([65]u8, @splat('b'));
    const lengths = [_]usize{ 63, 64, 65 };

    for (lengths) |length| {
        var response_buffer = ResponseBuffer{};
        const encoder = try Encoder.init(
            200,
            &.{},
            body[0..length],
            &response_buffer,
        );
        var iovec_buffer: IovecBuffer = undefined;
        const iovecs = encoder.remainingIovecs(&iovec_buffer);

        if (length <= 64) {
            try std.testing.expectEqual(@as(usize, 1), iovecs.len);
        } else {
            try std.testing.expectEqual(@as(usize, 2), iovecs.len);
            try std.testing.expectEqual(body[0..].ptr, iovecs[1].base);
            try std.testing.expectEqual(length, iovecs[1].len);
        }
    }
}

test "response head size covers below at and above maximum" {
    const fixed_length = "HTTP/1.1 200 \r\n".len +
        "X: ".len + "\r\n".len + "\r\n".len;
    const boundary_value_length = http1.maximum_head_bytes - fixed_length;
    const values = [_]usize{
        boundary_value_length - 1,
        boundary_value_length,
        boundary_value_length + 1,
    };
    var value: [http1.maximum_head_bytes]u8 = undefined;
    @memset(&value, 'x');
    var response_buffer = ResponseBuffer{};

    for (values, 0..) |length, index| {
        const headers = [_]Header{
            .{ .name = "X", .value = value[0..length] },
        };
        if (index < 2) {
            _ = try Encoder.init(200, &headers, "", &response_buffer);
        } else {
            try std.testing.expectError(
                error.HeaderSectionTooLarge,
                Encoder.init(200, &headers, "", &response_buffer),
            );
        }
    }
}

test "Encoder validates large values across SIMD boundaries" {
    var value = @as([4096]u8, @splat('x'));
    const headers = [_]Header{
        .{ .name = "X-Large", .value = &value },
    };
    var response_buffer = ResponseBuffer{};
    const invalid_positions = [_]usize{ 0, 15, 16, value.len - 1 };

    for (invalid_positions) |position| {
        value[position] = '\r';
        try std.testing.expectError(
            error.InvalidHeaderValue,
            Encoder.init(200, &headers, "", &response_buffer),
        );
        value[position] = 'x';
    }
}

test "Encoder rejects output aliasing every borrowed input class" {
    var response_buffer = ResponseBuffer{};
    @memset(&response_buffer.bytes, 'x');

    const name_headers = [_]Header{
        .{ .name = response_buffer.bytes[0..1], .value = "value" },
    };
    try std.testing.expectError(
        error.AliasingInput,
        Encoder.init(200, &name_headers, "", &response_buffer),
    );

    const value_headers = [_]Header{
        .{ .name = "X", .value = response_buffer.bytes[40..45] },
    };
    try std.testing.expectError(
        error.AliasingInput,
        Encoder.init(200, &value_headers, "", &response_buffer),
    );

    try std.testing.expectError(
        error.AliasingInput,
        Encoder.init(
            200,
            &.{},
            response_buffer.bytes[70..],
            &response_buffer,
        ),
    );
}

test "Encoder resumes from every partial-write byte boundary" {
    const headers = [_]Header{
        .{ .name = "X-Empty", .value = "" },
        .{ .name = "X-Test", .value = "value" },
    };
    const expected =
        "HTTP/1.1 201 \r\n" ++
        "X-Empty: \r\n" ++
        "X-Test: value\r\n" ++
        "\r\n" ++
        "body";

    for (0..expected.len + 1) |written| {
        var response_buffer = ResponseBuffer{};
        var encoder = try Encoder.init(201, &headers, "body", &response_buffer);
        try encoder.advance(written);

        var output: [128]u8 = undefined;
        const length = try appendRemaining(&encoder, &output);
        try std.testing.expectEqualStrings(expected[written..], output[0..length]);
        try std.testing.expectEqual(expected.len - written, encoder.remainingBytes());
        try std.testing.expectEqual(written == expected.len, encoder.isComplete());
    }
}

test "Encoder resumes within a borrowed body" {
    const body = @as([65]u8, @splat('b'));
    var response_buffer = ResponseBuffer{};
    var encoder = try Encoder.init(200, &.{}, &body, &response_buffer);

    var initial_iovec_buffer: IovecBuffer = undefined;
    const head_length = encoder.remainingIovecs(&initial_iovec_buffer)[0].len;
    try encoder.advance(head_length + 1);

    var remaining_iovec_buffer: IovecBuffer = undefined;
    const remaining = encoder.remainingIovecs(&remaining_iovec_buffer);
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectEqual(body[1..].ptr, remaining[0].base);
    try std.testing.expectEqual(body.len - 1, remaining[0].len);
}

test "Encoder rejects advancing beyond the remaining response" {
    var response_buffer = ResponseBuffer{};
    var encoder = try Encoder.init(204, &.{}, "", &response_buffer);
    const remaining = encoder.remainingBytes();

    try encoder.advance(remaining - 1);
    try encoder.advance(1);
    try std.testing.expect(encoder.isComplete());
    try std.testing.expectError(error.WriteBeyondEnd, encoder.advance(1));
}

test "caller-owned iovec snapshot survives Encoder move" {
    var response_buffer = ResponseBuffer{};
    var original = try Encoder.init(200, &.{}, "body", &response_buffer);
    var iovec_buffer: IovecBuffer = undefined;
    const snapshot = original.remainingIovecs(&iovec_buffer);
    const moved = original;
    original = undefined;

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 \r\n\r\nbody",
        snapshot[0].base[0..snapshot[0].len],
    );

    var output: [64]u8 = undefined;
    const length = try appendRemaining(&moved, &output);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 \r\n\r\nbody",
        output[0..length],
    );
}
