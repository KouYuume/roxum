const std = @import("std");
const builtin = @import("builtin");
const http1 = @import("http1_encoder");

const sample_count: usize = 7;
const encode_target_header_bytes: usize = 32 * 1024 * 1024;
const advance_target_bytes: usize = 64 * 1024 * 1024;
const syscall_target_count: usize = 100_000;
const socket_target_bytes: usize = 16 * 1024 * 1024;

var encode_function = &http1.Encoder.init;

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn writev(
    file_descriptor: c_int,
    iovecs: [*]const std.posix.iovec_const,
    iovec_count: c_int,
) isize;
extern "c" fn close(file_descriptor: c_int) c_int;
extern "c" fn socketpair(
    domain: c_int,
    socket_type: c_int,
    protocol: c_int,
    sockets: *[2]c_int,
) c_int;
extern "c" fn socket(
    domain: c_int,
    socket_type: c_int,
    protocol: c_int,
) c_int;
extern "c" fn setsockopt(
    socket_fd: c_int,
    level: c_int,
    option_name: c_int,
    option_value: *const anyopaque,
    option_length: u32,
) c_int;
extern "c" fn bind(
    socket_fd: c_int,
    address: *const SockAddr,
    address_length: u32,
) c_int;
extern "c" fn listen(socket_fd: c_int, backlog: c_int) c_int;
extern "c" fn getsockname(
    socket_fd: c_int,
    address: *SockAddr,
    address_length: *u32,
) c_int;
extern "c" fn connect(
    socket_fd: c_int,
    address: *const SockAddr,
    address_length: u32,
) c_int;
extern "c" fn accept(
    socket_fd: c_int,
    address: ?*SockAddr,
    address_length: ?*u32,
) c_int;
extern "c" fn read(
    file_descriptor: c_int,
    buffer: *anyopaque,
    length: usize,
) isize;
extern "c" fn write(
    file_descriptor: c_int,
    buffer: *const anyopaque,
    length: usize,
) isize;

const address_family_inet: c_int = 2;
const socket_stream: c_int = 1;
const socket_level: c_int = 0xffff;
const no_sigpipe: c_int = 0x1022;
const ip_protocol_tcp: c_int = 6;
const tcp_no_delay: c_int = 1;
const loopback_address_network_order: u32 = 0x0100007f;

const SockAddr = extern struct {
    length: u8,
    family: u8,
    data: [14]u8,
};

const SockAddrIn = extern struct {
    length: u8,
    family: u8,
    port: u16,
    address: extern struct { value: u32 },
    zero: [8]u8,
};

const Corpus = struct {
    name: []const u8,
    headers: []const http1.Header,
    body: []const u8,
};

const small_headers = [_]http1.Header{
    .{ .name = "Content-Length", .value = "5" },
    .{ .name = "Content-Type", .value = "text/plain" },
};
const typical_headers = [_]http1.Header{
    .{ .name = "Content-Length", .value = "1234" },
    .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
    .{ .name = "Cache-Control", .value = "private, max-age=0" },
    .{ .name = "ETag", .value = "\"0123456789abcdef\"" },
    .{ .name = "Vary", .value = "Accept-Encoding" },
    .{ .name = "X-Request-Id", .value = "0123456789abcdef" },
    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    .{ .name = "Server", .value = "roxum" },
};
const many_headers: [64]http1.Header = @splat(
    .{
        .name = "X-Benchmark-Header",
        .value = "abcdefghijklmnopqrstuvwxyz0123456789",
    },
);
const maximum_headers: [128]http1.Header = @splat(
    .{
        .name = "X-Maximum-Header",
        .value = "abcdefghijklmnopqrstuvwxyz0123456789",
    },
);
const long_value_headers = [_]http1.Header{
    .{ .name = "X-Large", .value = &@as([16_384]u8, @splat('a')) },
};
const large_body = &@as([(64 * 1024)]u8, @splat('b'));

pub fn main() void {
    const corpora = [_]Corpus{
        .{ .name = "empty", .headers = &.{}, .body = "" },
        .{ .name = "small", .headers = &small_headers, .body = "hello" },
        .{ .name = "typical", .headers = &typical_headers, .body = &@as([1234]u8, @splat('b')) },
        .{ .name = "many_headers", .headers = &many_headers, .body = "hello" },
        .{ .name = "maximum_headers", .headers = &maximum_headers, .body = "hello" },
        .{ .name = "long_value", .headers = &long_value_headers, .body = "hello" },
        .{ .name = "large_body", .headers = &small_headers, .body = large_body },
    };

    std.debug.print(
        "HTTP/1 encoder benchmark: {s}, samples={d}\n",
        .{ @tagName(builtin.mode), sample_count },
    );
    std.debug.print(
        "columns: operation corpus iterations median_ns ns_per_response\n",
        .{},
    );

    for (corpora) |corpus| {
        const header_bytes = countHeaderBytes(corpus.headers);
        const encode_iterations = boundedIterations(
            encode_target_header_bytes,
            @max(header_bytes, 1),
        );
        const advance_iterations = boundedIterations(
            advance_target_bytes,
            messageLength(corpus),
        );
        const socket_iterations = std.math.clamp(
            socket_target_bytes / messageLength(corpus),
            1_000,
            100_000,
        );

        report("encode", corpus, encode_iterations, runEncode);
        report("partial_127", corpus, advance_iterations, runPartialWrite);
        report("total_writev_null", corpus, syscall_target_count, runTotalWritevNull);
        report("total_unix_socket", corpus, socket_iterations, runTotalSocket);
        report("total_tcp_direct", corpus, socket_iterations, runTotalTcpDirect);
        report("total_tcp_writev", corpus, socket_iterations, runTotalTcp);
    }
}

fn report(
    operation: []const u8,
    corpus: Corpus,
    iterations: usize,
    run: *const fn (Corpus, usize) u64,
) void {
    _ = run(corpus, @max(iterations / 10, 1));
    var samples: [sample_count]u64 = undefined;
    for (&samples) |*sample| sample.* = run(corpus, iterations);
    insertionSort(&samples);

    const median_ns = samples[sample_count / 2];
    const ns_per_response = @as(f64, @floatFromInt(median_ns)) /
        @as(f64, @floatFromInt(iterations));
    std.debug.print(
        "{s} {s} {d} {d} {d:.2}\n",
        .{ operation, corpus.name, iterations, median_ns, ns_per_response },
    );
}

fn runEncode(corpus: Corpus, iterations: usize) u64 {
    var response_buffer = http1.ResponseBuffer{};
    var iovec_buffer: http1.IovecBuffer = undefined;
    var checksum: usize = 0;
    const started = nowNanos();

    for (0..iterations) |index| {
        const encoder = encodeRuntime(
            200 + @as(u16, @intCast(index & 1)),
            corpus.headers,
            corpus.body,
            &response_buffer,
        );
        checksum +%= encoder.remainingIovecs(&iovec_buffer).len;
        std.mem.doNotOptimizeAway(&encoder);
    }

    std.mem.doNotOptimizeAway(checksum);
    return nowNanos() - started;
}

fn runPartialWrite(corpus: Corpus, iterations: usize) u64 {
    var response_buffer = http1.ResponseBuffer{};
    var iovec_buffer: http1.IovecBuffer = undefined;
    var checksum: usize = 0;
    const started = nowNanos();

    for (0..iterations) |_| {
        var encoder = encodeRuntime(
            200,
            corpus.headers,
            corpus.body,
            &response_buffer,
        );
        while (!encoder.isComplete()) {
            const iovecs = encoder.remainingIovecs(&iovec_buffer);
            var offered: usize = 0;
            for (iovecs) |iovec| offered += iovec.len;
            const written = @min(offered, 127);
            encoder.advance(written) catch unreachable;
            checksum +%= written;
        }
    }

    std.mem.doNotOptimizeAway(checksum);
    return nowNanos() - started;
}

fn runTotalWritevNull(corpus: Corpus, iterations: usize) u64 {
    const file_descriptor = open("/dev/null", 1);
    if (file_descriptor == -1) @panic("could not open /dev/null");
    defer _ = close(file_descriptor);

    var response_buffer = http1.ResponseBuffer{};
    var iovec_buffer: http1.IovecBuffer = undefined;
    var checksum: usize = 0;
    const started = nowNanos();

    for (0..iterations) |index| {
        const encoder = encodeRuntime(
            200 + @as(u16, @intCast(index & 1)),
            corpus.headers,
            corpus.body,
            &response_buffer,
        );
        const iovecs = encoder.remainingIovecs(&iovec_buffer);
        const written = writev(
            file_descriptor,
            iovecs.ptr,
            @intCast(iovecs.len),
        );
        if (written < 0) @panic("writev to /dev/null failed");
        if (written != encoder.remainingBytes()) {
            @panic("writev to /dev/null was unexpectedly partial");
        }
        checksum +%= @intCast(written);
    }

    std.mem.doNotOptimizeAway(checksum);
    return nowNanos() - started;
}

const DrainContext = struct {
    file_descriptor: c_int,
    expected_bytes: usize,
};

fn runTotalSocket(corpus: Corpus, iterations: usize) u64 {
    var sockets: [2]c_int = undefined;
    if (socketpair(1, 1, 0, &sockets) == -1) @panic("socketpair failed");
    defer _ = close(sockets[0]);
    defer _ = close(sockets[1]);

    return runConnectedSocket(corpus, iterations, sockets, false);
}

fn runTotalTcp(corpus: Corpus, iterations: usize) u64 {
    const sockets = openTcpPair();
    defer _ = close(sockets[0]);
    defer _ = close(sockets[1]);
    return runConnectedSocket(corpus, iterations, sockets, false);
}

fn runTotalTcpDirect(corpus: Corpus, iterations: usize) u64 {
    const sockets = openTcpPair();
    defer _ = close(sockets[0]);
    defer _ = close(sockets[1]);
    return runConnectedSocket(corpus, iterations, sockets, true);
}

fn runConnectedSocket(
    corpus: Corpus,
    iterations: usize,
    sockets: [2]c_int,
    direct_single_iovec: bool,
) u64 {
    const total_bytes = std.math.mul(
        usize,
        messageLength(corpus),
        iterations,
    ) catch unreachable;
    var drain_context = DrainContext{
        .file_descriptor = sockets[1],
        .expected_bytes = total_bytes,
    };
    const drain_thread = std.Thread.spawn(
        .{},
        drainSocket,
        .{&drain_context},
    ) catch @panic("reader thread failed");

    var response_buffer = http1.ResponseBuffer{};
    var iovec_buffer: http1.IovecBuffer = undefined;
    var checksum: usize = 0;
    const started = nowNanos();

    for (0..iterations) |index| {
        var encoder = encodeRuntime(
            200 + @as(u16, @intCast(index & 1)),
            corpus.headers,
            corpus.body,
            &response_buffer,
        );

        while (!encoder.isComplete()) {
            const iovecs = encoder.remainingIovecs(&iovec_buffer);
            const written = if (direct_single_iovec and iovecs.len == 1)
                write(sockets[0], iovecs[0].base, iovecs[0].len)
            else
                writev(sockets[0], iovecs.ptr, @intCast(iovecs.len));
            if (written <= 0) @panic("TCP writev failed");
            encoder.advance(@intCast(written)) catch unreachable;
            checksum +%= @intCast(written);
        }
    }

    const elapsed = nowNanos() - started;
    drain_thread.join();
    std.mem.doNotOptimizeAway(checksum);
    return elapsed;
}

fn openTcpPair() [2]c_int {
    const listener = socket(address_family_inet, socket_stream, 0);
    if (listener == -1) @panic("TCP listener socket failed");
    defer _ = close(listener);

    var address = SockAddrIn{
        .length = @sizeOf(SockAddrIn),
        .family = address_family_inet,
        .port = 0,
        .address = .{ .value = loopback_address_network_order },
        .zero = @splat(0),
    };
    if (bind(listener, @ptrCast(&address), @sizeOf(SockAddrIn)) == -1) {
        @panic("TCP bind failed");
    }
    if (listen(listener, 1) == -1) @panic("TCP listen failed");

    var address_length: u32 = @sizeOf(SockAddrIn);
    if (getsockname(
        listener,
        @ptrCast(&address),
        &address_length,
    ) == -1) @panic("TCP getsockname failed");

    const writer = socket(address_family_inet, socket_stream, 0);
    if (writer == -1) @panic("TCP writer socket failed");
    errdefer _ = close(writer);
    enableSocketOption(writer, socket_level, no_sigpipe);
    enableSocketOption(writer, ip_protocol_tcp, tcp_no_delay);

    if (connect(
        writer,
        @ptrCast(&address),
        @sizeOf(SockAddrIn),
    ) == -1) @panic("TCP connect failed");

    const reader = accept(listener, null, null);
    if (reader == -1) @panic("TCP accept failed");
    return .{ writer, reader };
}

fn enableSocketOption(
    socket_fd: c_int,
    level: c_int,
    option_name: c_int,
) void {
    var enabled: c_int = 1;
    if (setsockopt(
        socket_fd,
        level,
        option_name,
        &enabled,
        @sizeOf(c_int),
    ) == -1) @panic("setsockopt failed");
}

fn drainSocket(context: *const DrainContext) void {
    var buffer: [64 * 1024]u8 = undefined;
    var remaining = context.expected_bytes;

    while (remaining > 0) {
        const received = read(
            context.file_descriptor,
            &buffer,
            @min(buffer.len, remaining),
        );
        if (received <= 0) @panic("socket read failed");
        remaining -= @intCast(received);
    }
}

noinline fn encodeRuntime(
    status: u16,
    headers: []const http1.Header,
    body: []const u8,
    response_buffer: *http1.ResponseBuffer,
) http1.Encoder {
    const function_pointer: *volatile @TypeOf(encode_function) =
        &encode_function;
    return function_pointer.*(
        status,
        headers,
        body,
        response_buffer,
    ) catch unreachable;
}

fn countHeaderBytes(headers: []const http1.Header) usize {
    var total: usize = 0;
    for (headers) |header| total += header.name.len + header.value.len;
    return total;
}

fn messageLength(corpus: Corpus) usize {
    var total: usize = status_line_lengthForBenchmark() + 2 + corpus.body.len;
    for (corpus.headers) |header| {
        total += header.name.len + 2 + header.value.len + 2;
    }
    return total;
}

fn status_line_lengthForBenchmark() usize {
    return "HTTP/1.1 200 \r\n".len;
}

fn boundedIterations(target: usize, work_per_iteration: usize) usize {
    return std.math.clamp(target / work_per_iteration, 1_000, 1_000_000);
}

fn insertionSort(values: []u64) void {
    for (1..values.len) |index| {
        const value = values[index];
        var insertion = index;
        while (insertion > 0 and values[insertion - 1] > value) {
            values[insertion] = values[insertion - 1];
            insertion -= 1;
        }
        values[insertion] = value;
    }
}

fn nowNanos() u64 {
    var time: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &time);
    return @as(u64, @intCast(time.sec)) * 1_000_000_000 +
        @as(u64, @intCast(time.nsec));
}
