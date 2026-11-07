const std = @import("std");

const io = std.testing.io;
const allocator = std.testing.allocator;

const content_length_request =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: 127.0.0.1\r\n" ++
    "Content-Length: 3\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "abc";

const chunked_request =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: 127.0.0.1\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "1\r\na\r\n" ++
    "2\r\nbc\r\n" ++
    "0\r\n\r\n";

const unsupported_request =
    "CUSTOM /echo HTTP/1.1\r\n" ++
    "Host: 127.0.0.1\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const expected_response =
    "HTTP/1.1 200 \r\n" ++
    "Content-Length: 3\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "abc";

const expected_unsupported_response =
    "HTTP/1.1 501 Not Implemented\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const pipelined_request =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: 127.0.0.1\r\n" ++
    "Content-Length: 3\r\n" ++
    "\r\n" ++
    "abc" ++
    "POST /echo HTTP/1.1\r\n" ++
    "Host: 127.0.0.1\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "\r\n" ++
    "1\r\na\r\n2\r\nbc\r\n0\r\n\r\n" ++
    "GET /empty HTTP/1.1\r\n" ++
    "Host: 127.0.0.1\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const expected_pipelined_response =
    "HTTP/1.1 200 \r\n" ++
    "Content-Length: 3\r\n" ++
    "\r\n" ++
    "abc" ++
    "HTTP/1.1 200 \r\n" ++
    "Content-Length: 3\r\n" ++
    "\r\n" ++
    "abc" ++
    "HTTP/1.1 200 \r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const http_1_0_keep_alive_request =
    "POST /echo HTTP/1.0\r\n" ++
    "Host: 127.0.0.1\r\n" ++
    "Content-Length: 3\r\n" ++
    "Connection: keep-alive\r\n" ++
    "\r\n" ++
    "abc" ++
    "POST /echo HTTP/1.0\r\n" ++
    "Host: 127.0.0.1\r\n" ++
    "Content-Length: 3\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "xyz";

const expected_http_1_0_keep_alive_response =
    "HTTP/1.0 200 \r\n" ++
    "Content-Length: 3\r\n" ++
    "Connection: keep-alive\r\n" ++
    "\r\n" ++
    "abc" ++
    "HTTP/1.0 200 \r\n" ++
    "Content-Length: 3\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "xyz";

const expected_bad_request_response =
    "HTTP/1.1 400 Bad Request\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const expected_request_timeout_response =
    "HTTP/1.1 408 Request Timeout\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const expected_content_too_large_response =
    "HTTP/1.1 413 Content Too Large\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const expected_uri_too_long_response =
    "HTTP/1.1 414 URI Too Long\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const expected_headers_too_large_response =
    "HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const expected_version_not_supported_response =
    "HTTP/1.1 505 HTTP Version Not Supported\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const expected_expectation_failed_response =
    "HTTP/1.1 417 Expectation Failed\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const expected_head_response =
    "HTTP/1.1 200 \r\n" ++
    "Content-Length: 3\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const expected_stream_response =
    "HTTP/1.1 200 \r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "7\r\nchunk-3\r\n" ++
    "7\r\nchunk-2\r\n" ++
    "7\r\nchunk-1\r\n" ++
    "0\r\n\r\n";

const expected_empty_stream_response =
    "HTTP/1.1 200 \r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "0\r\n\r\n";

const expected_unread_response =
    "HTTP/1.1 200 \r\n" ++
    "Content-Length: 6\r\n" ++
    "\r\n" ++
    "unread" ++
    "HTTP/1.1 200 \r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const expected_partial_response =
    "HTTP/1.1 200 \r\n" ++
    "Content-Length: 7\r\n" ++
    "\r\n" ++
    "partial" ++
    "HTTP/1.1 200 \r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const continue_response = "HTTP/1.1 100 Continue\r\n\r\n";

const contract_marker = "roxum-contract-request-ok";
const startup_effect_lines = [_][]const u8{
    "[DEBUG] m4-debug",
    "[INFO] m4-info",
    "[WARN] m4-warn",
    "[ERROR] m4-error",
};
const startup_time_prefix = "[INFO] m4-time-";
// The interpreter starts one Roc runtime per logical worker and exercises the
// complete route matrix. Keep this bounded while allowing slower CI machines.
const timeout_ms: u64 = 60 * std.time.ms_per_s;

test "echo server returns the structured Roc response on sequential connections" {
    const executable = getEnvironmentVariable(
        "ROXUM_PREBUILT_EXE",
    ) orelse return error.MissingPrebuiltExecutable;
    const contract_alloc = if (getEnvironmentVariable(
        "ROXUM_CONTRACT_ALLOC",
    )) |value|
        std.mem.eql(u8, value, "1")
    else
        false;
    const interpreter = if (getEnvironmentVariable("ROXUM_OPT")) |value|
        std.mem.eql(u8, value, "interpreter")
    else
        false;

    try runServer(executable, contract_alloc, interpreter);
}

fn runServer(
    executable: []const u8,
    contract_alloc: bool,
    interpreter: bool,
) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{executable},
        .stdin = std.process.SpawnOptions.StdIo.ignore,
        .stdout = std.process.SpawnOptions.StdIo.pipe,
        .stderr = std.process.SpawnOptions.StdIo.pipe,
        .pgid = 0,
    });
    var child_running = true;
    defer if (child_running) child.kill(io);

    var watch = Watch{
        .child_id = child.id orelse return error.ChildIdMissing,
        .done = std.atomic.Value(bool).init(false),
        .timed_out = std.atomic.Value(bool).init(false),
    };
    const watch_thread = try std.Thread.spawn(
        .{},
        Watch.run,
        .{&watch},
    );

    const interaction_result = runInteraction(
        child.stdout.?,
        child.stderr.?,
        contract_alloc,
        interpreter,
    );

    watch.done.store(
        true,
        std.builtin.AtomicOrder.release,
    );
    watch_thread.join();

    if (watch.timed_out.load(
        std.builtin.AtomicOrder.acquire,
    )) return error.ServerTimedOut;

    try interaction_result;

    child.kill(io);
    child_running = false;
}

fn runInteraction(
    stdout: std.Io.File,
    stderr: std.Io.File,
    contract_alloc: bool,
    interpreter: bool,
) !void {
    const port = try readPortLine(stdout);
    // One process by default; its threads share one `init!`.
    const process_count = 1;
    try expectStartupEffects(stderr, process_count);

    // Interpreter dispatch deliberately prioritizes semantic coverage over
    // load volume; speed/dev retain the exhaustive M6 concurrency fixture.
    const concurrent_count: usize = if (interpreter) 4 else 64;
    try runConcurrentRequests(port, concurrent_count);
    if (contract_alloc) {
        for (0..concurrent_count) |_| try expectContractMarker(stderr);
    }

    const first_response = try sendHttpRequest(
        port,
        content_length_request,
    );
    defer allocator.free(first_response);
    try std.testing.expectEqualStrings(
        expected_response,
        first_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const stream_response = try sendHttpRequest(
        port,
        "GET /stream HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );
    defer allocator.free(stream_response);
    try std.testing.expectEqualStrings(
        expected_stream_response,
        stream_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const empty_stream_response = try sendHttpRequest(
        port,
        "GET /stream-empty HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );
    defer allocator.free(empty_stream_response);
    try std.testing.expectEqualStrings(
        expected_empty_stream_response,
        empty_stream_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const head_stream_response = try sendHttpRequest(
        port,
        "HEAD /stream HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );
    defer allocator.free(head_stream_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 \r\nConnection: close\r\n\r\n",
        head_stream_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const unread_response = try sendHttpRequest(
        port,
        "POST /unread HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Content-Length: 3\r\n" ++
            "\r\n" ++
            "abc" ++
            "GET /empty HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(unread_response);
    try std.testing.expectEqualStrings(
        expected_unread_response,
        unread_response,
    );
    if (contract_alloc) {
        try expectContractMarker(stderr);
        try expectContractMarker(stderr);
    }

    const partial_response = try sendHttpRequest(
        port,
        "POST /partial HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Content-Length: 3\r\n" ++
            "\r\n" ++
            "abc" ++
            "GET /empty HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(partial_response);
    try std.testing.expectEqualStrings(
        expected_partial_response,
        partial_response,
    );
    if (contract_alloc) {
        try expectContractMarker(stderr);
        try expectContractMarker(stderr);
    }

    // A client that withholds the body gets 100 Continue once the handler
    // reads it, for a plain value and for a list with empty elements.
    for ([_][]const u8{ "100-continue", ",100-continue,," }) |expect_value| {
        const continue_result = try sendExpectContinueRequest(port, expect_value);
        defer allocator.free(continue_result);
        try std.testing.expectEqualStrings(
            continue_response ++ expected_response,
            continue_result,
        );
        if (contract_alloc) try expectContractMarker(stderr);
    }

    const unsupported_expectation_response = try sendHttpRequest(
        port,
        "POST /echo HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Expect: custom\r\n" ++
            "Content-Length: 1\r\n" ++
            "\r\n",
    );
    defer allocator.free(unsupported_expectation_response);
    try std.testing.expectEqualStrings(
        expected_expectation_failed_response,
        unsupported_expectation_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const head_response = try sendHttpRequest(
        port,
        "HEAD /echo HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );
    defer allocator.free(head_response);
    try std.testing.expectEqualStrings(
        expected_head_response,
        head_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const static_route_responses = try sendHttpRequest(
        port,
        "GET /users/me HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /users/me HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(static_route_responses);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 \r\nContent-Length: 6\r\n\r\nstatic" ++
            "HTTP/1.1 200 \r\nContent-Length: 6\r\nConnection: close\r\n\r\nstatic",
        static_route_responses,
    );
    if (contract_alloc) {
        try expectContractMarker(stderr);
        try expectContractMarker(stderr);
    }

    const decoded_parameter_response = try sendHttpRequest(
        port,
        "GET /users/a%2Fb HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(decoded_parameter_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 \r\nContent-Length: 3\r\nConnection: close\r\n\r\na/b",
        decoded_parameter_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const extracted_response = try sendHttpRequest(
        port,
        "POST /extract/a%2Fb?mode=fast HTTP/1.1\r\n" ++
            "Host: x\r\nContent-Type: application/json\r\n" ++
            "Content-Length: 16\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{\"name\":\"roxum\"}",
    );
    defer allocator.free(extracted_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 \r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: 19\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "a/b|mode=fast|roxum",
        extracted_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    // Invalid chunk syntax and terminators are client errors through the extractor.
    for ([_][]const u8{ "Z\r\n", "1\r\nxXX" }) |wire_body| {
        const request = try std.fmt.allocPrint(allocator, "POST /extract/id HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{s}", .{wire_body});
        defer allocator.free(request);
        const response = try sendHttpRequest(port, request);
        defer allocator.free(response);
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 "));
        if (contract_alloc) try expectContractMarker(stderr);
    }
    // The limit of a body read whole (2 MiB, M21f): nearest valid below/at,
    // and first rejected above.
    const whole_limit: usize = 2 * 1024 * 1024;
    for ([_]usize{ whole_limit - 1, whole_limit, whole_limit + 1 }) |length| {
        const body = try allocator.alloc(u8, length);
        defer allocator.free(body);
        @memset(body, ' ');
        const json = "{\"name\":\"roxum\"}";
        @memcpy(body[0..json.len], json);
        for ([_]bool{ false, true }) |use_chunked| {
            const framing = if (use_chunked)
                try std.fmt.allocPrint(allocator, "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n{x}\r\n{s}\r\n0\r\n\r\n", .{ length, body })
            else
                try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ length, if (length > whole_limit) "" else body });
            defer allocator.free(framing);
            const request = try std.fmt.allocPrint(allocator, "POST /extract/id HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n{s}", .{framing});
            defer allocator.free(request);
            const response = try sendHttpRequest(port, request);
            defer allocator.free(response);
            try std.testing.expect(std.mem.startsWith(u8, response, if (length <= whole_limit) "HTTP/1.1 200 " else "HTTP/1.1 413 "));
            if (contract_alloc) try expectContractMarker(stderr);
        }
    }

    const invalid_json_response = try sendHttpRequest(
        port,
        "POST /extract/id?mode=fast HTTP/1.1\r\n" ++
            "Host: x\r\nContent-Type: application/json\r\n" ++
            "Content-Length: 4\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{bad",
    );
    defer allocator.free(invalid_json_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 400 \r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: 30\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "request body is not valid JSON",
        invalid_json_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const typed_headers_response = try sendHttpRequest(
        port,
        "GET /typed-headers HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Content-Length: 0\r\n" ++
            "X-Request-Id: request-42\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );
    defer allocator.free(typed_headers_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 \r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: 12\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "0|request-42",
        typed_headers_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const missing_typed_header_response = try sendHttpRequest(
        port,
        "GET /typed-headers HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );
    defer allocator.free(missing_typed_header_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 400 \r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: 44\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "request headers do not match the target type",
        missing_typed_header_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const catch_all_response = try sendHttpRequest(
        port,
        "GET /files/a/b/c HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(catch_all_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 \r\nContent-Length: 5\r\nConnection: close\r\n\r\na/b/c",
        catch_all_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    // The static path wins before method lookup; POST must not fall through
    // to the parameter route even though that route accepts POST.
    const static_method_response = try sendHttpRequest(
        port,
        "POST /users/me HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(static_method_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 405 \r\nallow: GET, HEAD\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        static_method_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const allow_order_response = try sendHttpRequest(
        port,
        "PUT /methods HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(allow_order_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 405 \r\nallow: GET, HEAD, POST, DELETE\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        allow_order_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const explicit_head_response = try sendHttpRequest(
        port,
        "HEAD /head HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(explicit_head_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 \r\nx-head: explicit\r\nContent-Length: 4\r\nConnection: close\r\n\r\n",
        explicit_head_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const missing_route_response = try sendHttpRequest(
        port,
        "GET /missing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(missing_route_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 404 \r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        missing_route_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const invalid_parameter_response = try sendHttpRequest(
        port,
        "GET /users/%FF HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(invalid_parameter_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 400 \r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        invalid_parameter_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    // Structural hazards are rejected before the request allocator and before
    // an Expect: 100-continue acknowledgement.
    const unsafe_path_response = try sendHttpRequest(
        port,
        "POST /a/../b HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n",
    );
    defer allocator.free(unsafe_path_response);
    try std.testing.expectEqualStrings(
        expected_bad_request_response,
        unsafe_path_response,
    );

    const unsupported_version_response = try sendHttpRequest(
        port,
        "GET / HTTP/2.0\r\nHost: x\r\n\r\n",
    );
    defer allocator.free(unsupported_version_response);
    try std.testing.expectEqualStrings(
        expected_version_not_supported_response,
        unsupported_version_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    // A target one byte over 8 KiB, and one longer than the 32 KiB head
    // limit, are both 414: the target limit is checked before the head ends.
    const long_target_response = try sendLongTarget(port, 8 * 1024);
    defer allocator.free(long_target_response);
    try std.testing.expectEqualStrings(
        expected_uri_too_long_response,
        long_target_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const head_sized_target_response = try sendLongTarget(port, 40 * 1024);
    defer allocator.free(head_sized_target_response);
    try std.testing.expectEqualStrings(
        expected_uri_too_long_response,
        head_sized_target_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const malformed_response = try sendHttpRequest(
        port,
        "GET / HTTP/1.1\n\n",
    );
    defer allocator.free(malformed_response);
    try std.testing.expectEqualStrings(
        expected_bad_request_response,
        malformed_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const malformed_http_1_0_response = try sendHttpRequest(
        port,
        "GET / HTTP/1.0\r\nHost: x\r\nConnection: close / keep-alive\r\n\r\n",
    );
    defer allocator.free(malformed_http_1_0_response);
    try std.testing.expectEqualStrings(
        "HTTP/1.0 400 Bad Request\r\n" ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        malformed_http_1_0_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    // Recipient-list equivalence classes: leading, interior, trailing and
    // wholly empty elements, including repeated fields. The body arrives
    // with the head, so no interim response is needed (RFC 9110 10.1.1):
    // the request goes to the Roc thread on its head and
    // the read finds the body already buffered. A withheld body is checked
    // with sendExpectContinueRequest.
    const list_cases = [_]struct { version: []const u8, expect: []const u8 }{
        .{ .version = "1.0", .expect = "100-continue" },
        .{ .version = "1.0", .expect = ",100-continue,," },
        .{ .version = "1.1", .expect = ",100-continue,," },
        .{ .version = "1.1", .expect = ", \t," },
    };
    for (list_cases) |case| {
        const request = try std.fmt.allocPrint(allocator, "GET /empty HTTP/{s}\r\nHost: x\r\nConnection: ,keep-alive,,\r\nConnection: ,close,\r\nExpect: \r\nExpect: {s}\r\nContent-Length: 1\r\n\r\nx", .{ case.version, case.expect });
        defer allocator.free(request);
        const actual = try sendHttpRequest(port, request);
        defer allocator.free(actual);
        const expected = try std.fmt.allocPrint(allocator, "HTTP/{s} 200 \r\nContent-Length: 1\r\nConnection: close\r\n\r\nx", .{case.version});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, actual);
        if (contract_alloc) try expectContractMarker(stderr);
    }

    // Over the route's limit by Content-Length: 413 from the handler's first
    // read, without 100 Continue.
    const oversized_body_response = try sendHttpRequest(
        port,
        "POST /limited-upload HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Expect: 100-continue\r\n" ++
            "Content-Length: 65537\r\n" ++
            "\r\n",
    );
    defer allocator.free(oversized_body_response);
    try std.testing.expect(std.mem.startsWith(u8, oversized_body_response, "HTTP/1.1 413 "));
    if (contract_alloc) try expectContractMarker(stderr);

    const oversized_head_response = try sendOversizedHead(port);
    defer allocator.free(oversized_head_response);
    try std.testing.expectEqualStrings(
        expected_headers_too_large_response,
        oversized_head_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const slowloris_response = try sendSlowlorisRequest(port);
    defer allocator.free(slowloris_response);
    try std.testing.expectEqualStrings(
        expected_request_timeout_response,
        slowloris_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    // Every protocol failure above must leave the listener operational.
    const recovery_response = try sendHttpRequest(
        port,
        content_length_request,
    );
    defer allocator.free(recovery_response);
    try std.testing.expectEqualStrings(
        expected_response,
        recovery_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const pipelined_response = try sendHttpRequest(
        port,
        pipelined_request,
    );
    defer allocator.free(pipelined_response);
    try std.testing.expectEqualStrings(
        expected_pipelined_response,
        pipelined_response,
    );
    if (contract_alloc) {
        try expectContractMarker(stderr);
        try expectContractMarker(stderr);
        try expectContractMarker(stderr);
    }

    const http_1_0_response = try sendHttpRequest(
        port,
        http_1_0_keep_alive_request,
    );
    defer allocator.free(http_1_0_response);
    try std.testing.expectEqualStrings(
        expected_http_1_0_keep_alive_response,
        http_1_0_response,
    );
    if (contract_alloc) {
        try expectContractMarker(stderr);
        try expectContractMarker(stderr);
    }

    const second_response = try sendHttpRequest(
        port,
        chunked_request,
    );
    defer allocator.free(second_response);
    try std.testing.expectEqualStrings(
        expected_response,
        second_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);

    const unsupported_response = try sendHttpRequest(
        port,
        unsupported_request,
    );
    defer allocator.free(unsupported_response);
    try std.testing.expectEqualStrings(
        expected_unsupported_response,
        unsupported_response,
    );
    if (contract_alloc) try expectContractMarker(stderr);
}

const ConcurrentRequest = struct {
    port: u16,
    start: *std.atomic.Value(bool),
    result: ?anyerror = null,

    fn run(self: *ConcurrentRequest) void {
        while (!self.start.load(std.builtin.AtomicOrder.acquire)) {
            std.atomic.spinLoopHint();
        }
        self.execute() catch |err| {
            self.result = err;
        };
    }

    fn execute(self: *ConcurrentRequest) !void {
        const response = try sendHttpRequest(
            self.port,
            "GET /empty HTTP/1.1\r\n" ++
                "Host: 127.0.0.1\r\n" ++
                "Connection: close\r\n" ++
                "\r\n",
        );
        defer allocator.free(response);
        try std.testing.expectEqualStrings(
            "HTTP/1.1 200 \r\n" ++
                "Content-Length: 0\r\n" ++
                "Connection: close\r\n" ++
                "\r\n",
            response,
        );
    }
};

fn runConcurrentRequests(port: u16, count: usize) !void {
    var start = std.atomic.Value(bool).init(false);
    var requests: [64]ConcurrentRequest = undefined;
    var threads: [64]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();

    while (started < count) : (started += 1) {
        requests[started] = .{ .port = port, .start = &start };
        threads[started] = try std.Thread.spawn(
            .{},
            ConcurrentRequest.run,
            .{&requests[started]},
        );
    }
    start.store(true, std.builtin.AtomicOrder.release);
    for (threads[0..count]) |thread| thread.join();
    for (requests[0..count]) |request| {
        if (request.result) |err| return err;
    }
}

/// Processes initialize concurrently, so their startup lines interleave line
/// by line. Each line is written in one call, so every expected line appears
/// once per process regardless of order.
fn expectStartupEffects(stderr: std.Io.File, process_count: usize) !void {
    var buffer: [512]u8 = undefined;
    var seen = [_]usize{0} ** startup_effect_lines.len;
    var time_lines: usize = 0;

    for (0..process_count * (startup_effect_lines.len + 1)) |_| {
        const line = try readLine(
            stderr,
            &buffer,
            error.ServerExitedBeforeStartupEffects,
        );
        if (std.mem.startsWith(u8, line, startup_time_prefix)) {
            const milliseconds = std.fmt.parseInt(
                i64,
                line[startup_time_prefix.len..],
                10,
            ) catch return error.InvalidStartupTime;
            if (milliseconds <= 0) return error.InvalidStartupTime;
            time_lines += 1;
            continue;
        }
        const index = for (startup_effect_lines, 0..) |expected, position| {
            if (std.mem.eql(u8, expected, line)) break position;
        } else return error.UnexpectedStartupLine;
        seen[index] += 1;
    }

    for (seen) |count| try std.testing.expectEqual(process_count, count);
    try std.testing.expectEqual(process_count, time_lines);
}

fn readPortLine(stdout: std.Io.File) !u16 {
    var buffer: [6]u8 = undefined;
    const line = try readLine(
        stdout,
        &buffer,
        error.ServerExitedBeforePort,
    );
    if (line.len == 0) return error.EmptyPortLine;

    var port: u32 = 0;
    for (line) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidPortLine;
        port = port * 10 + byte - '0';
        if (port > std.math.maxInt(u16)) return error.InvalidPortLine;
    }
    if (port == 0) return error.InvalidPortLine;
    return @intCast(port);
}

fn expectContractMarker(stderr: std.Io.File) !void {
    var buffer: [64]u8 = undefined;
    const line = try readLine(
        stderr,
        &buffer,
        error.ServerExitedBeforeContractMarker,
    );
    try std.testing.expectEqualStrings(contract_marker, line);
}

fn readLine(
    file: std.Io.File,
    buffer: []u8,
    end_of_stream_error: anyerror,
) ![]const u8 {
    var length: usize = 0;

    while (length < buffer.len) {
        var byte_buffer: [1]u8 = undefined;
        var slices = [_][]u8{byte_buffer[0..]};
        const count = file.readStreaming(
            io,
            &slices,
        ) catch |err| switch (err) {
            error.EndOfStream => return end_of_stream_error,
            else => |read_error| return read_error,
        };
        if (count == 0) return end_of_stream_error;
        if (byte_buffer[0] == '\n') return buffer[0..length];

        buffer[length] = byte_buffer[0];
        length += 1;
    }

    return error.LineTooLong;
}

fn sendHttpRequest(
    port: u16,
    request_bytes: []const u8,
) ![]u8 {
    const net = std.Io.net;
    var address = net.IpAddress{
        .ip4 = net.Ip4Address.loopback(port),
    };
    const stream = try net.IpAddress.connect(
        &address,
        io,
        .{
            .mode = net.Socket.Mode.stream,
        },
    );
    defer stream.close(io);

    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request_bytes);
    try writer.interface.flush();

    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);

    var read_buffer: [512]u8 = undefined;
    var stream_buffer: [512]u8 = undefined;
    var reader = stream.reader(io, &stream_buffer);

    while (true) {
        var slices = [_][]u8{read_buffer[0..]};
        const count = std.Io.Reader.readVec(
            &reader.interface,
            &slices,
        ) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return reader.err orelse error.Unexpected,
        };
        if (count == 0) break;

        try response.appendSlice(
            allocator,
            read_buffer[0..count],
        );
        if (response.items.len > 4096) return error.ResponseTooLarge;
    }

    try removeDateHeaders(&response);
    return response.toOwnedSlice(allocator);
}

fn sendExpectContinueRequest(port: u16, expect_value: []const u8) ![]u8 {
    const net = std.Io.net;
    var address = net.IpAddress{
        .ip4 = net.Ip4Address.loopback(port),
    };
    const stream = try net.IpAddress.connect(
        &address,
        io,
        .{ .mode = net.Socket.Mode.stream },
    );
    defer stream.close(io);

    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll("POST /echo HTTP/1.1\r\nHost: 127.0.0.1\r\nExpect: ");
    try writer.interface.writeAll(expect_value);
    try writer.interface.writeAll("\r\nContent-Length: 3\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();

    var stream_buffer: [512]u8 = undefined;
    var reader = stream.reader(io, &stream_buffer);
    var interim: [continue_response.len]u8 = undefined;
    try readExact(&reader.interface, interim[0..]);
    try std.testing.expectEqualStrings(continue_response, interim[0..]);

    try writer.interface.writeAll("abc");
    try writer.interface.flush();

    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);
    try response.appendSlice(allocator, interim[0..]);

    var read_buffer: [512]u8 = undefined;
    while (true) {
        var slices = [_][]u8{read_buffer[0..]};
        const count = std.Io.Reader.readVec(
            &reader.interface,
            &slices,
        ) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return reader.err orelse error.Unexpected,
        };
        if (count == 0) break;
        try response.appendSlice(allocator, read_buffer[0..count]);
    }

    try removeDateHeaders(&response);
    return response.toOwnedSlice(allocator);
}

fn readExact(reader: *std.Io.Reader, output: []u8) !void {
    var offset: usize = 0;
    while (offset < output.len) {
        var slices = [_][]u8{output[offset..]};
        const count = std.Io.Reader.readVec(
            reader,
            &slices,
        ) catch |err| switch (err) {
            error.EndOfStream => return error.UnexpectedEndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        if (count == 0) return error.UnexpectedEndOfStream;
        offset += count;
    }
}

fn sendOversizedHead(port: u16) ![]u8 {
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(allocator);

    try request.appendSlice(
        allocator,
        "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Fill: ",
    );
    try request.appendNTimes(
        allocator,
        'x',
        32 * 1024,
    );
    try request.appendSlice(allocator, "\r\n\r\n");
    return sendHttpRequest(port, request.items);
}

fn sendLongTarget(port: u16, path_bytes: usize) ![]u8 {
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(allocator);

    try request.appendSlice(allocator, "GET /");
    try request.appendNTimes(allocator, 'a', path_bytes);
    try request.appendSlice(
        allocator,
        " HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
    );
    return sendHttpRequest(port, request.items);
}

fn sendSlowlorisRequest(port: u16) ![]u8 {
    const net = std.Io.net;
    var address = net.IpAddress{
        .ip4 = net.Ip4Address.loopback(port),
    };
    const stream = try net.IpAddress.connect(
        &address,
        io,
        .{ .mode = net.Socket.Mode.stream },
    );
    defer stream.close(io);

    var write_buffer: [16]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll("G");
    try writer.interface.flush();
    try std.Io.sleep(
        io,
        std.Io.Duration.fromMilliseconds(2_000),
        std.Io.Clock.awake,
    );
    try writer.interface.writeAll("E");
    try writer.interface.flush();
    try std.Io.sleep(
        io,
        std.Io.Duration.fromMilliseconds(2_000),
        std.Io.Clock.awake,
    );
    try writer.interface.writeAll("T");
    try writer.interface.flush();
    try std.Io.sleep(
        io,
        std.Io.Duration.fromMilliseconds(1_500),
        std.Io.Clock.awake,
    );

    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);
    var read_buffer: [256]u8 = undefined;
    var stream_buffer: [256]u8 = undefined;
    var reader = stream.reader(io, &stream_buffer);
    while (true) {
        var slices = [_][]u8{read_buffer[0..]};
        const count = std.Io.Reader.readVec(
            &reader.interface,
            &slices,
        ) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return reader.err orelse error.Unexpected,
        };
        if (count == 0) break;
        try response.appendSlice(allocator, read_buffer[0..count]);
    }
    try removeDateHeaders(&response);
    return response.toOwnedSlice(allocator);
}

fn getEnvironmentVariable(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return value[0..std.mem.len(value)];
}

const Watch = struct {
    child_id: std.process.Child.Id,
    done: std.atomic.Value(bool),
    timed_out: std.atomic.Value(bool),

    fn run(self: *Watch) void {
        const start = milliTimestamp();

        while (!self.done.load(
            std.builtin.AtomicOrder.acquire,
        )) {
            std.Io.sleep(
                io,
                std.Io.Duration.fromMilliseconds(100),
                std.Io.Clock.awake,
            ) catch {};

            if (self.done.load(
                std.builtin.AtomicOrder.acquire,
            )) return;

            const elapsed: u64 = @intCast(
                @max(0, milliTimestamp() - start),
            );
            if (elapsed >= timeout_ms) {
                self.timed_out.store(
                    true,
                    std.builtin.AtomicOrder.release,
                );
                std.posix.kill(
                    -self.child_id,
                    std.posix.SIG.KILL,
                ) catch {
                    std.posix.kill(
                        self.child_id,
                        std.posix.SIG.KILL,
                    ) catch {};
                };
                return;
            }
        }
    }
};

fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(
        io,
        std.Io.Clock.awake,
    ).toMilliseconds();
}

// Existing wire fixtures compare deterministic bytes. Validate the host's
// variable IMF-fixdate before removing just its complete header line.
fn removeDateHeaders(response: *std.ArrayList(u8)) !void {
    const marker = "\r\nDate: ";
    while (std.mem.indexOf(u8, response.items, marker)) |start| {
        const value_start = start + marker.len;
        const end = std.mem.indexOfPos(u8, response.items, value_start, "\r\n") orelse return error.InvalidDate;
        const date = response.items[value_start..end];
        try std.testing.expectEqual(@as(usize, 29), date.len);
        try std.testing.expect(std.mem.endsWith(u8, date, " GMT"));
        try std.testing.expectEqualStrings(", ", date[3..5]);
        const removed = end - start;
        std.mem.copyForwards(u8, response.items[start..], response.items[end..]);
        response.items.len -= removed;
    }
}
