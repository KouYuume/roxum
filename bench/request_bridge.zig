//! Allocation diagnostic, not an HTTP throughput comparison.
//! zig run -O ReleaseSafe -lc --dep bridge --dep heap -Mroot=bench/request_bridge.zig -Mbridge=platform/host/bridge.zig -Mheap=platform/host/allocator/request_heap.zig
const std = @import("std");
const bridge = @import("bridge");
const RequestHeap = @import("heap").RequestHeap;
const allocation = bridge.host_allocator;

const Environment = struct {
    allocator: allocation.HostAllocator,
    calls: usize = 0,
    bytes: usize = 0,
    live: usize = 0,

    fn from(host: *bridge.RocHost) *Environment {
        return @ptrCast(@alignCast(host.env));
    }

    fn tryAllocate(host: *bridge.RocHost, length: usize, alignment: usize) ?*anyopaque {
        const self = from(host);
        const pointer = self.allocator.alloc(allocation.Domain.request, 1, length, alignment) orelse return null;
        self.calls += 1;
        self.bytes += length;
        self.live += 1;
        return pointer;
    }

    fn allocate(host: *bridge.RocHost, length: usize, alignment: usize) callconv(std.builtin.CallingConvention.c) *anyopaque {
        return tryAllocate(host, length, alignment) orelse @panic("allocation failed");
    }

    fn deallocate(host: *bridge.RocHost, pointer: *anyopaque, alignment: usize) callconv(std.builtin.CallingConvention.c) void {
        const self = from(host);
        self.allocator.dealloc(pointer, alignment);
        self.live -= 1;
    }

    fn reallocate(_: *bridge.RocHost, _: *anyopaque, _: usize, _: usize) callconv(std.builtin.CallingConvention.c) *anyopaque {
        @panic("unexpected bridge reallocation");
    }

    fn diagnostic(_: *bridge.RocHost, _: [*]const u8, _: usize) callconv(std.builtin.CallingConvention.c) void {
        @panic("unexpected Roc diagnostic");
    }
};

fn now() u64 {
    var timestamp: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &timestamp) != 0) @panic("clock failed");
    return @as(u64, @intCast(timestamp.sec)) * std.time.ns_per_s + @as(u64, @intCast(timestamp.nsec));
}

const Case = struct { name: []const u8, input: []const u8 };
const cases = [_]Case{
    .{ .name = "long_path_short_query", .input = "GET /" ++ (&@as([4094]u8, @splat('a'))) ++ "?x HTTP/1.1\r\nHost: x\r\n\r\n" },
    .{ .name = "one_header", .input = "GET / HTTP/1.1\r\nHost: x\r\n\r\n" },
    .{ .name = "eight_headers", .input = "GET / HTTP/1.1\r\nHost: x\r\n" ++ (@as(*const [7 * "X-Value: abc\r\n".len]u8, @ptrCast(&@as([7]["X-Value: abc\r\n".len]u8, @splat("X-Value: abc\r\n".*))))) ++ "\r\n" },
    .{ .name = "sixty_four_headers", .input = "GET / HTTP/1.1\r\nHost: x\r\n" ++ (@as(*const [63 * "X-Value: abc\r\n".len]u8, @ptrCast(&@as([63]["X-Value: abc\r\n".len]u8, @splat("X-Value: abc\r\n".*))))) ++ "\r\n" },
    // On 64-bit targets, 23 bytes is the last inline Roc string length.
    .{ .name = "path_23", .input = "GET /" ++ (&@as([22]u8, @splat('a'))) ++ " HTTP/1.1\r\nHost: x\r\n\r\n" },
    .{ .name = "path_24", .input = "GET /" ++ (&@as([23]u8, @splat('a'))) ++ " HTTP/1.1\r\nHost: x\r\n\r\n" },
    .{ .name = "path_25", .input = "GET /" ++ (&@as([24]u8, @splat('a'))) ++ " HTTP/1.1\r\nHost: x\r\n\r\n" },
    .{ .name = "query", .input = "GET /?name=roc HTTP/1.1\r\nHost: x\r\n\r\n" },
};

fn measure(case: Case, repetition: usize) !void {
    var parser = bridge.Parser{};
    const parsed = parser.feed(case.input);
    const FeedTag = std.meta.Tag(@TypeOf(parsed));
    switch (parsed) {
        FeedTag.head_complete => {},
        else => return error.InvalidFixture,
    }
    var heap = RequestHeap.initCached(std.heap.page_allocator);
    defer heap.deinit();
    var environment = Environment{ .allocator = .{
        .persistent_allocator = std.heap.page_allocator,
        .request_allocator = heap.allocator(),
    } };
    var host = bridge.RocHost{
        .env = &environment,
        .roc_alloc = Environment.allocate,
        .roc_dealloc = Environment.deallocate,
        .roc_realloc = Environment.reallocate,
        .roc_dbg = Environment.diagnostic,
        .roc_expect_failed = Environment.diagnostic,
        .roc_crashed = Environment.diagnostic,
    };
    const count = 100_000;
    const start = now();
    var checksum: usize = 0;
    for (0..count) |_| {
        // Admission validates the head before the bridge constructs owned values.
        try bridge.validateParsedRequestHead(case.input, parser.requestLine().?);
        const request = try bridge.requestFromParsed(
            case.input,
            parser.requestLine().?,
            parser.headers(),
            &.{},
            .{ .v4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 54321 } },
            "0123456789abcdef0123456789abcdef",
            .{ .roc_host = &host, .try_alloc = Environment.tryAllocate },
        );
        checksum +%= request.raw_target.items().len + request.headers.items().len;
        request.decref(&host);
        if (environment.live != 0 or heap.live_bytes != 0) return error.LeakedRequest;
    }
    const elapsed = now() - start;
    const measured_calls = environment.calls;
    const measured_bytes = environment.bytes;
    const request = try bridge.requestFromParsed(
        case.input,
        parser.requestLine().?,
        parser.headers(),
        &.{},
        .{ .v4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 54321 } },
        "0123456789abcdef0123456789abcdef",
        .{ .roc_host = &host, .try_alloc = Environment.tryAllocate },
    );
    const retained_query = request.query;
    retained_query.incref(1);
    request.decref(&host);
    const retained_bytes = heap.live_bytes;
    retained_query.decref(&host);
    if (environment.live != 0 or heap.live_bytes != 0) return error.LeakedQuery;
    std.debug.print("{d},{s},{d},{d},{d},{d},{d},{d},{d}\n", .{
        repetition,             case.name,       count,    elapsed,        measured_calls / count,
        measured_bytes / count, heap.peak_bytes, checksum, retained_bytes,
    });
}

pub fn main() !void {
    std.debug.print("repetition,case,requests,elapsed_ns,allocations_per_request,requested_bytes_per_request,heap_peak_bytes,checksum,query_retained_heap_bytes\n", .{});
    for (0..6) |repetition| {
        for (0..cases.len) |index| {
            const selected = if (repetition % 2 == 0) index else cases.len - 1 - index;
            try measure(cases[selected], repetition);
        }
    }
}
