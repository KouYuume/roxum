//! `Compression`: gzip-compresses a response body, and
//! decompresses the HTTP client's, on a blocking-work thread, so a large
//! body does not hold a Roc thread.
const std = @import("std");
const abi = @import("../roc_platform_abi.zig");
const allocator_context = @import("../allocator/context.zig");
const blocking = @import("../blocking.zig");
const fiber_wait = @import("../fiber_wait.zig");
const gzip = @import("../gzip.zig");
const request_bridge = @import("../bridge/request.zig");
const runtime = @import("../runtime.zig");

const CompressJob = struct {
    job: blocking.Job = .{ .run = run },
    input: []const u8,
    result: gzip.Error![]u8 = error.CompressFailed,

    fn run(job: *blocking.Job) void {
        const self: *CompressJob = @fieldParentPtr("job", job);
        self.result = gzip.compressAll(std.heap.smp_allocator, self.input);
    }
};

/// `bytes` gzip-compressed; empty when they could not be (a gzip stream
/// never is).
pub fn hostedCompressGzip(bytes: abi.RocListWith(u8, false)) callconv(std.builtin.CallingConvention.c) abi.RocListWith(u8, false) {
    var roc_host = rocHost();
    defer bytes.decref(&roc_host);
    var compress = CompressJob{ .input = bytes.items() };
    blocking.run(&compress.job);
    defer fiber_wait.stopIfStreamEnds();
    const compressed = compress.result catch return emptyList(&roc_host);
    defer std.heap.smp_allocator.free(compressed);
    return request_bridge.rocByteListFromSliceChecked(
        compressed,
        .{ .roc_host = &roc_host, .try_alloc = runtime.tryAllocWithHost },
    ) catch emptyList(&roc_host);
}

const DecompressJob = struct {
    job: blocking.Job = .{ .run = run },
    coding: gzip.Coding,
    input: []const u8,
    limit: usize,
    result: gzip.DecompressError![]u8 = error.Invalid,

    fn run(job: *blocking.Job) void {
        const self: *DecompressJob = @fieldParentPtr("job", job);
        self.result = gzip.decompressBounded(std.heap.smp_allocator, self.coding, self.input, self.limit);
    }
};

/// `bytes` decompressed with `coding` (0 gzip, 1 Zstandard), at most
/// `maximum_bytes` of them.
pub fn hostedCompressDecompress(bytes: abi.RocListWith(u8, false), coding: u8, maximum_bytes: u64) callconv(std.builtin.CallingConvention.c) abi.HostCompressDecompressed {
    var roc_host = rocHost();
    defer bytes.decref(&roc_host);
    var decompress = DecompressJob{
        .coding = if (coding == 1) gzip.Coding.zstd else gzip.Coding.gzip,
        .input = bytes.items(),
        .limit = std.math.cast(usize, maximum_bytes) orelse std.math.maxInt(usize),
    };
    blocking.run(&decompress.job);
    defer fiber_wait.stopIfStreamEnds();
    const decompressed = decompress.result catch |err| return decompressedTag(switch (err) {
        error.TooLarge => abi.HostCompressDecompressedTag.TooLarge,
        error.Invalid, error.OutOfMemory => abi.HostCompressDecompressedTag.Invalid,
    });
    defer std.heap.smp_allocator.free(decompressed);
    const list = request_bridge.rocByteListFromSliceChecked(
        decompressed,
        .{ .roc_host = &roc_host, .try_alloc = runtime.tryAllocWithHost },
    ) catch return decompressedTag(abi.HostCompressDecompressedTag.Invalid);
    var result: abi.HostCompressDecompressed = undefined;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    result.tag = abi.HostCompressDecompressedTag.Decompressed;
    const payload: *abi.RocListWith(u8, false) = @ptrCast(@alignCast(&result.payload));
    payload.* = list;
    return result;
}

fn decompressedTag(tag: abi.HostCompressDecompressedTag) abi.HostCompressDecompressed {
    var result: abi.HostCompressDecompressed = undefined;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    result.tag = tag;
    return result;
}

fn emptyList(roc_host: *abi.RocHost) abi.RocListWith(u8, false) {
    return request_bridge.rocByteListFromSliceChecked(
        &.{},
        .{ .roc_host = roc_host, .try_alloc = runtime.tryAllocWithHost },
    ) catch unreachable;
}

fn rocHost() abi.RocHost {
    const context = allocator_context.current() orelse @panic("allocator context is not set");
    return runtime.makeRocHost(@ptrCast(context.host_allocator));
}
