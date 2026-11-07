const std = @import("std");
const framing = @import("http1_response_framing");

test "response plan owns framing headers case insensitively" {
    const reserved = [_][]const u8{
        "Content-Length",
        "content-length",
        "TRANSFER-ENCODING",
        "Connection",
    };

    for (reserved) |name| {
        try std.testing.expectError(
            error.ApplicationControlsMessageFraming,
            framing.validateApplicationHeader(name),
        );
    }
    try framing.validateApplicationHeader("Content-Type");
}

test "synthetic headers cover omitted close and keep-alive connection policy" {
    const cases = [_]struct {
        connection: framing.ResponseConnection,
        expected_count: usize,
        expected_connection: ?[]const u8,
    }{
        .{
            .connection = framing.ResponseConnection.omit,
            .expected_count = 1,
            .expected_connection = null,
        },
        .{
            .connection = framing.ResponseConnection.close,
            .expected_count = 2,
            .expected_connection = "close",
        },
        .{
            .connection = framing.ResponseConnection.keep_alive,
            .expected_count = 2,
            .expected_connection = "keep-alive",
        },
    };

    for (cases) |case| {
        const plan = try framing.plan(
            200,
            123,
            case.connection,
            framing.RequestSemantics.regular,
        );
        var length_buffer: [20]u8 = undefined;
        var header_buffer: [2]framing.Header = undefined;
        const headers = plan.syntheticHeaders(
            &length_buffer,
            &header_buffer,
        );

        try std.testing.expectEqual(case.expected_count, headers.len);
        try std.testing.expectEqualStrings("Content-Length", headers[0].name);
        try std.testing.expectEqualStrings("123", headers[0].value);
        if (case.expected_connection) |expected| {
            try std.testing.expectEqualStrings("Connection", headers[1].name);
            try std.testing.expectEqualStrings(expected, headers[1].value);
        }
    }
}

test "statuses without message content reject body length boundaries" {
    const informational_statuses = [_]u16{ 100, 101, 198, 199 };
    for (informational_statuses) |status| {
        try std.testing.expectError(
            error.InformationalResponseUnsupported,
            framing.plan(
                status,
                0,
                framing.ResponseConnection.omit,
                framing.RequestSemantics.regular,
            ),
        );
    }

    const statuses = [_]u16{ 204, 304 };
    for (statuses) |status| {
        const plan = try framing.plan(
            status,
            0,
            framing.ResponseConnection.omit,
            framing.RequestSemantics.regular,
        );
        try std.testing.expect(!plan.transmit_body);
        var length_buffer: [20]u8 = undefined;
        var header_buffer: [2]framing.Header = undefined;
        try std.testing.expectEqual(
            @as(usize, 0),
            plan.syntheticHeaders(
                &length_buffer,
                &header_buffer,
            ).len,
        );
        try std.testing.expectError(
            error.BodyNotAllowedForStatus,
            framing.plan(
                status,
                1,
                framing.ResponseConnection.omit,
                framing.RequestSemantics.regular,
            ),
        );
    }

    _ = try framing.plan(
        200,
        1,
        framing.ResponseConnection.omit,
        framing.RequestSemantics.regular,
    );
}

test "HEAD preserves representation length and suppresses wire body" {
    const representation_lengths = [_]usize{ 0, 1 };

    for (representation_lengths) |representation_length| {
        const plan = try framing.plan(
            200,
            representation_length,
            framing.ResponseConnection.omit,
            framing.RequestSemantics.head,
        );

        try std.testing.expectEqual(representation_length, plan.body_length);
        try std.testing.expect(!plan.transmit_body);

        var length_buffer: [20]u8 = undefined;
        var header_buffer: [2]framing.Header = undefined;
        const headers = plan.syntheticHeaders(
            &length_buffer,
            &header_buffer,
        );
        try std.testing.expectEqual(@as(usize, 1), headers.len);
        try std.testing.expectEqualStrings(
            if (representation_length == 0) "0" else "1",
            headers[0].value,
        );
    }
}

test "streaming framing follows HTTP version and no-content semantics" {
    const http_1_1 = try framing.planStreaming(
        200,
        framing.HttpVersion.http_1_1,
        framing.ResponseConnection.omit,
        framing.RequestSemantics.regular,
    );
    try std.testing.expect(http_1_1.transmit_body);
    try std.testing.expect(http_1_1.chunked);
    var http_1_1_headers: [2]framing.Header = undefined;
    const chunked_headers = http_1_1.syntheticHeaders(&http_1_1_headers);
    try std.testing.expectEqual(@as(usize, 1), chunked_headers.len);
    try std.testing.expectEqualStrings(
        "Transfer-Encoding",
        chunked_headers[0].name,
    );

    const http_1_0 = try framing.planStreaming(
        200,
        framing.HttpVersion.http_1_0,
        framing.ResponseConnection.keep_alive,
        framing.RequestSemantics.regular,
    );
    try std.testing.expect(http_1_0.transmit_body);
    try std.testing.expect(!http_1_0.chunked);
    var http_1_0_headers: [2]framing.Header = undefined;
    const close_headers = http_1_0.syntheticHeaders(&http_1_0_headers);
    try std.testing.expectEqual(@as(usize, 1), close_headers.len);
    try std.testing.expectEqualStrings("close", close_headers[0].value);

    for ([_]u16{ 204, 304 }) |status| {
        const no_content = try framing.planStreaming(
            status,
            framing.HttpVersion.http_1_1,
            framing.ResponseConnection.omit,
            framing.RequestSemantics.regular,
        );
        try std.testing.expect(!no_content.transmit_body);
        try std.testing.expect(!no_content.chunked);
    }

    const head = try framing.planStreaming(
        200,
        framing.HttpVersion.http_1_1,
        framing.ResponseConnection.omit,
        framing.RequestSemantics.head,
    );
    try std.testing.expect(!head.transmit_body);
    try std.testing.expect(!head.chunked);
}

// 204/205 disallow content; the adjacent ordinary status 206 permits it.
// Empty content is the only accepted length for 205; one byte must fail.
test "205 has explicit zero framing for buffered and streaming responses" {
    const regular = framing.RequestSemantics.regular;
    const omit = framing.ResponseConnection.omit;
    const buffered = try framing.plan(205, 0, omit, regular);
    try std.testing.expect(!buffered.transmit_body);
    var lengths: [20]u8 = undefined;
    var headers: [2]framing.Header = undefined;
    const result = buffered.syntheticHeaders(&lengths, &headers);
    try std.testing.expectEqualStrings("Content-Length", result[0].name);
    try std.testing.expectEqualStrings("0", result[0].value);
    try std.testing.expectError(error.BodyNotAllowedForStatus, framing.plan(205, 1, omit, regular));
    try std.testing.expect((try framing.plan(206, 1, omit, regular)).transmit_body);
    for ([_]framing.HttpVersion{ framing.HttpVersion.http_1_0, framing.HttpVersion.http_1_1 }) |version| {
        const streaming = try framing.planStreaming(205, version, omit, regular);
        try std.testing.expect(!streaming.transmit_body);
        const stream_headers = streaming.syntheticHeaders(&headers);
        try std.testing.expectEqual(@as(usize, 1), stream_headers.len);
        try std.testing.expectEqualStrings("Content-Length", stream_headers[0].name);
        try std.testing.expectEqualStrings("0", stream_headers[0].value);
    }
}
