//! Whole-body gzip: compressible and incompressible payloads at small,
//! medium, and large response sizes. Run each executable in alternating order.
const std = @import("std");
const gzip = @import("gzip");

fn now() u64 {
    var time: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &time);
    return @as(u64, @intCast(time.sec)) * 1_000_000_000 + @as(u64, @intCast(time.nsec));
}

pub fn main() !void {
    for ([_]usize{ 1024, 65536, 1048576 }) |size| {
        const bytes = try std.heap.smp_allocator.alloc(u8, size);
        defer std.heap.smp_allocator.free(bytes);
        for ([_]bool{ false, true }) |random| {
            var seed: u64 = 12345;
            for (bytes) |*byte| {
                seed = seed *% 6364136223846793005 +% 1;
                byte.* = if (random) @truncate(seed >> 32) else 'a';
            }
            const warm = try gzip.compressAll(std.heap.smp_allocator, bytes);
            std.heap.smp_allocator.free(warm);
            const start = now();
            var total: usize = 0;
            for (0..20) |_| {
                const compressed = try gzip.compressAll(std.heap.smp_allocator, bytes);
                total += compressed.len;
                std.heap.smp_allocator.free(compressed);
            }
            std.debug.print("{d},{s},{d},{d}\n", .{ size, if (random) "random" else "repeat", now() - start, total });
        }
    }
}
