const std = @import("std");
const host = @import("host");

const allocator = std.testing.allocator;

const address_family_local: c_int = 1;
const socket_stream: c_int = 1;
const timeout_milliseconds: u64 = 50;

extern "c" fn socketpair(
    domain: c_uint,
    socket_type: c_uint,
    protocol: c_uint,
    sockets: *[2]c_int,
) c_int;

extern "c" fn send(
    socket: c_int,
    bytes: *const anyopaque,
    length: usize,
    flags: c_int,
) isize;

extern "c" fn close(socket: c_int) c_int;

test "reader distinguishes idle head and body absolute deadlines" {
    const head_cases = [_]struct {
        initial_bytes: []const u8,
        expected_error: anyerror,
    }{
        .{ .initial_bytes = "", .expected_error = error.IdleTimeout },
        .{ .initial_bytes = "G", .expected_error = error.RequestHeadTimeout },
    };
    for (head_cases) |case| {
        const sockets = try openSocketPair();
        defer _ = close(sockets[0]);
        defer _ = close(sockets[1]);
        try sendAll(sockets[1], case.initial_bytes);
        var reader = host.RequestReader{};
        try std.testing.expectError(case.expected_error, reader.nextHead(sockets[0], timeouts()));
    }

    // A body that stops short times out on the body deadline.
    const sockets = try openSocketPair();
    defer _ = close(sockets[0]);
    defer _ = close(sockets[1]);
    try sendAll(sockets[1], "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\na");
    var reader = host.RequestReader{};
    const head = (try reader.nextHead(sockets[0], timeouts())).?;
    var stream = try reader.beginBodyStream(sockets[0], head, timeout_milliseconds);
    try std.testing.expectEqualStrings("a", (try stream.read(16)).chunk);
    try std.testing.expectError(error.RequestBodyTimeout, stream.read(16));
}

test "content-length stream crosses buffered and socket input then ends" {
    const sockets = try openSocketPair();
    defer _ = close(sockets[0]);
    defer _ = close(sockets[1]);

    try sendAll(
        sockets[1],
        "POST / HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Content-Length: 3\r\n" ++
            "\r\n" ++
            "a",
    );
    var reader = host.RequestReader{};
    const head = (try reader.nextHead(sockets[0], timeouts())).?;
    var stream = try reader.beginBodyStream(
        sockets[0],
        head,
        timeout_milliseconds,
    );

    const first = try stream.read(1);
    try std.testing.expectEqualStrings("a", first.chunk);
    try sendAll(sockets[1], "bc");
    const second = try stream.read(16);
    try std.testing.expectEqualStrings("bc", second.chunk);
    try std.testing.expect(stream.isFullyConsumed());
    try std.testing.expectEqual(
        host.StreamRead.end,
        try stream.read(16),
    );
}

test "chunked stream respects one-byte read boundary and preserves surplus" {
    const sockets = try openSocketPair();
    defer _ = close(sockets[0]);
    defer _ = close(sockets[1]);

    try sendAll(
        sockets[1],
        "POST / HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "3\r\nabc\r\n0\r\n\r\n" ++
            "GET /next HTTP/1.1\r\nHost: x\r\n\r\n",
    );
    var reader = host.RequestReader{};
    const head = (try reader.nextHead(sockets[0], timeouts())).?;
    var stream = try reader.beginBodyStream(
        sockets[0],
        head,
        timeout_milliseconds,
    );

    inline for ("abc") |expected| {
        const read = try stream.read(1);
        try std.testing.expectEqualSlices(
            u8,
            &.{expected},
            read.chunk,
        );
    }
    try std.testing.expectEqual(
        host.StreamRead.end,
        try stream.read(1),
    );
    const next = (try reader.nextHead(sockets[0], timeouts())).?;
    try std.testing.expectEqualStrings(
        "/next",
        next.request_line.target.slice(reader.headBytes(next)),
    );
}

test "content-length stream reports EOF immediately outside declared body" {
    const sockets = try openSocketPair();
    defer _ = close(sockets[0]);

    try sendAll(
        sockets[1],
        "POST / HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Content-Length: 2\r\n" ++
            "\r\n" ++
            "a",
    );
    var reader = host.RequestReader{};
    const head = (try reader.nextHead(sockets[0], timeouts())).?;
    var stream = try reader.beginBodyStream(
        sockets[0],
        head,
        timeout_milliseconds,
    );
    try std.testing.expectEqualStrings("a", (try stream.read(16)).chunk);
    _ = close(sockets[1]);

    try std.testing.expectError(error.IncompleteBody, stream.read(16));
    try std.testing.expect(!stream.isFullyConsumed());
}

test "buffered recovery preserves the next request for content-length and chunked bodies" {
    const cases = [_]struct {
        request: []const u8,
        expected_discarded: usize,
    }{
        .{
            .request = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc" ++
                "GET /next HTTP/1.1\r\nHost: x\r\n\r\n",
            .expected_discarded = 3,
        },
        .{
            .request = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
                "3\r\nabc\r\n0\r\n\r\n" ++
                "GET /next HTTP/1.1\r\nHost: x\r\n\r\n",
            .expected_discarded = 3,
        },
    };

    for (cases) |case| {
        const sockets = try openSocketPair();
        defer _ = close(sockets[0]);
        defer _ = close(sockets[1]);
        try sendAll(sockets[1], case.request);

        var reader = host.RequestReader{};
        const head = (try reader.nextHead(sockets[0], timeouts())).?;
        var stream = try reader.beginBodyStream(
            sockets[0],
            head,
            timeout_milliseconds,
        );
        const outcome = try stream.discardBuffered();
        switch (outcome) {
            host.RequestRecoveryOutcome.recovered => |discarded| try std.testing.expectEqual(
                case.expected_discarded,
                discarded,
            ),
            else => return error.ExpectedBufferedRecovery,
        }

        const next = (try reader.nextHead(sockets[0], timeouts())).?;
        try std.testing.expectEqualStrings(
            "/next",
            next.request_line.target.slice(reader.headBytes(next)),
        );
    }
}

test "buffered recovery returns immediately when body bytes require a socket read" {
    const sockets = try openSocketPair();
    defer _ = close(sockets[0]);
    defer _ = close(sockets[1]);
    try sendAll(
        sockets[1],
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\na",
    );

    var reader = host.RequestReader{};
    const head = (try reader.nextHead(sockets[0], timeouts())).?;
    var stream = try reader.beginBodyStream(
        sockets[0],
        head,
        timeout_milliseconds,
    );
    try std.testing.expectEqual(
        host.RequestRecoveryOutcome.incomplete,
        try stream.discardBuffered(),
    );
    try std.testing.expect(!stream.isFullyConsumed());
}

test "bounded recovery covers the 16 KiB limit and adjacent valid lengths" {
    const limit: usize = 16 * 1024;
    const lengths = [_]usize{ limit - 1, limit, limit + 1 };

    for (lengths) |length| {
        const sockets = try openSocketPair();
        defer _ = close(sockets[0]);
        defer _ = close(sockets[1]);
        var head_buffer: [128]u8 = undefined;
        const head_bytes = try std.fmt.bufPrint(
            &head_buffer,
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n",
            .{length},
        );
        try sendAll(sockets[1], head_bytes);

        var reader = host.RequestReader{};
        const head = (try reader.nextHead(sockets[0], timeouts())).?;
        var stream = try reader.beginBodyStream(
            sockets[0],
            head,
            timeout_milliseconds,
        );
        var sender: ?std.Thread = null;
        var body: [limit]u8 = undefined;
        if (length <= limit) {
            @memset(body[0..length], 'x');
            sender = try std.Thread.spawn(.{}, sendAllOrPanic, .{
                sockets[1],
                body[0..length],
            });
        }
        const outcome = try stream.drainBounded(limit, timeout_milliseconds);
        if (sender) |thread| thread.join();
        if (length <= limit) {
            switch (outcome) {
                host.RequestRecoveryOutcome.recovered => |discarded| try std.testing.expectEqual(
                    length,
                    discarded,
                ),
                else => return error.ExpectedBoundedRecovery,
            }
        } else {
            try std.testing.expectEqual(
                host.RequestRecoveryOutcome.limit_exceeded,
                outcome,
            );
        }
    }
}

test "bounded chunked recovery covers the 16 KiB limit and adjacent valid lengths" {
    const limit: usize = 16 * 1024;
    const lengths = [_]usize{ limit - 1, limit, limit + 1 };

    for (lengths) |length| {
        const sockets = try openSocketPair();
        defer _ = close(sockets[0]);
        defer _ = close(sockets[1]);
        try sendAll(
            sockets[1],
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
        );

        var reader = host.RequestReader{};
        const head = (try reader.nextHead(sockets[0], timeouts())).?;
        var stream = try reader.beginBodyStream(
            sockets[0],
            head,
            timeout_milliseconds,
        );
        const body = try allocator.alloc(u8, length);
        defer allocator.free(body);
        @memset(body, 'x');
        const wire_body = try std.fmt.allocPrint(
            allocator,
            "{x}\r\n{s}\r\n0\r\n\r\n",
            .{ length, body },
        );
        defer allocator.free(wire_body);
        const sender = try std.Thread.spawn(.{}, sendAllOrPanic, .{
            sockets[1],
            wire_body,
        });
        const outcome = try stream.drainBounded(limit, timeout_milliseconds);
        sender.join();

        if (length <= limit) {
            switch (outcome) {
                host.RequestRecoveryOutcome.recovered => |discarded| try std.testing.expectEqual(
                    length,
                    discarded,
                ),
                else => return error.ExpectedBoundedRecovery,
            }
        } else {
            try std.testing.expectEqual(
                host.RequestRecoveryOutcome.limit_exceeded,
                outcome,
            );
        }
    }
}

test "bounded recovery uses its independent timeout" {
    const sockets = try openSocketPair();
    defer _ = close(sockets[0]);
    defer _ = close(sockets[1]);
    try sendAll(
        sockets[1],
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\na",
    );

    var reader = host.RequestReader{};
    const head = (try reader.nextHead(sockets[0], timeouts())).?;
    var stream = try reader.beginBodyStream(
        sockets[0],
        head,
        1_000,
    );
    try std.testing.expectEqual(
        host.RequestRecoveryOutcome.timed_out,
        try stream.drainBounded(16 * 1024, 5),
    );
}

fn openSocketPair() ![2]c_int {
    var sockets: [2]c_int = undefined;
    if (socketpair(
        address_family_local,
        socket_stream,
        0,
        &sockets,
    ) != 0) return error.SocketPairFailed;
    return sockets;
}

fn timeouts() host.RequestTimeouts {
    return .{
        .first_byte_milliseconds = timeout_milliseconds,
        .head_milliseconds = timeout_milliseconds,
    };
}

fn sendAll(socket: c_int, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const result = send(
            socket,
            bytes[sent..].ptr,
            bytes.len - sent,
            0,
        );
        if (result <= 0) return error.SendFailed;
        sent += @intCast(result);
    }
}

fn sendAllOrPanic(socket: c_int, bytes: []const u8) void {
    sendAll(socket, bytes) catch @panic("test sender failed");
}

// Failure classes must remain stable across repeated reads and recovery attempts.
test "stream failure cause survives retries including allocation failure" {
    const cases = [_]struct { wire: []const u8, expected: anyerror, allocation_failure: bool = false }{
        .{ .wire = "Transfer-Encoding: chunked\r\n\r\nZ\r\n", .expected = error.InvalidChunkedBody },
        .{ .wire = "Transfer-Encoding: chunked\r\n\r\n1\r\nx\r\n0\r\n\r\n", .expected = error.RequestBodyTooLarge },
        .{ .wire = "Content-Length: 1\r\n\r\n", .expected = error.RequestBodyTimeout },
        .{ .wire = "Content-Length: 1\r\n\r\nx", .expected = error.OutOfMemory, .allocation_failure = true },
    };
    for (cases) |case| {
        const sockets = try openSocketPair();
        defer _ = close(sockets[0]);
        defer _ = close(sockets[1]);
        try sendAll(sockets[1], "POST / HTTP/1.1\r\nHost: x\r\n");
        try sendAll(sockets[1], case.wire);
        var reader = host.RequestReader{};
        const head = (try reader.nextHead(sockets[0], timeouts())).?;
        var stream = try reader.beginBodyStream(sockets[0], head, timeout_milliseconds);
        // A limit of 0 makes the one byte of body too large.
        if (case.expected == error.RequestBodyTooLarge) stream.limits.whole_bytes = 0;
        if (case.allocation_failure) stream.markFailed();
        while (true) {
            const result = stream.read(16 * 1024) catch |err| {
                try std.testing.expectEqual(case.expected, err);
                break;
            };
            switch (result) {
                host.StreamRead.end => return error.ExpectedStreamFailure,
                host.StreamRead.chunk => {},
            }
        }
        try std.testing.expectError(case.expected, stream.read(16));
        const token = host.body_effect.activate(&stream);
        defer host.body_effect.deactivate();
        const first_failure = host.body_effect.hostedBodyRead(token, 16, true);
        const expected_tag = switch (case.expected) {
            error.InvalidChunkedBody => "BadRequest",
            error.RequestBodyTooLarge => "TooLarge",
            error.RequestBodyTimeout => "TimedOut",
            error.OutOfMemory => "Failed",
            else => unreachable,
        };
        try std.testing.expectEqualStrings(expected_tag, @tagName(first_failure.tag));
        try std.testing.expectEqual(first_failure.tag, host.body_effect.hostedBodyRead(token, 16, true).tag);
        try std.testing.expectError(case.expected, stream.discardBuffered());
        try std.testing.expectError(case.expected, stream.drainBounded(16, timeout_milliseconds));
        try std.testing.expect(!stream.isFullyConsumed());
    }
}

/// A chunked request whose body is `decoded_length` one-byte chunks
/// (`1\r\nx\r\n`, six wire bytes each), followed by a pipelined request.
fn oneByteChunkedRequest(decoded_length: usize) ![]u8 {
    var wire: std.ArrayList(u8) = .empty;
    errdefer wire.deinit(allocator);
    try wire.appendSlice(allocator, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n");
    for (0..decoded_length) |_| try wire.appendSlice(allocator, "1\r\nx\r\n");
    try wire.appendSlice(allocator, "0\r\n\r\nGET /next HTTP/1.1\r\nHost: x\r\n\r\n");
    return wire.toOwnedSlice(allocator);
}

// A body limit of 64 KiB decoded. In one-byte chunks the wire form is about
// 384 KiB, three times the reader's 128 KiB wire buffer, so it only fits if
// the stream drops bytes it already handed out.
test "one-byte chunks reach the decoded body limit through a compacting buffer" {
    const limit: usize = 64 * 1024;
    for ([_]usize{ limit - 1, limit, limit + 1 }) |decoded_length| {
        const sockets = try openSocketPair();
        defer _ = close(sockets[0]);
        defer _ = close(sockets[1]);
        const wire = try oneByteChunkedRequest(decoded_length);
        defer allocator.free(wire);
        const sender = try std.Thread.spawn(.{}, sendAllOrPanic, .{ sockets[1], wire });

        var reader = host.RequestReader{};
        const head = (try reader.nextHead(sockets[0], timeouts())).?;
        var stream = try reader.beginBodyStream(sockets[0], head, 5_000);
        stream.limits.whole_bytes = limit;
        var received: usize = 0;
        const outcome: anyerror!void = while (true) {
            const read = stream.read(16 * 1024) catch |err| break err;
            switch (read) {
                host.StreamRead.end => break {},
                host.StreamRead.chunk => |bytes| {
                    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 'x'), byte);
                    received += bytes.len;
                },
            }
        };
        if (decoded_length <= limit) {
            try outcome;
            try std.testing.expectEqual(decoded_length, received);
            const next = (try reader.nextHead(sockets[0], timeouts())).?;
            try std.testing.expectEqualStrings("/next", next.request_line.target.slice(reader.headBytes(next)));
        } else {
            try std.testing.expectError(error.RequestBodyTooLarge, outcome);
            // Let the sender finish so it does not block on a full socket.
            drainUntilQuiet(sockets[0]);
        }
        sender.join();
    }
}

test "bounded chunked recovery follows the buffer when it is compacted" {
    const sockets = try openSocketPair();
    defer _ = close(sockets[0]);
    defer _ = close(sockets[1]);
    // 26 KiB in one-byte chunks is about 156 KiB of wire: more than the
    // buffer holds, so the drain compacts while its own decoder is ahead.
    const read_first: usize = 10 * 1024;
    const wire = try oneByteChunkedRequest(read_first + 16 * 1024);
    defer allocator.free(wire);
    const sender = try std.Thread.spawn(.{}, sendAllOrPanic, .{ sockets[1], wire });
    defer sender.join();

    var reader = host.RequestReader{};
    const head = (try reader.nextHead(sockets[0], timeouts())).?;
    var stream = try reader.beginBodyStream(sockets[0], head, 5_000);
    var received: usize = 0;
    while (received < read_first) {
        const read = try stream.read(@min(16 * 1024, read_first - received));
        received += read.chunk.len;
    }
    const outcome = try stream.drainBounded(16 * 1024, 5_000);
    switch (outcome) {
        host.RequestRecoveryOutcome.recovered => |discarded| try std.testing.expectEqual(@as(usize, 16 * 1024), discarded),
        else => return error.ExpectedBoundedRecovery,
    }
    const next = (try reader.nextHead(sockets[0], timeouts())).?;
    try std.testing.expectEqualStrings("/next", next.request_line.target.slice(reader.headBytes(next)));
}

/// Reads until no bytes arrive for 200 ms, so a sender thread can finish.
fn drainUntilQuiet(socket: c_int) void {
    var sink: [64 * 1024]u8 = undefined;
    while (true) {
        var poll_fd = [_]std.c.pollfd{.{ .fd = socket, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&poll_fd, 1, 200) <= 0) return;
        if (std.c.read(socket, &sink, sink.len) <= 0) return;
    }
}

test "a seeded head parsed elsewhere is taken over and its limits still checked" {
    const sockets = try openSocketPair();
    defer _ = close(sockets[0]);
    defer _ = close(sockets[1]);
    const first = "GET /a HTTP/1.1\r\nHost: x\r\n\r\n";
    var reader = host.RequestReader{};
    defer reader.deinit();
    var parsed: @TypeOf(reader.parser) = .{};
    _ = parsed.feed(first ++ "GET /b");
    try std.testing.expect(parsed.isComplete());
    try reader.seed(first ++ "GET /b", &parsed);
    const head = (try reader.nextHead(sockets[0], timeouts())).?;
    try std.testing.expectEqual(first.len, head.length);
    try std.testing.expectEqualStrings("/a", head.request_line.target.slice(reader.headBytes(head)));
    _ = reader.finish(head);

    // The pipelined head after it is parsed here, from the bytes.
    try sendAll(sockets[1], " HTTP/1.1\r\nHost: y\r\n\r\n");
    const next = (try reader.nextHead(sockets[0], timeouts())).?;
    try std.testing.expectEqualStrings("/b", next.request_line.target.slice(reader.headBytes(next)));
    try std.testing.expectEqualStrings("y", next.headers[0].value.slice(reader.headBytes(next)));
    _ = reader.finish(next);

    // A target past the limit is answered 414 though the loop parsed it.
    const target = "/" ++ "a" ** (16 * 1024);
    const long = "GET " ++ target ++ " HTTP/1.1\r\nHost: x\r\n\r\n";
    parsed.reset();
    _ = parsed.feed(long);
    try std.testing.expect(parsed.isComplete());
    try reader.seed(long, &parsed);
    try std.testing.expectError(error.RequestTargetTooLong, reader.nextHead(sockets[0], timeouts()));
}

fn readAll(stream: *host.RequestBodyStream, mode: host.RequestReadMode) !usize {
    var received: usize = 0;
    while (true) {
        switch (try stream.readAs(16 * 1024, mode)) {
            host.StreamRead.end => return received,
            host.StreamRead.chunk => |bytes| received += bytes.len,
        }
    }
}

// M21f: a body larger than the host receives first is read from the socket
// in parts, under the limit for the way it is read.
test "a large Content-Length body streams under its own limit" {
    const length: usize = 1024 * 1024;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    try wire.print(allocator, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n", .{length});
    try wire.appendNTimes(allocator, 'x', length);
    for ([_]struct { mode: host.RequestReadMode, limits: host.RequestBodyLimits, fits: bool }{
        .{ .mode = host.RequestReadMode.streamed, .limits = .{}, .fits = true },
        .{ .mode = host.RequestReadMode.streamed, .limits = .{ .streamed_bytes = length }, .fits = true },
        .{ .mode = host.RequestReadMode.streamed, .limits = .{ .streamed_bytes = length - 1 }, .fits = false },
        .{ .mode = host.RequestReadMode.whole, .limits = .{ .whole_bytes = length - 1 }, .fits = false },
        // The other way's limit does not apply.
        .{ .mode = host.RequestReadMode.whole, .limits = .{ .streamed_bytes = 1 }, .fits = true },
    }) |case| {
        const sockets = try openSocketPair();
        defer _ = close(sockets[0]);
        defer _ = close(sockets[1]);
        const sender = try std.Thread.spawn(.{}, sendAllOrPanic, .{ sockets[1], wire.items });
        var reader = host.RequestReader{};
        defer reader.deinit();
        const head = (try reader.nextHead(sockets[0], timeouts())).?;
        var stream = try reader.beginBodyStream(sockets[0], head, 5_000);
        stream.limits = case.limits;
        if (case.fits) {
            try std.testing.expectEqual(length, try readAll(&stream, case.mode));
        } else {
            // Known from Content-Length before any byte is read.
            try std.testing.expectError(error.RequestBodyTooLarge, readAll(&stream, case.mode));
            drainUntilQuiet(sockets[0]);
        }
        sender.join();
    }
}

// M21f: a streamed read waits for bytes up to the idle timeout each time, so
// a slow body that keeps arriving is not cut; a whole read keeps the
// deadline for the whole body.
test "a streamed read times out only while no bytes arrive" {
    for ([_]host.RequestReadMode{ host.RequestReadMode.streamed, host.RequestReadMode.whole }) |mode| {
        const sockets = try openSocketPair();
        defer _ = close(sockets[0]);
        defer _ = close(sockets[1]);
        try sendAll(sockets[1], "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n");
        var reader = host.RequestReader{};
        defer reader.deinit();
        const head = (try reader.nextHead(sockets[0], timeouts())).?;
        var stream = try reader.beginBodyStream(sockets[0], head, 250);
        stream.limits.idle_timeout_milliseconds = 1000;
        // A byte every 100 ms: far within the idle timeout each time, so a
        // slow machine's late wake-ups do not reach it, and past the
        // whole-body deadline at the end (400 ms).
        const sender = try std.Thread.spawn(.{}, sendSlowly, .{ sockets[1], "abcd", 100 });
        defer sender.join();
        const outcome = readAll(&stream, mode);
        switch (mode) {
            host.RequestReadMode.streamed => try std.testing.expectEqual(@as(usize, 4), try outcome),
            host.RequestReadMode.whole => try std.testing.expectError(error.RequestBodyTimeout, outcome),
        }
    }
}

fn sendSlowly(socket: c_int, bytes: []const u8, interval_milliseconds: u64) void {
    for (bytes) |byte| {
        const pause = std.c.timespec{ .sec = 0, .nsec = @intCast(interval_milliseconds * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&pause, null);
        sendAll(socket, &.{byte}) catch return;
    }
}

// M21f: `100 Continue` goes out at the first read that waits for the
// client, not before, and not when the body is too large to read.
test "100 Continue is sent at the first read that waits" {
    for ([_]struct { limit: u64, sent: bool }{
        .{ .limit = std.math.maxInt(u64), .sent = true },
        .{ .limit = 1, .sent = false },
    }) |case| {
        const sockets = try openSocketPair();
        defer _ = close(sockets[0]);
        defer _ = close(sockets[1]);
        try sendAll(sockets[1], "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n");
        var reader = host.RequestReader{};
        defer reader.deinit();
        const head = (try reader.nextHead(sockets[0], timeouts())).?;
        var stream = try reader.beginBodyStreamWith(sockets[0], head, .{
            .deadline = try host.net.Deadline.afterMilliseconds(timeout_milliseconds),
            .limits = .{ .streamed_bytes = case.limit },
            .send_continue = true,
        });
        // Nothing is sent before the first read.
        var poll_fd = [_]std.c.pollfd{.{ .fd = sockets[1], .events = std.c.POLL.IN, .revents = 0 }};
        try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&poll_fd, 1, 0));
        try sendAll(sockets[1], "ok");
        if (case.sent) {
            try std.testing.expectEqual(@as(usize, 2), try readAll(&stream, host.RequestReadMode.streamed));
            var interim: [host.request_continue_response.len]u8 = undefined;
            try std.testing.expectEqual(@as(isize, interim.len), std.c.read(sockets[1], &interim, interim.len));
            try std.testing.expectEqualStrings(host.request_continue_response, &interim);
        } else {
            try std.testing.expectError(error.RequestBodyTooLarge, readAll(&stream, host.RequestReadMode.streamed));
            try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&poll_fd, 1, 0));
        }
    }
}

// M21f: the event loop decodes the start of a large chunked body and hands
// it over; the stream reads those bytes first, then decodes the rest.
test "a chunked body goes on from what the event loop decoded" {
    const sockets = try openSocketPair();
    defer _ = close(sockets[0]);
    defer _ = close(sockets[1]);
    // The loop decoded "abc" from "5\r\nabc", and stopped in the chunk.
    const head_bytes = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    var decoder = host.chunked.Decoder{};
    _ = decoder.feed("5\r\n");
    _ = decoder.feed("abc");
    var reader = host.RequestReader{};
    defer reader.deinit();
    try reader.seed(head_bytes ++ "abc", null);
    const head = (try reader.nextHead(sockets[0], timeouts())).?;
    try sendAll(sockets[1], "de\r\n2\r\nfg\r\n0\r\n\r\n");
    var stream = try reader.beginBodyStreamWith(sockets[0], head, .{
        .deadline = try host.net.Deadline.afterMilliseconds(5_000),
        .predecoded = .{ .decoder = decoder, .length = 3, .wire = 6 },
    });
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    while (true) {
        switch (try stream.readAs(16 * 1024, host.RequestReadMode.streamed)) {
            host.StreamRead.end => break,
            host.StreamRead.chunk => |bytes| try body.appendSlice(allocator, bytes),
        }
    }
    try std.testing.expectEqualStrings("abcdefg", body.items);
    try std.testing.expect(stream.isFullyConsumed());
}

test "a whole Content-Length body already received is read in one chunk" {
    // All of the body received: one chunk, exactly the body, then the end.
    // Part of it received, or a chunked body: null, and parts as before.
    // Past the whole-body limit (one below, at, one above): too large only above.
    const Case = struct {
        head: []const u8,
        sent: []const u8,
        whole_limit: u64 = 1 << 20,
        expected: ?[]const u8,
        too_large: bool = false,
    };
    const length_head = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n";
    for ([_]Case{
        .{ .head = length_head, .sent = "abc", .expected = "abc" },
        .{ .head = length_head, .sent = "abcGET /next HTTP/1.1\r\nHost: x\r\n\r\n", .expected = "abc" },
        .{ .head = length_head, .sent = "a", .expected = null },
        .{ .head = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n", .sent = "3\r\nabc\r\n0\r\n\r\n", .expected = null },
        .{ .head = length_head, .sent = "abc", .whole_limit = 4, .expected = "abc" },
        .{ .head = length_head, .sent = "abc", .whole_limit = 3, .expected = "abc" },
        .{ .head = length_head, .sent = "abc", .whole_limit = 2, .expected = null, .too_large = true },
    }) |case| {
        const sockets = try openSocketPair();
        defer _ = close(sockets[0]);
        defer _ = close(sockets[1]);
        try sendAll(sockets[1], case.head);
        try sendAll(sockets[1], case.sent);
        var reader = host.RequestReader{};
        const head = (try reader.nextHead(sockets[0], timeouts())).?;
        var stream = try reader.beginBodyStream(sockets[0], head, timeout_milliseconds);
        stream.limits.whole_bytes = case.whole_limit;
        if (case.too_large) {
            try std.testing.expectError(error.RequestBodyTooLarge, stream.readBufferedWhole());
            continue;
        }
        const read = try stream.readBufferedWhole();
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, read.?.chunk);
            try std.testing.expect(stream.isFullyConsumed());
            try std.testing.expectEqual(host.StreamRead.end, (try stream.readBufferedWhole()).?);
        } else {
            try std.testing.expect(read == null);
            try std.testing.expect(!stream.isFullyConsumed());
        }
    }
}
