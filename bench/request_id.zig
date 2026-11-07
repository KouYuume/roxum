//! Compare only the 128-bit ID hex conversion, excluding random generation.
//! zig run -O ReleaseSafe -lc bench/request_id.zig
const std = @import("std");
noinline fn formatted(high: u64, low: u64) [32]u8 {
    var output: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&output, "{x:0>16}{x:0>16}", .{ high, low }) catch unreachable;
    return output;
}
noinline fn encoded(high: u64, low: u64) [32]u8 {
    var words: [16]u8 = undefined;
    std.mem.writeInt(u64, words[0..8], high, std.builtin.Endian.big);
    std.mem.writeInt(u64, words[8..16], low, std.builtin.Endian.big);
    return std.fmt.bytesToHex(words, std.fmt.Case.lower);
}
fn now() u64 {
    var time: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &time);
    return @as(u64, @intCast(time.sec)) * 1_000_000_000 + @as(u64, @intCast(time.nsec));
}
fn measure(run: usize, direct: bool) void {
    const start = now();
    var sum: u64 = 0;
    var state: u64 = 1;
    for (0..1_000_000) |index| {
        state = state *% 6364136223846793005 +% 1;
        const output = if (direct) encoded(state, ~state) else formatted(state, ~state);
        sum += output[index % output.len];
    }
    std.debug.print("{d},{s},{d},{d}\n", .{ run, if (direct) "encoded" else "formatted", now() - start, sum });
}
pub fn main() void {
    for (0..5) |run| {
        measure(run, run % 2 == 0);
        measure(run, run % 2 != 0);
    }
}
