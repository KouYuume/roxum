const std = @import("std");
const bridge = @import("bridge");

const TestEnvironment = struct {
    allocator: std.mem.Allocator,
    allocation_attempts: usize = 0,
    live_allocations: usize = 0,
    fail_index: ?usize = null,

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

    fn requestHost(roc_host: *bridge.RocHost) bridge.RequestHost {
        return .{ .roc_host = roc_host, .try_alloc = tryAllocate };
    }

    fn allocate(
        roc_host: *bridge.RocHost,
        length: usize,
        alignment: usize,
    ) callconv(std.builtin.CallingConvention.c) *anyopaque {
        return tryAllocate(roc_host, length, alignment) orelse
            @panic("out of memory");
    }

    fn tryAllocate(
        roc_host: *bridge.RocHost,
        length: usize,
        alignment: usize,
    ) ?*anyopaque {
        const self: *TestEnvironment = @ptrCast(
            @alignCast(roc_host.env),
        );
        const attempt = self.allocation_attempts;
        self.allocation_attempts += 1;
        if (self.fail_index) |fail_index| {
            if (attempt == fail_index) return null;
        }

        const prefix_length = @max(
            alignment,
            @sizeOf(usize),
        );
        const total_length = std.math.add(
            usize,
            prefix_length,
            length,
        ) catch return null;
        const allocation_alignment =
            std.mem.Alignment.fromByteUnits(
                @max(alignment, @alignOf(usize)),
            );
        const base = self.allocator.rawAlloc(
            total_length,
            allocation_alignment,
            @returnAddress(),
        ) orelse return null;
        const data = base + prefix_length;
        const stored_size: *usize = @ptrFromInt(
            @intFromPtr(data) - @sizeOf(usize),
        );
        stored_size.* = total_length;
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
        const prefix_length = @max(
            alignment,
            @sizeOf(usize),
        );
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
        @panic("the request bridge does not reallocate");
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

const Parsed = struct {
    parser: bridge.Parser,
    request_line: bridge.RequestLine,
    head_length: usize,
};

fn parse(input: []const u8) !Parsed {
    var parser = bridge.Parser{};
    const result = parser.feed(input);
    const completion = switch (result) {
        .head_complete => |value| value,
        .need_more => return error.IncompleteRequest,
        .err => return error.InvalidRequest,
    };
    return .{
        .request_line = parser.requestLine() orelse
            return error.MissingRequestLine,
        .head_length = completion.head_length,
        .parser = parser,
    };
}

fn stringBytes(value: anytype) []const u8 {
    return value.asU8ptr()[0..value.len()];
}

test "request bridge constructs normalized owned request" {
    const input =
        "POST /echo?name=roc HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Trace: \xffid\r\n" ++
        "Content-Length: 3\r\n" ++
        "\r\n" ++
        "abc";
    const parsed = try parse(input);

    var environment = TestEnvironment{
        .allocator = std.testing.allocator,
    };
    var roc_host = environment.rocHost();
    const request = try bridge.requestFromParsed(
        input,
        parsed.request_line,
        parsed.parser.headers(),
        input[parsed.head_length..],
        .{ .v4 = .{
            .octets = .{ 127, 0, 0, 1 },
            .port = 54321,
        } },
        "9f86d081884c7d659a2feaa0c55ad015",
        TestEnvironment.requestHost(&roc_host),
    );
    defer request.decref(&roc_host);

    try std.testing.expectEqual(
        bridge.HttpMethod.post,
        request.method,
    );
    try std.testing.expectEqualStrings(
        "/echo?name=roc",
        request.raw_target.items(),
    );
    try std.testing.expectEqualStrings(
        "/echo",
        stringBytes(&request.path),
    );
    try std.testing.expectEqualStrings(
        "name=roc",
        request.query.items(),
    );

    const headers = request.headers.items();
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings(
        "host",
        stringBytes(&headers[0].name),
    );
    try std.testing.expectEqualStrings(
        "x-trace",
        stringBytes(&headers[1].name),
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xff, 'i', 'd' },
        headers[1].value.items(),
    );
    try std.testing.expectEqualStrings(
        "abc",
        request.body.payload_bytes().items(),
    );
    try std.testing.expectEqual(@as(u16, 54321), request.remote_addr.payload_tcp().port);
    try std.testing.expectEqualStrings("9f86d081884c7d659a2feaa0c55ad015", request.request_id.asSlice());
}

test "request bridge classifies exactly the supported method set" {
    const cases = [_]struct {
        method: []const u8,
        target: []const u8,
        expected: bridge.HttpMethod,
    }{
        .{ .method = "OPTIONS", .target = "*", .expected = bridge.HttpMethod.options },
        .{ .method = "GET", .target = "/", .expected = bridge.HttpMethod.get },
        .{ .method = "HEAD", .target = "/", .expected = bridge.HttpMethod.head },
        .{ .method = "POST", .target = "/", .expected = bridge.HttpMethod.post },
        .{ .method = "PUT", .target = "/", .expected = bridge.HttpMethod.put },
        .{ .method = "DELETE", .target = "/", .expected = bridge.HttpMethod.delete },
        .{ .method = "PATCH", .target = "/", .expected = bridge.HttpMethod.patch },
        .{ .method = "QUERY", .target = "/", .expected = bridge.HttpMethod.query },
    };

    for (cases) |case| {
        var input_buffer: [128]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &input_buffer,
            "{s} {s} HTTP/1.1\r\nHost: x\r\n\r\n",
            .{ case.method, case.target },
        );
        const parsed = try parse(input);
        var environment = TestEnvironment{
            .allocator = std.testing.allocator,
        };
        var roc_host = environment.rocHost();
        const request = try bridge.requestFromParsed(
            input,
            parsed.request_line,
            parsed.parser.headers(),
            &.{},
            .{ .v4 = .{
                .octets = .{ 127, 0, 0, 1 },
                .port = 1,
            } },
            "9f86d081884c7d659a2feaa0c55ad015",
            TestEnvironment.requestHost(&roc_host),
        );
        try std.testing.expectEqual(
            case.expected,
            request.method,
        );
        request.decref(&roc_host);
        try std.testing.expectEqual(
            @as(usize, 0),
            environment.live_allocations,
        );
    }
}

test "request bridge rejects unsupported method before allocating" {
    const cases = [_][]const u8{
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "TRACE / HTTP/1.1\r\nHost: x\r\n\r\n",
        "CUSTOM / HTTP/1.1\r\nHost: x\r\n\r\n",
    };

    for (cases) |input| {
        const parsed = try parse(input);
        var environment = TestEnvironment{
            .allocator = std.testing.allocator,
        };
        var roc_host = environment.rocHost();
        try std.testing.expectError(
            error.UnsupportedMethod,
            bridge.requestFromParsed(
                input,
                parsed.request_line,
                parsed.parser.headers(),
                &.{},
                .{ .v4 = .{
                    .octets = .{ 127, 0, 0, 1 },
                    .port = 1,
                } },
                "9f86d081884c7d659a2feaa0c55ad015",
                TestEnvironment.requestHost(&roc_host),
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            environment.allocation_attempts,
        );
    }
}

test "request bridge rejects structural path hazards before allocating" {
    const cases = [_]struct {
        path: []const u8,
        valid: bool,
    }{
        // Ordinary one-segment path and trailing slash are valid boundaries.
        .{ .path = "/a", .valid = true },
        .{ .path = "/a/", .valid = true },
        // Exact dot segments are rejected at the root and between valid segments.
        .{ .path = "/.", .valid = false },
        .{ .path = "/..", .valid = false },
        .{ .path = "/a/./b", .valid = false },
        .{ .path = "/a/../b", .valid = false },
        // An empty interior segment is rejected; one slash remains valid.
        .{ .path = "//", .valid = false },
        .{ .path = "/", .valid = true },
        // Three dots and dots within names are data, unlike one or two dots.
        .{ .path = "/...", .valid = true },
        .{ .path = "/a.b", .valid = true },
        .{ .path = "/a/.", .valid = false },
        .{ .path = "/a/..", .valid = false },
        .{ .path = "/a/.../", .valid = true },
        // Duplicate delimiters are invalid at the start, middle, or end.
        .{ .path = "///", .valid = false },
        .{ .path = "/a//b", .valid = false },
        .{ .path = "/a//", .valid = false },
        .{ .path = "/a/b/", .valid = true },
        // Query bytes are outside the path validation domain.
        .{ .path = "/?a=//../", .valid = true },
        // Encoded dots and slashes remain data until Router capture decoding.
        .{ .path = "/%2E%2E", .valid = true },
        .{ .path = "/a%2Fb", .valid = true },
    };

    for (cases) |case| {
        var input_buffer: [128]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &input_buffer,
            "GET {s} HTTP/1.1\r\nHost: x\r\n\r\n",
            .{case.path},
        );
        const parsed = try parse(input);
        var environment = TestEnvironment{
            .allocator = std.testing.allocator,
        };
        var roc_host = environment.rocHost();
        const result = bridge.requestFromParsed(
            input,
            parsed.request_line,
            parsed.parser.headers(),
            &.{},
            .{ .v4 = .{
                .octets = .{ 127, 0, 0, 1 },
                .port = 1,
            } },
            "9f86d081884c7d659a2feaa0c55ad015",
            TestEnvironment.requestHost(&roc_host),
        );

        if (case.valid) {
            const request = try result;
            request.decref(&roc_host);
        } else {
            try std.testing.expectError(error.InvalidTarget, result);
        }
        try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
    }
}

test "request bridge constructs empty optional request fields" {
    const input = "GET / HTTP/1.0\r\n\r\n";
    const parsed = try parse(input);
    var environment = TestEnvironment{
        .allocator = std.testing.allocator,
    };
    var roc_host = environment.rocHost();

    const request = try bridge.requestFromParsed(
        input,
        parsed.request_line,
        parsed.parser.headers(),
        &.{},
        .{ .v4 = .{
            .octets = .{ 0, 0, 0, 0 },
            .port = 0,
        } },
        "9f86d081884c7d659a2feaa0c55ad015",
        TestEnvironment.requestHost(&roc_host),
    );
    defer request.decref(&roc_host);

    try std.testing.expectEqual(
        @as(usize, 0),
        request.query.len(),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        request.headers.len(),
    );
    try std.testing.expectEqual(
        bridge.HttpRequestBodyTag.Empty,
        request.body.tag,
    );
    try std.testing.expectEqual(
        bridge.HttpMethod.get,
        request.method,
    );
}

test "request bridge validates every parser span before use" {
    const input = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    const parsed = try parse(input);
    const maximum_offset = std.math.maxInt(u32);

    var invalid_method = parsed.request_line;
    invalid_method.method.start = maximum_offset;

    var invalid_target = parsed.request_line;
    invalid_target.target.start = maximum_offset;

    const invalid_name = [_]bridge.Header{.{
        .name = .{ .start = maximum_offset, .len = 0 },
        .value = .{ .start = 0, .len = 0 },
    }};
    const invalid_value = [_]bridge.Header{.{
        .name = .{ .start = 0, .len = 3 },
        .value = .{ .start = maximum_offset, .len = 0 },
    }};

    const cases = [_]struct {
        request_line: bridge.RequestLine,
        headers: []const bridge.Header,
    }{
        .{
            .request_line = invalid_method,
            .headers = parsed.parser.headers(),
        },
        .{
            .request_line = invalid_target,
            .headers = parsed.parser.headers(),
        },
        .{
            .request_line = parsed.request_line,
            .headers = &invalid_name,
        },
        .{
            .request_line = parsed.request_line,
            .headers = &invalid_value,
        },
    };

    for (cases) |case| {
        var environment = TestEnvironment{
            .allocator = std.testing.allocator,
        };
        var roc_host = environment.rocHost();

        try std.testing.expectError(
            error.InvalidSpan,
            bridge.requestFromParsed(
                input,
                case.request_line,
                case.headers,
                &.{},
                .{ .v4 = .{
                    .octets = .{ 127, 0, 0, 1 },
                    .port = 1,
                } },
                "9f86d081884c7d659a2feaa0c55ad015",
                TestEnvironment.requestHost(&roc_host),
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            environment.live_allocations,
        );
    }
}

test "request bridge validates span end boundary" {
    const input = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    const parsed = try parse(input);
    var environment = TestEnvironment{
        .allocator = std.testing.allocator,
    };
    var roc_host = environment.rocHost();

    const below_headers = [_]bridge.Header{.{
        .name = .{ .start = 0, .len = 3 },
        .value = .{
            .start = @intCast(input.len - 1),
            .len = 1,
        },
    }};
    const below_request = try bridge.requestFromParsed(
        input,
        parsed.request_line,
        &below_headers,
        &.{},
        .{ .v4 = .{
            .octets = .{ 127, 0, 0, 1 },
            .port = 1,
        } },
        "9f86d081884c7d659a2feaa0c55ad015",
        TestEnvironment.requestHost(&roc_host),
    );
    below_request.decref(&roc_host);

    const boundary_headers = [_]bridge.Header{.{
        .name = .{ .start = 0, .len = 3 },
        .value = .{
            .start = @intCast(input.len),
            .len = 0,
        },
    }};
    const boundary_request = try bridge.requestFromParsed(
        input,
        parsed.request_line,
        &boundary_headers,
        &.{},
        .{ .v4 = .{
            .octets = .{ 127, 0, 0, 1 },
            .port = 1,
        } },
        "9f86d081884c7d659a2feaa0c55ad015",
        TestEnvironment.requestHost(&roc_host),
    );
    boundary_request.decref(&roc_host);

    const above_headers = [_]bridge.Header{.{
        .name = .{ .start = 0, .len = 3 },
        .value = .{
            .start = @intCast(input.len),
            .len = 1,
        },
    }};
    try std.testing.expectError(
        error.InvalidSpan,
        bridge.requestFromParsed(
            input,
            parsed.request_line,
            &above_headers,
            &.{},
            .{ .v4 = .{
                .octets = .{ 127, 0, 0, 1 },
                .port = 1,
            } },
            "9f86d081884c7d659a2feaa0c55ad015",
            TestEnvironment.requestHost(&roc_host),
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        environment.live_allocations,
    );
}

test "request bridge extracts absolute target path boundaries" {
    const cases = [_]struct {
        target: []const u8,
        expected_path: []const u8,
        expected_query: []const u8,
    }{
        .{
            .target = "http://example.com/path?name=roc",
            .expected_path = "/path",
            .expected_query = "name=roc",
        },
        .{
            .target = "http://example.com?name=roc",
            .expected_path = "/",
            .expected_query = "name=roc",
        },
        .{
            .target = "http://example.com",
            .expected_path = "/",
            .expected_query = "",
        },
    };

    for (cases) |case| {
        var input_buffer: [160]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &input_buffer,
            "GET {s} HTTP/1.1\r\nHost: example.com\r\n\r\n",
            .{case.target},
        );
        const parsed = try parse(input);
        var environment = TestEnvironment{
            .allocator = std.testing.allocator,
        };
        var roc_host = environment.rocHost();
        const request = try bridge.requestFromParsed(
            input,
            parsed.request_line,
            parsed.parser.headers(),
            &.{},
            .{ .v4 = .{
                .octets = .{ 127, 0, 0, 1 },
                .port = 1,
            } },
            "9f86d081884c7d659a2feaa0c55ad015",
            TestEnvironment.requestHost(&roc_host),
        );
        try std.testing.expectEqualStrings(
            case.expected_path,
            stringBytes(&request.path),
        );
        try std.testing.expectEqualStrings(
            case.expected_query,
            request.query.items(),
        );
        request.decref(&roc_host);
        try std.testing.expectEqual(
            @as(usize, 0),
            environment.live_allocations,
        );
    }
}

test "request bridge preserves all eight IPv6 segments" {
    const input = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    const parsed = try parse(input);
    const segments = [_]u16{
        0,
        1,
        0x1234,
        0x5678,
        0x9abc,
        0xdef0,
        std.math.maxInt(u16) - 1,
        std.math.maxInt(u16),
    };
    var environment = TestEnvironment{
        .allocator = std.testing.allocator,
    };
    var roc_host = environment.rocHost();
    const request = try bridge.requestFromParsed(
        input,
        parsed.request_line,
        parsed.parser.headers(),
        &.{},
        .{ .v6 = .{
            .segments = segments,
            .port = std.math.maxInt(u16),
        } },
        "9f86d081884c7d659a2feaa0c55ad015",
        TestEnvironment.requestHost(&roc_host),
    );
    defer request.decref(&roc_host);

    const actual = request.remote_addr.payload_tcp().ip.payload_v6();
    try std.testing.expectEqual(segments[0], actual._0);
    try std.testing.expectEqual(segments[1], actual._1);
    try std.testing.expectEqual(segments[2], actual._2);
    try std.testing.expectEqual(segments[3], actual._3);
    try std.testing.expectEqual(segments[4], actual._4);
    try std.testing.expectEqual(segments[5], actual._5);
    try std.testing.expectEqual(segments[6], actual._6);
    try std.testing.expectEqual(segments[7], actual._7);
    try std.testing.expectEqual(
        std.math.maxInt(u16),
        request.remote_addr.payload_tcp().port,
    );
}

test "request bridge releases every partial construction on OOM" {
    const input =
        "POST /a-path-longer-than-small-string?query=long HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-A-Header-Name-Longer-Than-Small: a-long-header-value\r\n" ++
        "Content-Length: 24\r\n" ++
        "\r\n" ++
        "123456789012345678901234";
    const parsed = try parse(input);

    var baseline_environment = TestEnvironment{
        .allocator = std.testing.allocator,
    };
    var baseline_host = baseline_environment.rocHost();
    const baseline_request = try bridge.requestFromParsed(
        input,
        parsed.request_line,
        parsed.parser.headers(),
        input[parsed.head_length..],
        .{ .v6 = .{
            .segments = .{ 0, 0, 0, 0, 0, 0, 0, 1 },
            .port = 65535,
        } },
        "9f86d081884c7d659a2feaa0c55ad015",
        TestEnvironment.requestHost(&baseline_host),
    );
    baseline_request.decref(&baseline_host);
    const allocation_count = baseline_environment.allocation_attempts;
    try std.testing.expect(allocation_count > 2);
    try std.testing.expectEqual(
        @as(usize, 0),
        baseline_environment.live_allocations,
    );

    for (0..allocation_count) |fail_index| {
        var environment = TestEnvironment{
            .allocator = std.testing.allocator,
            .fail_index = fail_index,
        };
        var roc_host = environment.rocHost();
        try std.testing.expectError(
            error.OutOfMemory,
            bridge.requestFromParsed(
                input,
                parsed.request_line,
                parsed.parser.headers(),
                input[parsed.head_length..],
                .{ .v6 = .{
                    .segments = .{ 0, 0, 0, 0, 0, 0, 0, 1 },
                    .port = 65535,
                } },
                "9f86d081884c7d659a2feaa0c55ad015",
                TestEnvironment.requestHost(&roc_host),
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            environment.live_allocations,
        );
    }
}

test "request query ownership survives either target or query release first" {
    // Absent, empty, minimum nonempty, and embedded '?' query suffixes.
    const cases = [_]struct { target: []const u8, query: []const u8 }{
        .{ .target = "/", .query = "" },
        .{ .target = "/?", .query = "" },
        .{ .target = "/?a", .query = "a" },
        .{ .target = "/?a?b", .query = "a?b" },
        .{ .target = "http://example.com?a", .query = "a" },
        .{ .target = "http://example.com/path?a", .query = "a" },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |query_first| {
            const input = try std.fmt.allocPrint(std.testing.allocator, "GET {s} HTTP/1.1\r\nHost: x\r\n\r\n", .{case.target});
            defer std.testing.allocator.free(input);
            const parsed = try parse(input);
            var environment = TestEnvironment{ .allocator = std.testing.allocator };
            var host = environment.rocHost();
            const request = try bridge.requestFromParsed(
                input,
                parsed.request_line,
                parsed.parser.headers(),
                &.{},
                .{ .v4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 1234 } },
                "id",
                TestEnvironment.requestHost(&host),
            );
            const target = request.raw_target;
            const query = request.query;
            target.incref(1);
            query.incref(1);
            request.decref(&host);
            @memset(input, 0);
            try std.testing.expectEqualStrings(case.target, target.items());
            try std.testing.expectEqualStrings(case.query, query.items());
            if (query_first) {
                query.decref(&host);
                try std.testing.expectEqualStrings(case.target, target.items());
                target.decref(&host);
            } else {
                target.decref(&host);
                try std.testing.expectEqualStrings(case.query, query.items());
                query.decref(&host);
            }
            try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
        }
    }
}

test "request byte values share one allocation that the last value releases" {
    // A header name and a request ID past the 23-byte inline limit go in the
    // shared bytes too; an empty value and a short name need none.
    const input =
        "GET /items/42?page=2 HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-A-Header-Name-Past-Inline: Long\r\n" ++
        "X-Empty:\r\n" ++
        "\r\n";
    const request_id = "0123456789abcdef0123456789abcdef";
    for ([_]bool{ false, true }) |reverse| {
        const parsed = try parse(input);
        var environment = TestEnvironment{ .allocator = std.testing.allocator };
        var host = environment.rocHost();
        const request = try bridge.requestFromParsed(
            input,
            parsed.request_line,
            parsed.parser.headers(),
            &.{},
            .{ .v4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 1234 } },
            request_id,
            TestEnvironment.requestHost(&host),
        );
        // One allocation for the byte values, one for the header list.
        try std.testing.expectEqual(@as(usize, 2), environment.allocation_attempts);

        const headers = request.headers.items();
        try std.testing.expectEqual(@as(usize, 3), headers.len);
        const long_name = headers[1].name;
        // An empty value holds no allocation, so it takes no reference.
        try std.testing.expectEqual(@as(usize, 0), headers[2].value.len());
        try std.testing.expect(headers[2].value.elements_ptr == null);
        const values = [_]@TypeOf(request.raw_target){ request.raw_target, request.query, headers[0].value, headers[1].value };
        const id = request.request_id;
        for (values) |value| value.incref(1);
        long_name.incref(1);
        id.incref(1);
        request.decref(&host);
        try std.testing.expectEqual(@as(usize, 1), environment.live_allocations);

        try std.testing.expectEqualStrings("/items/42?page=2", values[0].items());
        try std.testing.expectEqualStrings("page=2", values[1].items());
        try std.testing.expectEqualStrings("example.com", values[2].items());
        try std.testing.expectEqualStrings("Long", values[3].items());
        try std.testing.expectEqualStrings("x-a-header-name-past-inline", stringBytes(long_name));
        try std.testing.expectEqualStrings(request_id, stringBytes(id));

        long_name.decref(&host);
        id.decref(&host);
        for (0..values.len) |position| {
            try std.testing.expectEqual(@as(usize, 1), environment.live_allocations);
            values[if (reverse) values.len - 1 - position else position].decref(&host);
        }
        try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
    }
}

test "metadata entry owns input and rolls back every failed allocation" {
    const Version = @TypeOf(@as(bridge.RequestMetadata, undefined).version);
    var reached_success = false;
    for (0..16) |fail_index| {
        var environment = TestEnvironment{ .allocator = std.testing.allocator, .fail_index = fail_index };
        var roc_host = environment.rocHost();
        var target = "/owned?query=bytes".*;
        var value = "borrowed header value".*;
        const request = bridge.requestFromMetadata(.{
            .method = bridge.HttpMethod.get,
            .version = Version.http11,
            .target = &target,
            .headers = &.{.{ .name = "X-Value", .value = &value }},
        }, "body", bridge.RemoteAddress.unix, "id", TestEnvironment.requestHost(&roc_host)) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
            continue;
        };
        var released = false;
        errdefer if (!released) request.decref(&roc_host);
        @memset(&target, 'x');
        @memset(&value, 'x');
        try std.testing.expectEqualStrings("/owned?query=bytes", request.raw_target.items());
        try std.testing.expectEqualStrings("/owned", request.path.asSlice());
        try std.testing.expectEqualStrings("query=bytes", request.query.items());
        try std.testing.expectEqualStrings("x-value", request.headers.items()[0].name.asSlice());
        try std.testing.expectEqualStrings("borrowed header value", request.headers.items()[0].value.items());
        request.decref(&roc_host);
        released = true;
        try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
        reached_success = true;
        break;
    }
    try std.testing.expect(reached_success);
}

test "metadata entry rejects unsupported target forms and noncanonical paths before allocation" {
    const Version = @TypeOf(@as(bridge.RequestMetadata, undefined).version);
    for ([_][]const u8{ "", "relative", "http://example.com/", "/a//b", "/a/../b", "/./" }) |target| {
        var environment = TestEnvironment{ .allocator = std.testing.allocator };
        var roc_host = environment.rocHost();
        try std.testing.expectError(error.InvalidTarget, bridge.requestFromMetadata(.{ .method = bridge.HttpMethod.get, .version = Version.http11, .target = target, .headers = &.{} }, "", bridge.RemoteAddress.unix, "", TestEnvironment.requestHost(&roc_host)));
        try std.testing.expectEqual(@as(usize, 0), environment.allocation_attempts);
    }
}

test "metadata entry preserves root and asterisk requests including empty values" {
    const Version = @TypeOf(@as(bridge.RequestMetadata, undefined).version);
    const Case = struct { target: []const u8, method: bridge.HttpMethod, version: Version, body: []const u8, id: []const u8 };
    for ([_]Case{
        .{ .target = "/", .method = bridge.HttpMethod.get, .version = Version.http11, .body = "payload", .id = "request-id" },
        .{ .target = "*", .method = bridge.HttpMethod.options, .version = Version.http10, .body = "", .id = "" },
        .{ .target = "/rpc", .method = bridge.HttpMethod.post, .version = Version.http20, .body = "rpc bytes", .id = "http2-id" },
    }) |case| {
        var environment = TestEnvironment{ .allocator = std.testing.allocator };
        var roc_host = environment.rocHost();
        {
            const request = try bridge.requestFromMetadata(.{
                .method = case.method,
                .version = case.version,
                .target = case.target,
                .headers = &.{},
            }, case.body, .{ .v4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 4321 } }, case.id, TestEnvironment.requestHost(&roc_host));
            defer request.decref(&roc_host);
            try std.testing.expectEqual(case.method, request.method);
            try std.testing.expectEqual(case.version, request.version);
            try std.testing.expectEqualStrings(case.target, request.raw_target.items());
            try std.testing.expectEqualStrings(case.target, request.path.asSlice());
            try std.testing.expectEqual(@as(usize, 0), request.query.items().len);
            try std.testing.expectEqual(@as(usize, 0), request.headers.items().len);
            try std.testing.expectEqualStrings(case.id, request.request_id.asSlice());
            try std.testing.expectEqual(@as(u16, 4321), request.remote_addr.payload_tcp().port);
            if (case.body.len == 0) {
                try std.testing.expectEqual(bridge.HttpRequestBodyTag.Empty, request.body.tag);
            } else {
                try std.testing.expectEqual(bridge.HttpRequestBodyTag.Bytes, request.body.tag);
                try std.testing.expectEqualStrings(case.body, request.body.payload_bytes().items());
            }
        }
        try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
    }
}

const http2_fields = [_]bridge.RequestMetadataHeader{
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/rpc?name=%2F" },
    .{ .name = ":authority", .value = "[::1]:443" },
};

test "HTTP/2 metadata maps control fields and joins zero one or multiple cookie fields" {
    // The cookie join boundary is one field; zero, one, and two are distinct.
    for (0..3) |cookie_count| {
        var environment = TestEnvironment{ .allocator = std.testing.allocator };
        var roc_host = environment.rocHost();
        var fields = http2_fields ++ [_]bridge.RequestMetadataHeader{
            .{ .name = "x-repeat", .value = "first" },
            .{ .name = "x-repeat", .value = "second" },
            .{ .name = "cookie", .value = "a=1" },
            .{ .name = "cookie", .value = "b=2" },
        };
        const value = try bridge.requestFromHttp2(std.testing.allocator, fields[0 .. 6 + cookie_count], "body", bridge.RemoteAddress.unix, "id", TestEnvironment.requestHost(&roc_host));
        {
            defer value.decref(&roc_host);
            try std.testing.expectEqual(bridge.HttpMethod.post, value.method);
            try std.testing.expectEqual(@as(u8, 2), @backingInt(value.version));
            try std.testing.expectEqualStrings("/rpc?name=%2F", value.raw_target.items());
            try std.testing.expectEqualStrings("/rpc", value.path.asSlice());
            try std.testing.expectEqualStrings("name=%2F", value.query.items());
            const headers = value.headers.items();
            try std.testing.expectEqual(@as(usize, if (cookie_count == 0) 3 else 4), headers.len);
            try std.testing.expectEqualStrings("host", headers[0].name.asSlice());
            try std.testing.expectEqualStrings("[::1]:443", headers[0].value.items());
            try std.testing.expectEqualStrings("first", headers[1].value.items());
            try std.testing.expectEqualStrings("second", headers[2].value.items());
            if (cookie_count != 0) try std.testing.expectEqualStrings(if (cookie_count == 1) "a=1" else "a=1; b=2", headers[3].value.items());
            try std.testing.expectEqualStrings("body", value.body.payload_bytes().items());
            try std.testing.expectEqualStrings("id", value.request_id.asSlice());
        }
        try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
    }
}

test "HTTP/2 method domain and asterisk target follow the existing application contract" {
    const Case = struct { text: []const u8, method: bridge.HttpMethod };
    for ([_]Case{
        .{ .text = "GET", .method = bridge.HttpMethod.get },
        .{ .text = "HEAD", .method = bridge.HttpMethod.head },
        .{ .text = "POST", .method = bridge.HttpMethod.post },
        .{ .text = "PUT", .method = bridge.HttpMethod.put },
        .{ .text = "DELETE", .method = bridge.HttpMethod.delete },
        .{ .text = "PATCH", .method = bridge.HttpMethod.patch },
        .{ .text = "OPTIONS", .method = bridge.HttpMethod.options },
        .{ .text = "QUERY", .method = bridge.HttpMethod.query },
    }) |case| {
        var fields = http2_fields;
        fields[0].value = case.text;
        fields[2].value = if (case.method == bridge.HttpMethod.options) "*" else "/";
        var environment = TestEnvironment{ .allocator = std.testing.allocator };
        var roc_host = environment.rocHost();
        const value = try bridge.requestFromHttp2(std.testing.allocator, &fields, "", bridge.RemoteAddress.unix, "", TestEnvironment.requestHost(&roc_host));
        defer value.decref(&roc_host);
        try std.testing.expectEqual(case.method, value.method);
        try std.testing.expectEqualStrings(fields[2].value, value.path.asSlice());
    }
}

test "HTTP/2 mapping rejects invalid metadata before Roc allocation" {
    const H = bridge.RequestMetadataHeader;
    const Case = struct { fields: []const H, expected: anyerror };
    for ([_]Case{
        // Missing, duplicate, unknown, and out-of-order control fields.
        .{ .fields = &.{}, .expected = error.InvalidHeaders },
        .{ .fields = http2_fields[1..], .expected = error.InvalidHeaders },
        .{ .fields = &.{ http2_fields[0], http2_fields[2], http2_fields[3] }, .expected = error.InvalidHeaders },
        .{ .fields = &.{ http2_fields[0], http2_fields[1], http2_fields[3] }, .expected = error.InvalidHeaders },
        .{ .fields = &http2_fields ++ &[_]H{http2_fields[0]}, .expected = error.InvalidHeaders },
        .{ .fields = &http2_fields ++ &[_]H{.{ .name = ":status", .value = "200" }}, .expected = error.InvalidHeaders },
        .{ .fields = &.{ .{ .name = "x", .value = "y" }, http2_fields[0] }, .expected = error.InvalidHeaders },
        .{ .fields = &.{.{ .name = ":method", .value = "CONNECT" }}, .expected = error.UnsupportedMethod },
        // Authority ambiguity is rejected, rather than leaking a conflicting Host.
        .{ .fields = http2_fields[0..3], .expected = error.InvalidHeaders },
        .{ .fields = &http2_fields ++ &[_]H{.{ .name = "host", .value = "other.example" }}, .expected = error.InvalidHeaders },
        .{ .fields = &http2_fields ++ &[_]H{ .{ .name = "host", .value = "[::1]:443" }, .{ .name = "host", .value = "[::1]:443" } }, .expected = error.InvalidHeaders },
    }) |case| {
        var environment = TestEnvironment{ .allocator = std.testing.allocator };
        var roc_host = environment.rocHost();
        try std.testing.expectError(case.expected, bridge.requestFromHttp2(std.testing.allocator, case.fields, "", bridge.RemoteAddress.unix, "", TestEnvironment.requestHost(&roc_host)));
        try std.testing.expectEqual(@as(usize, 0), environment.allocation_attempts);
    }
    const Invalid = struct { index: usize, value: []const u8, expected: anyerror };
    for ([_]Invalid{
        .{ .index = 0, .value = "TRACE", .expected = error.UnsupportedMethod },
        .{ .index = 0, .value = "CUSTOM", .expected = error.UnsupportedMethod },
        .{ .index = 0, .value = "get", .expected = error.UnsupportedMethod },
        .{ .index = 1, .value = "", .expected = error.InvalidHeaders },
        .{ .index = 1, .value = "1http", .expected = error.InvalidHeaders },
        .{ .index = 1, .value = "ht tp", .expected = error.InvalidHeaders },
        .{ .index = 2, .value = "", .expected = error.InvalidTarget },
        .{ .index = 2, .value = "*", .expected = error.InvalidTarget },
        .{ .index = 2, .value = "http://example.com/", .expected = error.InvalidTarget },
        .{ .index = 2, .value = "/a#fragment", .expected = error.InvalidTarget },
        .{ .index = 2, .value = "/bad%2", .expected = error.InvalidTarget },
        .{ .index = 2, .value = "/bad%GG", .expected = error.InvalidTarget },
        .{ .index = 2, .value = "/a\r\nb", .expected = error.InvalidTarget },
        .{ .index = 2, .value = "/a//b", .expected = error.InvalidTarget },
        .{ .index = 2, .value = "/a/../b", .expected = error.InvalidTarget },
        .{ .index = 3, .value = "", .expected = error.InvalidHeaders },
        .{ .index = 3, .value = "user@example.com", .expected = error.InvalidHeaders },
        .{ .index = 3, .value = "example.com:65536", .expected = error.InvalidHeaders },
    }) |case| {
        var fields = http2_fields;
        fields[case.index].value = case.value;
        var environment = TestEnvironment{ .allocator = std.testing.allocator };
        var roc_host = environment.rocHost();
        try std.testing.expectError(case.expected, bridge.requestFromHttp2(std.testing.allocator, &fields, "", bridge.RemoteAddress.unix, "", TestEnvironment.requestHost(&roc_host)));
        try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
    }
}

test "HTTP/2 authority fallback and matching Host produce one authority header" {
    for ([_][]const u8{ "example.com:65534", "example.com:65535", "[::1]:443" }) |host_value| {
        for ([_]bool{ false, true }) |with_authority| {
            var fields = http2_fields ++ [_]bridge.RequestMetadataHeader{.{ .name = "host", .value = host_value }};
            fields[3] = .{ .name = if (with_authority) ":authority" else "x-extra", .value = host_value };
            var environment = TestEnvironment{ .allocator = std.testing.allocator };
            var roc_host = environment.rocHost();
            const value = try bridge.requestFromHttp2(std.testing.allocator, &fields, "", bridge.RemoteAddress.unix, "", TestEnvironment.requestHost(&roc_host));
            defer value.decref(&roc_host);
            try std.testing.expectEqualStrings(host_value, value.headers.items()[0].value.items());
            try std.testing.expectEqual(@as(usize, if (with_authority) 1 else 2), value.headers.items().len);
        }
    }
}

fn http2ScratchAllocationCheck(allocator: std.mem.Allocator) !void {
    const fields = http2_fields ++ [_]bridge.RequestMetadataHeader{
        .{ .name = "cookie", .value = "a=1" },
        .{ .name = "cookie", .value = "b=2" },
    };
    var environment = TestEnvironment{ .allocator = std.testing.allocator };
    var roc_host = environment.rocHost();
    const value = try bridge.requestFromHttp2(allocator, &fields, "body", bridge.RemoteAddress.unix, "id", TestEnvironment.requestHost(&roc_host));
    value.decref(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
}

test "HTTP/2 scratch allocation failures release temporary storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, http2ScratchAllocationCheck, .{});
}

test "HTTP/2 Roc allocation failures roll back and input bytes are copied" {
    var reached_success = false;
    for (0..32) |fail_index| {
        var host_value = "borrowed.example".*;
        var cookie_value = "a=borrowed".*;
        const fields = http2_fields[0..3].* ++ [_]bridge.RequestMetadataHeader{
            .{ .name = ":authority", .value = &host_value },
            .{ .name = "cookie", .value = &cookie_value },
            .{ .name = "cookie", .value = "b=2" },
        };
        var environment = TestEnvironment{ .allocator = std.testing.allocator, .fail_index = fail_index };
        var roc_host = environment.rocHost();
        const value = bridge.requestFromHttp2(std.testing.allocator, &fields, "body", bridge.RemoteAddress.unix, "id", TestEnvironment.requestHost(&roc_host)) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
            continue;
        };
        @memset(&host_value, 'x');
        @memset(&cookie_value, 'x');
        {
            defer value.decref(&roc_host);
            try std.testing.expectEqualStrings("borrowed.example", value.headers.items()[0].value.items());
            try std.testing.expectEqualStrings("a=borrowed; b=2", value.headers.items()[1].value.items());
        }
        try std.testing.expectEqual(@as(usize, 0), environment.live_allocations);
        reached_success = true;
        break;
    }
    try std.testing.expect(reached_success);
}

test "HTTP/2 Cookie joining preserves empty crumbs and interleaved field order" {
    const fields = http2_fields ++ [_]bridge.RequestMetadataHeader{
        .{ .name = "cookie", .value = "" },
        .{ .name = "x-between", .value = "kept" },
        .{ .name = "cookie", .value = "b=2" },
        .{ .name = "cookie", .value = "" },
    };
    var environment = TestEnvironment{ .allocator = std.testing.allocator };
    var roc_host = environment.rocHost();
    const value = try bridge.requestFromHttp2(std.testing.allocator, &fields, "", bridge.RemoteAddress.unix, "", TestEnvironment.requestHost(&roc_host));
    defer value.decref(&roc_host);
    try std.testing.expectEqual(@as(usize, 3), value.headers.items().len);
    try std.testing.expectEqualStrings("; b=2; ", value.headers.items()[1].value.items());
    try std.testing.expectEqualStrings("x-between", value.headers.items()[2].name.asSlice());
    try std.testing.expectEqualStrings("kept", value.headers.items()[2].value.items());
}
