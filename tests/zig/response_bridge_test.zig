const std = @import("std");
const bridge = @import("bridge");

const TestEnvironment = struct {
    allocator: std.mem.Allocator,
    allocation_count: usize = 0,
    deallocation_count: usize = 0,
    live_allocations: usize = 0,

    fn rocHost(self: *TestEnvironment) bridge.RocHost {
        return .{
            .env = @ptrCast(self),
            .roc_alloc = allocate,
            .roc_dealloc = deallocate,
            .roc_realloc = reallocate,
            .roc_dbg = ignoreDiagnostic,
            .roc_expect_failed = ignoreDiagnostic,
            .roc_crashed = ignoreDiagnostic,
        };
    }

    fn allocate(
        roc_host: *bridge.RocHost,
        length: usize,
        alignment: usize,
    ) callconv(std.builtin.CallingConvention.c) *anyopaque {
        const self: *TestEnvironment = @ptrCast(
            @alignCast(roc_host.env),
        );
        const prefix_length = @max(alignment, @sizeOf(usize));
        const total_length = std.math.add(
            usize,
            prefix_length,
            length,
        ) catch @panic("out of memory");
        const allocation_alignment =
            std.mem.Alignment.fromByteUnits(
                @max(alignment, @alignOf(usize)),
            );
        const base = self.allocator.rawAlloc(
            total_length,
            allocation_alignment,
            @returnAddress(),
        ) orelse @panic("out of memory");
        const data = base + prefix_length;
        const stored_size: *usize = @ptrFromInt(
            @intFromPtr(data) - @sizeOf(usize),
        );
        stored_size.* = total_length;
        self.allocation_count += 1;
        self.live_allocations += 1;
        return data;
    }

    fn deallocate(
        roc_host: *bridge.RocHost,
        pointer: *anyopaque,
        alignment: usize,
    ) callconv(std.builtin.CallingConvention.c) void {
        const self: *TestEnvironment = @ptrCast(
            @alignCast(roc_host.env),
        );
        const prefix_length = @max(alignment, @sizeOf(usize));
        const data_address = @intFromPtr(pointer);
        const stored_size: *const usize = @ptrFromInt(
            data_address - @sizeOf(usize),
        );
        const base: [*]u8 = @ptrFromInt(
            data_address - prefix_length,
        );
        self.allocator.rawFree(
            base[0..stored_size.*],
            std.mem.Alignment.fromByteUnits(
                @max(alignment, @alignOf(usize)),
            ),
            @returnAddress(),
        );
        self.deallocation_count += 1;
        self.live_allocations -= 1;
    }

    fn reallocate(
        roc_host: *bridge.RocHost,
        pointer: *anyopaque,
        new_length: usize,
        alignment: usize,
    ) callconv(std.builtin.CallingConvention.c) *anyopaque {
        _ = roc_host;
        _ = pointer;
        _ = new_length;
        _ = alignment;
        @panic("the response bridge does not reallocate");
    }

    fn ignoreDiagnostic(
        roc_host: *bridge.RocHost,
        bytes: [*]const u8,
        length: usize,
    ) callconv(std.builtin.CallingConvention.c) void {
        _ = roc_host;
        _ = bytes;
        _ = length;
    }
};

const Writer = struct {
    output: []u8,
    length: usize = 0,
    maximum_write: usize = std.math.maxInt(usize),
    fail: bool = false,
    fail_after_calls: ?usize = null,
    calls: usize = 0,

    fn write(
        context: *anyopaque,
        iovecs: []const std.posix.iovec_const,
    ) bridge.ResponseWriteError!usize {
        const self: *Writer = @ptrCast(@alignCast(context));
        if (self.fail or
            (self.fail_after_calls != null and
                self.calls >= self.fail_after_calls.?))
        {
            return bridge.ResponseWriteError.WriteFailed;
        }
        self.calls += 1;

        var remaining = @min(
            self.maximum_write,
            self.output.len - self.length,
        );
        var written: usize = 0;
        for (iovecs) |iovec| {
            const count = @min(remaining, iovec.len);
            @memcpy(
                self.output[self.length + written ..][0..count],
                iovec.base[0..count],
            );
            written += count;
            remaining -= count;
            if (remaining == 0) break;
        }
        self.length += written;
        return written;
    }
};

fn responseBody(
    bytes: []const u8,
    roc_host: *bridge.RocHost,
) bridge.HttpResponseBody {
    var result: bridge.HttpResponseBody = undefined;
    if (bytes.len == 0) {
        result.tag = bridge.HttpResponseBodyTag.Empty;
        result.payload = std.mem.zeroes(@TypeOf(result.payload));
        return result;
    }

    const list = bridge.RocByteList.fromSlice(bytes, roc_host);
    result.tag = bridge.HttpResponseBodyTag.Bytes;
    const payload: *bridge.RocByteList = @ptrCast(
        @alignCast(&result.payload),
    );
    payload.* = list;
    return result;
}

fn makeResponse(
    status: u16,
    name: []const u8,
    value: []const u8,
    body: []const u8,
    roc_host: *bridge.RocHost,
) bridge.HttpResponse {
    const headers = bridge.HttpResponseHeaderList.allocate(
        1,
        roc_host,
    );
    headers.elements_ptr.?[0] = .{
        .name = bridge.GeneratedRocStr.fromSlice(name, roc_host),
        .value = bridge.GeneratedRocStr.fromSlice(value, roc_host),
    };

    return .{
        .headers = headers,
        .body = responseBody(body, roc_host),
        .status = status,
    };
}

test "response bridge validates encodes and releases after partial writes" {
    var environment = TestEnvironment{
        .allocator = std.testing.allocator,
    };
    var roc_host = environment.rocHost();
    const body = @as([80]u8, @splat('x'));
    const response = makeResponse(
        200,
        "x-response-header-longer-than-small",
        "a-response-value-longer-than-small",
        body[0..],
        &roc_host,
    );

    var response_buffer = bridge.ResponseBuffer{};
    var encoded = try bridge.OwnedResponseEncoder.init(
        response,
        &roc_host,
        &response_buffer,
    );
    var output: [512]u8 = undefined;
    var writer = Writer{
        .output = output[0..],
        .maximum_write = 7,
    };
    try encoded.sendAll(
        @ptrCast(&writer),
        Writer.write,
    );

    const expected_head =
        "HTTP/1.1 200 \r\n" ++
        "x-response-header-longer-than-small: " ++
        "a-response-value-longer-than-small\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(
        expected_head,
        output[0..expected_head.len],
    );
    try std.testing.expectEqualSlices(
        u8,
        body[0..],
        output[expected_head.len..writer.length],
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        environment.live_allocations,
    );
    try std.testing.expectEqual(
        environment.allocation_count,
        environment.deallocation_count,
    );
}

test "framed response bridge owns length connection and protocol version" {
    var environment = TestEnvironment{
        .allocator = std.testing.allocator,
    };
    var roc_host = environment.rocHost();
    const response = makeResponse(
        200,
        "Content-Type",
        "text/plain",
        "hello",
        &roc_host,
    );

    var response_buffer = bridge.ResponseBuffer{};
    var encoded = try bridge.OwnedResponseEncoder.initForRequest(
        response,
        &roc_host,
        &response_buffer,
        bridge.ResponseHttpVersion.http_1_0,
        bridge.ResponseConnection.keep_alive,
        bridge.ResponseRequestSemantics.regular,
        null,
    );
    var output: [256]u8 = undefined;
    var writer = Writer{ .output = output[0..] };
    try encoded.sendAll(@ptrCast(&writer), Writer.write);

    try std.testing.expectEqualStrings(
        "HTTP/1.0 200 \r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 5\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n" ++
            "hello",
        output[0..writer.length],
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        environment.live_allocations,
    );
}

test "framed response bridge suppresses HEAD body but preserves its length" {
    var environment = TestEnvironment{
        .allocator = std.testing.allocator,
    };
    var roc_host = environment.rocHost();
    const response = makeResponse(
        200,
        "Content-Type",
        "text/plain",
        "hello",
        &roc_host,
    );

    var response_buffer = bridge.ResponseBuffer{};
    var encoded = try bridge.OwnedResponseEncoder.initForRequest(
        response,
        &roc_host,
        &response_buffer,
        bridge.ResponseHttpVersion.http_1_1,
        bridge.ResponseConnection.close,
        bridge.ResponseRequestSemantics.head,
        null,
    );
    var output: [256]u8 = undefined;
    var writer = Writer{ .output = output[0..] };
    try encoded.sendAll(@ptrCast(&writer), Writer.write);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 \r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 5\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        output[0..writer.length],
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        environment.live_allocations,
    );
}

test "framed response bridge rejects application framing and releases ownership" {
    var environment = TestEnvironment{
        .allocator = std.testing.allocator,
    };
    var roc_host = environment.rocHost();
    const response = makeResponse(
        200,
        "Content-Length",
        "5",
        "hello",
        &roc_host,
    );
    var response_buffer = bridge.ResponseBuffer{};

    try std.testing.expectError(
        error.ApplicationControlsMessageFraming,
        bridge.OwnedResponseEncoder.initForRequest(
            response,
            &roc_host,
            &response_buffer,
            bridge.ResponseHttpVersion.http_1_1,
            bridge.ResponseConnection.omit,
            bridge.ResponseRequestSemantics.regular,
            null,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        environment.live_allocations,
    );
    try std.testing.expectEqual(
        environment.allocation_count,
        environment.deallocation_count,
    );
}

test "response bridge rejects unsafe responses before writing and releases them" {
    const cases = [_]struct {
        status: u16,
        name: []const u8,
        value: []const u8,
        expected: bridge.ResponseEncodeError,
    }{
        .{ .status = 99, .name = "x", .value = "ok", .expected = error.InvalidStatus },
        .{ .status = 600, .name = "x", .value = "ok", .expected = error.InvalidStatus },
        .{ .status = 200, .name = "", .value = "ok", .expected = error.InvalidHeaderName },
        .{ .status = 200, .name = "bad name", .value = "ok", .expected = error.InvalidHeaderName },
        .{ .status = 200, .name = "x", .value = "bad\r\nvalue", .expected = error.InvalidHeaderValue },
    };

    for (cases) |case| {
        var environment = TestEnvironment{
            .allocator = std.testing.allocator,
        };
        var roc_host = environment.rocHost();
        const response = makeResponse(
            case.status,
            case.name,
            case.value,
            "body",
            &roc_host,
        );
        var response_buffer = bridge.ResponseBuffer{};

        try std.testing.expectError(
            case.expected,
            bridge.OwnedResponseEncoder.init(
                response,
                &roc_host,
                &response_buffer,
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            environment.live_allocations,
        );
        try std.testing.expectEqual(
            environment.allocation_count,
            environment.deallocation_count,
        );
    }
}

test "response bridge releases ownership on write failure boundaries" {
    const cases = [_]struct {
        fail: bool,
        maximum_write: usize,
        expected: bridge.ResponseWriteError,
    }{
        .{
            .fail = true,
            .maximum_write = std.math.maxInt(usize),
            .expected = error.WriteFailed,
        },
        .{
            .fail = false,
            .maximum_write = 0,
            .expected = error.WriteZero,
        },
    };

    for (cases) |case| {
        var environment = TestEnvironment{
            .allocator = std.testing.allocator,
        };
        var roc_host = environment.rocHost();
        const response = makeResponse(
            200,
            "x-header-name-longer-than-small",
            "x-header-value-longer-than-small",
            "a-response-body-longer-than-small",
            &roc_host,
        );
        var response_buffer = bridge.ResponseBuffer{};
        var encoded = try bridge.OwnedResponseEncoder.init(
            response,
            &roc_host,
            &response_buffer,
        );
        var output: [256]u8 = undefined;
        var writer = Writer{
            .output = output[0..],
            .maximum_write = case.maximum_write,
            .fail = case.fail,
        };

        try std.testing.expectError(
            case.expected,
            encoded.sendAll(
                @ptrCast(&writer),
                Writer.write,
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            environment.live_allocations,
        );
        try std.testing.expectEqual(
            environment.allocation_count,
            environment.deallocation_count,
        );
    }
}

test "response bridge uses generated decref for seamless slices" {
    var environment = TestEnvironment{
        .allocator = std.testing.allocator,
    };
    var roc_host = environment.rocHost();

    const owned_value = bridge.GeneratedRocStr.fromSlice(
        "prefix-seamless-header-value-suffix",
        &roc_host,
    );
    var sliced_value = owned_value;
    sliced_value.bytes = owned_value.bytes.? + "prefix-".len;
    sliced_value.length = "seamless-header-value".len;
    sliced_value.capacity_or_alloc_ptr =
        @intFromPtr(owned_value.bytes.?) | 1;

    const owned_body = bridge.RocByteList.fromSlice(
        "prefix-seamless-response-body-suffix",
        &roc_host,
    );
    var sliced_body = owned_body;
    sliced_body.elements_ptr =
        owned_body.elements_ptr.? + "prefix-".len;
    sliced_body.length = "seamless-response-body".len;
    sliced_body.capacity_or_alloc_ptr =
        @intFromPtr(owned_body.elements_ptr.?) | 1;

    const headers = bridge.HttpResponseHeaderList.allocate(
        1,
        &roc_host,
    );
    headers.elements_ptr.?[0] = .{
        .name = bridge.GeneratedRocStr.fromSlice(
            "x-seamless",
            &roc_host,
        ),
        .value = sliced_value,
    };
    var body: bridge.HttpResponseBody = undefined;
    body.tag = bridge.HttpResponseBodyTag.Bytes;
    const body_payload: *bridge.RocByteList = @ptrCast(
        @alignCast(&body.payload),
    );
    body_payload.* = sliced_body;
    const response = bridge.HttpResponse{
        .headers = headers,
        .body = body,
        .status = 200,
    };

    var response_buffer = bridge.ResponseBuffer{};
    var encoded = try bridge.OwnedResponseEncoder.init(
        response,
        &roc_host,
        &response_buffer,
    );
    var output: [256]u8 = undefined;
    var writer = Writer{ .output = output[0..] };
    try encoded.sendAll(@ptrCast(&writer), Writer.write);

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            output[0..writer.length],
            "x-seamless: seamless-header-value\r\n",
        ) != null,
    );
    try std.testing.expect(
        std.mem.endsWith(
            u8,
            output[0..writer.length],
            "seamless-response-body",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        environment.live_allocations,
    );
    try std.testing.expectEqual(
        environment.allocation_count,
        environment.deallocation_count,
    );
}

test "host Date is supplied only when application Date is absent" {
    for ([_][]const u8{ "x-test", "dAtE" }) |name| {
        var environment = TestEnvironment{ .allocator = std.testing.allocator };
        var roc_host = environment.rocHost();
        const response = makeResponse(200, name, "Thu, 01 Jan 1970 00:00:00 GMT", "body", &roc_host);
        var buffer = bridge.ResponseBuffer{};
        var sender = try bridge.OwnedResponseEncoder.initForRequest(response, &roc_host, &buffer, bridge.ResponseHttpVersion.http_1_1, bridge.ResponseConnection.close, bridge.ResponseRequestSemantics.regular, "Fri, 02 Jan 1970 00:00:00 GMT");
        var output: [256]u8 = undefined;
        var writer = Writer{ .output = &output };
        try sender.sendAll(@ptrCast(&writer), Writer.write);
        const found = std.mem.indexOf(u8, output[0..writer.length], "Date: Fri, 02 Jan 1970");
        try std.testing.expect((found != null) == std.mem.eql(u8, name, "x-test"));
        try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
    }
}

test "host diagnostic fields follow Date in buffered and written heads" {
    const extra = [_]bridge.ResponseExtraHeader{
        .{ .name = "X-Roxum-Dbg", .value = "\"a\"" },
        .{ .name = "X-Roxum-Dbg", .value = "%0A" },
    };
    {
        var environment = TestEnvironment{ .allocator = std.testing.allocator };
        var roc_host = environment.rocHost();
        const response = makeResponse(200, "x-test", "1", "body", &roc_host);
        var buffer = bridge.ResponseBuffer{};
        var scratch = bridge.HeadScratch{};
        var sender = try bridge.OwnedResponseEncoder.initForRequestWithExtra(response, &roc_host, &buffer, &scratch, bridge.ResponseHttpVersion.http_1_1, bridge.ResponseConnection.omit, bridge.ResponseRequestSemantics.regular, "Fri, 02 Jan 1970 00:00:00 GMT", &extra);
        var output: [256]u8 = undefined;
        var writer = Writer{ .output = &output };
        try sender.sendAll(@ptrCast(&writer), Writer.write);
        try std.testing.expectEqualStrings(
            "HTTP/1.1 200 \r\nx-test: 1\r\nContent-Length: 4\r\nDate: Fri, 02 Jan 1970 00:00:00 GMT\r\nX-Roxum-Dbg: \"a\"\r\nX-Roxum-Dbg: %0A\r\n\r\nbody",
            output[0..writer.length],
        );
        try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
    }
    {
        // The head of a written body carries them too.
        var environment = TestEnvironment{ .allocator = std.testing.allocator };
        var roc_host = environment.rocHost();
        var response = makeResponse(205, "x-test", "1", "", &roc_host);
        defer response.decref(&roc_host);
        response.status = 205;
        var buffer = bridge.ResponseBuffer{};
        var scratch = bridge.HeadScratch{};
        var head = try bridge.WrittenHead.init(&response, &buffer, &scratch, bridge.ResponseHttpVersion.http_1_1, bridge.ResponseConnection.omit, bridge.ResponseRequestSemantics.regular, null, extra[0..1], null);
        var output: [256]u8 = undefined;
        var writer = Writer{ .output = &output };
        try head.send(@ptrCast(&writer), Writer.write);
        try std.testing.expect(!head.transmit_body);
        try std.testing.expectEqualStrings("HTTP/1.1 205 \r\nx-test: 1\r\nContent-Length: 0\r\nX-Roxum-Dbg: \"a\"\r\n\r\n", output[0..writer.length]);
    }
}

test "a written body is chunked on HTTP/1.1 and sent as it is on HTTP/1.0" {
    const Case = struct {
        version: bridge.ResponseHttpVersion,
        semantics: bridge.ResponseRequestSemantics,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{
            .version = bridge.ResponseHttpVersion.http_1_1,
            .semantics = bridge.ResponseRequestSemantics.regular,
            .expected = "HTTP/1.1 200 \r\nx-test: 1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n",
        },
        .{
            .version = bridge.ResponseHttpVersion.http_1_0,
            .semantics = bridge.ResponseRequestSemantics.regular,
            .expected = "HTTP/1.0 200 \r\nx-test: 1\r\nConnection: close\r\n\r\nabcde",
        },
        .{
            .version = bridge.ResponseHttpVersion.http_1_1,
            .semantics = bridge.ResponseRequestSemantics.head,
            .expected = "HTTP/1.1 200 \r\nx-test: 1\r\n\r\n",
        },
    };
    for (cases) |case| {
        var environment = TestEnvironment{ .allocator = std.testing.allocator };
        var roc_host = environment.rocHost();
        const response = makeResponse(200, "x-test", "1", "ignored", &roc_host);
        defer response.decref(&roc_host);
        var buffer = bridge.ResponseBuffer{};
        var scratch = bridge.HeadScratch{};
        var head = try bridge.WrittenHead.init(&response, &buffer, &scratch, case.version, bridge.ResponseConnection.omit, case.semantics, null, &.{}, null);
        var output: [256]u8 = undefined;
        var writer = Writer{ .output = &output };
        try head.send(@ptrCast(&writer), Writer.write);
        if (head.transmit_body) {
            // Empty bytes write nothing: an empty chunk would end the body.
            for ([_][]const u8{ "abc", "", "de" }) |part| try bridge.writeBodyPart(@ptrCast(&writer), Writer.write, part, head.chunked);
            if (head.chunked) try bridge.writeBodyEnd(@ptrCast(&writer), Writer.write);
        }
        try std.testing.expectEqualStrings(case.expected, output[0..writer.length]);
        try std.testing.expectEqual(case.version == bridge.ResponseHttpVersion.http_1_0, head.force_connection_close);
    }
}

test "HTTP/2 response owns normalized fields and preserves duplicate values until release" {
    var environment = TestEnvironment{ .allocator = std.testing.allocator };
    var host = environment.rocHost();
    const headers = bridge.HttpResponseHeaderList.allocate(2, &host);
    for (headers.elements_ptr.?[0..2], 0..) |*field, index| field.* = .{
        .name = bridge.GeneratedRocStr.fromSlice("Set-Cookie", &host),
        .value = bridge.GeneratedRocStr.fromSlice(if (index == 0) "a=1" else "second-cookie-with-a-value-longer-than-small-string", &host),
    };
    var response = try bridge.OwnedHttp2Response.init(.{ .status = 200, .headers = headers, .body = responseBody("payload", &host) }, &host, std.testing.allocator, bridge.ResponseRequestSemantics.regular, .{ .header_bytes = 1024, .body_bytes = 16 });
    // Moving the owner must not leave views into its previous stack location.
    var moved = response;
    response = undefined;
    try std.testing.expectEqualStrings("set-cookie", moved.headers[0].name);
    try std.testing.expectEqualStrings("a=1", moved.headers[0].value);
    try std.testing.expectEqualStrings("set-cookie", moved.headers[1].name);
    try std.testing.expectEqualStrings("second-cookie-with-a-value-longer-than-small-string", moved.headers[1].value);
    try std.testing.expectEqualStrings("content-length", moved.headers[2].name);
    try std.testing.expectEqualStrings("7", moved.headers[2].value);
    try std.testing.expectEqualStrings("payload", moved.body);
    moved.deinit();
    try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
}

test "HTTP/2 response retains HEAD length and rejects bodies on forbidden statuses" {
    var environment = TestEnvironment{ .allocator = std.testing.allocator };
    var host = environment.rocHost();
    var head = try bridge.OwnedHttp2Response.init(makeResponse(200, "x", "y", "body", &host), &host, std.testing.allocator, bridge.ResponseRequestSemantics.head, .{ .header_bytes = 1024, .body_bytes = 16 });
    try std.testing.expectEqual(@as(usize, 0), head.body.len);
    try std.testing.expectEqualStrings("4", head.headers[1].value);
    head.deinit();
    for ([_]u16{ 204, 205, 304 }) |status| {
        var empty = try bridge.OwnedHttp2Response.init(makeResponse(status, "x", "y", "", &host), &host, std.testing.allocator, bridge.ResponseRequestSemantics.regular, .{ .header_bytes = 1024, .body_bytes = 16 });
        try std.testing.expectEqual(@as(usize, if (status == 205) 2 else 1), empty.headers.len);
        if (status == 205) try std.testing.expectEqualStrings("0", empty.headers[1].value);
        empty.deinit();
        for ([_]bridge.ResponseRequestSemantics{ bridge.ResponseRequestSemantics.regular, bridge.ResponseRequestSemantics.head }) |semantics| {
            try std.testing.expectError(error.BodyNotAllowedForStatus, bridge.OwnedHttp2Response.init(makeResponse(status, "x", "y", "body", &host), &host, std.testing.allocator, semantics, .{ .header_bytes = 1024, .body_bytes = 16 }));
        }
    }
    try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
}

test "HTTP/2 response rejects invalid status and fields while consuming Roc ownership" {
    var environment = TestEnvironment{ .allocator = std.testing.allocator };
    var host = environment.rocHost();
    for ([_]u16{ 199, 200, 201, 598, 599, 600 }) |status| {
        const result = bridge.OwnedHttp2Response.init(makeResponse(status, "x", "y", "", &host), &host, std.testing.allocator, bridge.ResponseRequestSemantics.regular, .{ .header_bytes = 1024, .body_bytes = 16 });
        if (status < 200 or status > 599) {
            try std.testing.expectError(error.InvalidStatus, result);
        } else {
            var response = try result;
            response.deinit();
        }
    }
    for ([_][]const u8{ "Content-Length", "TRANSFER-Encoding", "Connection" }) |name| {
        try std.testing.expectError(error.ApplicationControlsMessageFraming, bridge.OwnedHttp2Response.init(makeResponse(200, name, "x", "", &host), &host, std.testing.allocator, bridge.ResponseRequestSemantics.regular, .{ .header_bytes = 1024, .body_bytes = 16 }));
    }
    for ([_][]const u8{ "", ":status", "bad name", "Keep-Alive", "Proxy-Connection", "Upgrade", "TE" }) |name| {
        try std.testing.expectError(error.InvalidHeaders, bridge.OwnedHttp2Response.init(makeResponse(200, name, "x", "", &host), &host, std.testing.allocator, bridge.ResponseRequestSemantics.regular, .{ .header_bytes = 1024, .body_bytes = 16 }));
    }
    for ([_][]const u8{ "\r", "\n", "\x00", "\x7f", " leading", "trailing ", "\tleading", "trailing\t" }) |value| {
        try std.testing.expectError(error.InvalidHeaders, bridge.OwnedHttp2Response.init(makeResponse(200, "x", value, "", &host), &host, std.testing.allocator, bridge.ResponseRequestSemantics.regular, .{ .header_bytes = 1024, .body_bytes = 16 }));
    }
    try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
}

test "HTTP/2 response field count header bytes and body limits include synthetic fields" {
    var environment = TestEnvironment{ .allocator = std.testing.allocator };
    var host = environment.rocHost();
    for ([_]usize{ 62, 63, 64 }) |count| {
        const headers = bridge.HttpResponseHeaderList.allocate(count, &host);
        for (headers.elements_ptr.?[0..count]) |*field| field.* = .{ .name = bridge.GeneratedRocStr.fromSlice("x", &host), .value = bridge.GeneratedRocStr.fromSlice("y", &host) };
        const result = bridge.OwnedHttp2Response.init(.{ .status = 200, .headers = headers, .body = responseBody("", &host) }, &host, std.testing.allocator, bridge.ResponseRequestSemantics.regular, .{ .header_bytes = 4096, .body_bytes = 16 });
        if (count == 64) {
            try std.testing.expectError(error.LimitExceeded, result);
        } else {
            var response = try result;
            try std.testing.expectEqual(count + 1, response.headers.len);
            response.deinit();
        }
    }
    // :status (42), x:y (34), content-length:0 (47) total 123.
    for ([_]usize{ 122, 123, 124 }) |limit| {
        const result = bridge.OwnedHttp2Response.init(makeResponse(200, "x", "y", "", &host), &host, std.testing.allocator, bridge.ResponseRequestSemantics.regular, .{ .header_bytes = limit, .body_bytes = 16 });
        if (limit < 123) {
            try std.testing.expectError(error.LimitExceeded, result);
        } else {
            var response = try result;
            response.deinit();
        }
    }
    for ([_]usize{ 3, 4, 5 }) |size| {
        const result = bridge.OwnedHttp2Response.init(makeResponse(200, "x", "y", "12345"[0..size], &host), &host, std.testing.allocator, bridge.ResponseRequestSemantics.regular, .{ .header_bytes = 1024, .body_bytes = 4 });
        if (size > 4) {
            try std.testing.expectError(error.LimitExceeded, result);
        } else {
            var response = try result;
            response.deinit();
        }
    }
    try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
}

test "HTTP/2 response rolls back each scratch allocation failure and releases Roc values" {
    for (0..3) |fail_index| {
        var environment = TestEnvironment{ .allocator = std.testing.allocator };
        var host = environment.rocHost();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const result = bridge.OwnedHttp2Response.init(makeResponse(200, "Long-Header-Name-For-Ownership", "long-value-to-exercise-Roc-ownership", "body", &host), &host, failing.allocator(), bridge.ResponseRequestSemantics.regular, .{ .header_bytes = 1024, .body_bytes = 16 });
        if (fail_index < 2) {
            try std.testing.expectError(error.OutOfMemory, result);
        } else {
            var response = try result;
            response.deinit();
        }
        try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
    }
}
