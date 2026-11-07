const std = @import("std");
const http1 = @import("http1_parser");

const sample_count: usize = 5;
const normal_target_bytes: usize = 8 * 1024 * 1024;
const one_byte_target_bytes: usize = 8 * 1024 * 1024;

const Chunking = struct {
    name: []const u8,
    size: usize,
};

const Corpus = struct {
    name: []const u8,
    bytes: []const u8,
};

const small = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";

const typical =
    "GET /api/users/42?expand=profile HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    "User-Agent: roxum-benchmark/1.0\r\n" ++
    "Accept: application/json\r\n" ++
    "Accept-Encoding: gzip, br\r\n" ++
    "Cache-Control: no-cache\r\n" ++
    "X-Request-Id: 0123456789abcdef\r\n" ++
    "X-Forwarded-For: 192.0.2.1\r\n" ++
    "\r\n";

const many_headers =
    "GET /many HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    ("X-Benchmark-Header: abcdefghijklmnopqrstuvwxyz0123456789\r\n" ** 63) ++
    "\r\n";

const large_value =
    "GET /large HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    "X-Large: " ++ ("a" ** 16_384) ++ "\r\n\r\n";

pub fn main() void {
    const corpora = [_]Corpus{
        .{ .name = "small", .bytes = small },
        .{ .name = "typical", .bytes = typical },
        .{ .name = "many_headers", .bytes = many_headers },
        .{ .name = "large_value", .bytes = large_value },
    };
    const chunkings = [_]Chunking{
        .{ .name = "whole", .size = std.math.maxInt(usize) },
        .{ .name = "read_4096", .size = 4096 },
        .{ .name = "read_128", .size = 128 },
        .{ .name = "read_32", .size = 32 },
        .{ .name = "read_8", .size = 8 },
        .{ .name = "one_byte", .size = 1 },
    };

    std.debug.print(
        "HTTP/1 parser benchmark: ReleaseFast, samples={d}\n",
        .{sample_count},
    );
    std.debug.print("columns: corpus bytes chunk iterations median_ns ns_per_request mib_per_second\n", .{});

    for (corpora) |corpus| {
        for (chunkings) |chunking| {
            const target_bytes = if (chunking.size == 1)
                one_byte_target_bytes
            else
                normal_target_bytes;
            const iterations = @max(
                @as(usize, 1),
                target_bytes / corpus.bytes.len,
            );

            report(corpus, chunking, iterations);
        }
    }
}

fn report(
    corpus: Corpus,
    chunking: Chunking,
    iterations: usize,
) void {
    _ = run(corpus.bytes, chunking.size, @max(iterations / 10, 1));

    var samples: [sample_count]u64 = undefined;
    for (&samples) |*sample| {
        sample.* = run(corpus.bytes, chunking.size, iterations);
    }
    insertionSort(&samples);

    const median_ns = samples[sample_count / 2];
    const ns_per_request = median_ns / iterations;
    const total_bytes: u128 = @as(u128, corpus.bytes.len) * iterations;
    const mib_per_second: u128 = total_bytes * 1_000_000_000 /
        (@as(u128, median_ns) * 1024 * 1024);

    std.debug.print(
        "{s} {d} {s} {d} {d} {d} {d}\n",
        .{
            corpus.name,
            corpus.bytes.len,
            chunking.name,
            iterations,
            median_ns,
            ns_per_request,
            mib_per_second,
        },
    );
}

fn run(
    input: []const u8,
    chunk_size: usize,
    iterations: usize,
) u64 {
    var checksum: usize = 0;
    const started = nowNanos();

    for (0..iterations) |_| {
        var parser = http1.Parser{};
        var position: usize = 0;

        while (position < input.len) {
            const end = @min(
                input.len,
                position +| chunk_size,
            );
            const result = parser.feed(input[position..end]);
            position = end;

            switch (result) {
                http1.FeedResult.need_more => {},
                http1.FeedResult.head_complete => |completion| {
                    checksum +%= completion.head_length;
                    checksum +%= completion.consumed;
                },
                http1.FeedResult.err => |parse_error| {
                    std.debug.panic(
                        "benchmark corpus failed: {s}",
                        .{@tagName(parse_error)},
                    );
                },
            }
        }

        checksum +%= parser.headers().len;
        const request_line = parser.requestLine() orelse
            std.debug.panic("benchmark corpus did not complete", .{});
        checksum +%= request_line.target.len;
    }

    std.mem.doNotOptimizeAway(checksum);
    return nowNanos() - started;
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
