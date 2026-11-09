//! gzip compression of response bodies, and gzip and Zstandard
//! decompression of the HTTP client's, with Zig's `std.compress`.
//! A compressor holds about 300 KiB (its window and match tables), and a
//! Zstandard decompressor an 8 MiB window, so they live on the heap for
//! one body. They run on blocking-work threads, never on a Roc thread.
const std = @import("std");
const flate = std.compress.flate;

pub const Error = error{ OutOfMemory, CompressFailed };

pub const Compressor = struct {
    output: std.Io.Writer.Allocating,
    window: [flate.max_window_len]u8,
    compress: flate.Compress,

    /// A compressor writing gzip with zlib's default level (6), as the
    /// common servers do by default.
    pub fn create() Error!*Compressor {
        return createWithOutputAllocator(std.heap.smp_allocator);
    }

    fn createWithOutputAllocator(allocator: std.mem.Allocator) Error!*Compressor {
        const self = try std.heap.smp_allocator.create(Compressor);
        errdefer std.heap.smp_allocator.destroy(self);
        self.output = try std.Io.Writer.Allocating.initCapacity(allocator, 16 * 1024);
        errdefer self.output.deinit();
        self.compress = flate.Compress.init(&self.output.writer, &self.window, flate.Container.gzip, flate.Compress.Options.default) catch return error.CompressFailed;
        return self;
    }

    pub fn destroy(self: *Compressor) void {
        self.output.deinit();
        std.heap.smp_allocator.destroy(self);
    }

    pub fn write(self: *Compressor, bytes: []const u8) Error!void {
        self.compress.writer.writeAll(bytes) catch return error.CompressFailed;
    }

    /// Ends the bytes written so far on a byte boundary, so the client can
    /// decompress them before the body ends (a sync flush).
    pub fn flush(self: *Compressor) Error!void {
        self.compress.writer.flush() catch return error.CompressFailed;
    }

    /// Ends the gzip stream: its last block and the CRC and length.
    pub fn finish(self: *Compressor) Error!void {
        self.compress.finish() catch return error.CompressFailed;
    }

    /// The compressed bytes produced so far, which the caller copies; then
    /// they are forgotten.
    pub fn produced(self: *Compressor) []const u8 {
        return self.output.written();
    }

    pub fn forgetProduced(self: *Compressor) void {
        self.output.clearRetainingCapacity();
    }
};

/// `bytes` gzip-compressed, in memory from `allocator`.
pub fn compressAll(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    const compressor = try Compressor.createWithOutputAllocator(allocator);
    defer compressor.destroy();
    try compressor.write(bytes);
    try compressor.finish();
    // Transfer the output; destroy then releases only the compressor itself.
    // Allocators that cannot shrink may still copy in toOwnedSlice.
    return compressor.output.toOwnedSlice();
}

pub const Coding = enum { gzip, zstd };

pub const DecompressError = error{ OutOfMemory, TooLarge, Invalid };

/// `compressed` decompressed, at most `limit` bytes of it, in memory from
/// `allocator`: a body that would be larger, as a small stream that
/// expands to gigabytes, is `TooLarge` once it passes the limit.
pub fn decompressBounded(allocator: std.mem.Allocator, coding: Coding, compressed: []const u8, limit: usize) DecompressError![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    switch (coding) {
        Coding.gzip => {
            const window = try std.heap.smp_allocator.alloc(u8, flate.max_window_len);
            defer std.heap.smp_allocator.free(window);
            var decompress: flate.Decompress = .init(&input, flate.Container.gzip, window);
            return readBounded(allocator, &decompress.reader, limit);
        },
        Coding.zstd => {
            const zstd = std.compress.zstd;
            // HTTP's Zstandard (RFC 8878 §3.1.1.1.2) has windows up to 8 MiB.
            const window = try std.heap.smp_allocator.alloc(u8, zstd.default_window_len + zstd.block_size_max);
            defer std.heap.smp_allocator.free(window);
            var decompress: zstd.Decompress = .init(&input, window, .{});
            return readBounded(allocator, &decompress.reader, limit);
        },
    }
}

fn readBounded(allocator: std.mem.Allocator, reader: *std.Io.Reader, limit: usize) DecompressError![]u8 {
    return reader.allocRemaining(allocator, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.TooLarge,
        error.ReadFailed => error.Invalid,
    };
}

fn decompressAll(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&input, flate.Container.gzip, &window);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    _ = try decompress.reader.streamRemaining(&output.writer);
    return output.toOwnedSlice();
}

test "a body comes back whole from its gzip" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..2000) |index| try text.print(allocator, "line {d} of a page that repeats itself\n", .{index % 37});
    for ([_][]const u8{ "", "x", text.items }) |body| {
        const compressed = try compressAll(allocator, body);
        defer allocator.free(compressed);
        try std.testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b }, compressed[0..2]);
        const restored = try decompressAll(allocator, compressed);
        defer allocator.free(restored);
        try std.testing.expectEqualSlices(u8, body, restored);
    }
    const compressed = try compressAll(allocator, text.items);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len * 10 < text.items.len);
}

test "parts flushed one by one come back as they were written" {
    const allocator = std.testing.allocator;
    const compressor = try Compressor.create();
    defer compressor.destroy();
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    for ([_][]const u8{ "data: one\n\n", "data: two\n\n", "data: three\n\n" }) |part| {
        try compressor.write(part);
        try compressor.flush();
        try wire.appendSlice(allocator, compressor.produced());
        compressor.forgetProduced();
    }
    try compressor.finish();
    try wire.appendSlice(allocator, compressor.produced());
    const restored = try decompressAll(allocator, wire.items);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("data: one\n\ndata: two\n\ndata: three\n\n", restored);
}

test "a body is decompressed within its limit, and a larger one is refused" {
    const allocator = std.testing.allocator;
    const body = @as(*const [2000 * "roxum ".len]u8, @ptrCast(&@as([2000]["roxum ".len]u8, @splat("roxum ".*))));
    const compressed = try compressAll(allocator, body);
    defer allocator.free(compressed);
    const restored = try decompressBounded(allocator, Coding.gzip, compressed, body.len);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings(body, restored);
    const below_limit = try decompressBounded(allocator, Coding.gzip, compressed, body.len + 1);
    defer allocator.free(below_limit);
    try std.testing.expectEqualStrings(body, below_limit);
    try std.testing.expectError(error.TooLarge, decompressBounded(allocator, Coding.gzip, compressed, body.len - 1));
    try std.testing.expectError(error.Invalid, decompressBounded(allocator, Coding.gzip, "not gzip at all", 1024));
}

test "a Zstandard body is decompressed" {
    const allocator = std.testing.allocator;
    // "hello zstd\n" from `zstd`.
    const compressed = "\x28\xb5\x2f\xfd\x04\x58\x59\x00\x00\x68\x65\x6c\x6c\x6f\x20\x7a\x73\x74\x64\x0a\x6c\x57\xf9\x51";
    const restored = try decompressBounded(allocator, Coding.zstd, compressed, 1024);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("hello zstd\n", restored);
    try std.testing.expectError(error.TooLarge, decompressBounded(allocator, Coding.zstd, compressed, 4));
    try std.testing.expectError(error.Invalid, decompressBounded(allocator, Coding.zstd, "\x28\xb5\x2f\xfdxx", 1024));
}

test "whole-body compression cleans up when output allocation or ownership transfer fails" {
    // Allocation 0 creates the output buffer; allocation 1 is the fallback
    // exact-size allocation when shrinking that buffer is refused.
    for ([_]usize{ 0, 1 }) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        try std.testing.expectError(error.OutOfMemory, compressAll(failing.allocator(), "hello"));
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
