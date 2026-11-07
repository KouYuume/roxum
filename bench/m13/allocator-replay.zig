// Replays one observed echo allocation/free sequence without Roc or HTTP.
// The sizes include roxum allocator metadata, as observed at the backing allocator.
const std = @import("std");
extern "c" fn sleep(seconds: c_uint) c_uint;
pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    for (1..5001) |iteration| {
        const p0 = allocator.rawAlloc(61, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p0[0..61], 1);
        const p1 = allocator.rawAlloc(304, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p1[0..304], 1);
        const p2 = allocator.rawAlloc(59, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p2[0..59], 1);
        const p3 = allocator.rawAlloc(83, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p3[0..83], 1);
        const p4 = allocator.rawAlloc(66, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p4[0..66], 1);
        const p5 = allocator.rawAlloc(71, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p5[0..71], 1);
        const p6 = allocator.rawAlloc(61, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p6[0..61], 1);
        const p7 = allocator.rawAlloc(128, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p7[0..128], 1);
        const p8 = allocator.rawAlloc(80, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p8[0..80], 1);
        allocator.rawFree(p8[0..80], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        allocator.rawFree(p7[0..128], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        const p9 = allocator.rawAlloc(112, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p9[0..112], 1);
        allocator.rawFree(p9[0..112], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        const p10 = allocator.rawAlloc(4000, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p10[0..4000], 1);
        const p11 = allocator.rawAlloc(16440, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p11[0..16440], 1);
        const p12 = allocator.rawAlloc(20384, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p12[0..20384], 1);
        allocator.rawFree(p10[0..4000], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        allocator.rawFree(p11[0..16440], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        const p13 = allocator.rawAlloc(12496, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p13[0..12496], 1);
        const p14 = allocator.rawAlloc(32824, std.mem.Alignment.fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        @memset(p14[0..32824], 1);
        allocator.rawFree(p12[0..20384], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        allocator.rawFree(p13[0..12496], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        allocator.rawFree(p2[0..59], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        allocator.rawFree(p3[0..83], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        allocator.rawFree(p4[0..66], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        allocator.rawFree(p5[0..71], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        allocator.rawFree(p6[0..61], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        allocator.rawFree(p1[0..304], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        allocator.rawFree(p0[0..61], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        allocator.rawFree(p14[0..32824], std.mem.Alignment.fromByteUnits(8), @returnAddress());
        if (iteration == 1 or iteration == 100 or iteration == 1000 or iteration == 5000) {
            std.debug.print("ITER {d}\n", .{iteration});
            _ = sleep(1);
        }
    }
}
