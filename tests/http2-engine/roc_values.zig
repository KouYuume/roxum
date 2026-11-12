//! Synthetic Roc values for transport ownership checks; no Roc code is invoked.
const std = @import("std");
const bridge = @import("http2_engine").bridge;
const Header = @import("http2_engine").engine.Header;

pub const Environment = struct {
    allocator: std.mem.Allocator,
    allocation_count: usize = 0,
    deallocation_count: usize = 0,
    live_allocations: usize = 0,

    pub fn rocHost(self: *Environment) bridge.RocHost {
        return .{
            .env = @ptrCast(self),
            .roc_alloc = allocate,
            .roc_dealloc = deallocate,
            .roc_realloc = reallocate,
            .roc_dbg = ignoreDiagnostic,
            .roc_expect_failed = ignoreDiagnostic,
            .roc_crashed = ignoreDiagnostic,
        };
    }

    fn allocate(
        roc_host: *bridge.RocHost,
        length: usize,
        alignment: usize,
    ) callconv(std.builtin.CallingConvention.c) *anyopaque {
        return tryAllocate(roc_host, length, alignment) orelse @panic("out of memory");
    }

    pub fn requestHost(host: *bridge.RocHost) bridge.RequestHost {
        return .{ .roc_host = host, .try_alloc = tryAllocate };
    }

    fn tryAllocate(roc_host: *bridge.RocHost, length: usize, alignment: usize) ?*anyopaque {
        const self: *Environment = @ptrCast(
            @alignCast(roc_host.env),
        );
        const prefix_length = @max(alignment, @sizeOf(usize));
        const total_length = std.math.add(
            usize,
            prefix_length,
            length,
        ) catch return null;
        const allocation_alignment =
            std.mem.Alignment.fromByteUnits(
                @max(alignment, @alignOf(usize)),
            );
        const base = self.allocator.rawAlloc(
            total_length,
            allocation_alignment,
            @returnAddress(),
        ) orelse return null;
        const data = base + prefix_length;
        const stored_size: *usize = @ptrFromInt(
            @intFromPtr(data) - @sizeOf(usize),
        );
        stored_size.* = total_length;
        self.allocation_count += 1;
        self.live_allocations += 1;
        return data;
    }

    fn deallocate(
        roc_host: *bridge.RocHost,
        pointer: *anyopaque,
        alignment: usize,
    ) callconv(std.builtin.CallingConvention.c) void {
        const self: *Environment = @ptrCast(
            @alignCast(roc_host.env),
        );
        const prefix_length = @max(alignment, @sizeOf(usize));
        const data_address = @intFromPtr(pointer);
        const stored_size: *const usize = @ptrFromInt(
            data_address - @sizeOf(usize),
        );
        const base: [*]u8 = @ptrFromInt(
            data_address - prefix_length,
        );
        // Poison Roc bytes before returning capacity so queued transport output
        // cannot accidentally pass by reading recently freed response storage.
        const data: [*]u8 = @ptrCast(pointer);
        @memset(data[0 .. stored_size.* - prefix_length], 0xa5);
        self.allocator.rawFree(
            base[0..stored_size.*],
            std.mem.Alignment.fromByteUnits(
                @max(alignment, @alignOf(usize)),
            ),
            @returnAddress(),
        );
        self.deallocation_count += 1;
        self.live_allocations -= 1;
    }

    fn reallocate(
        roc_host: *bridge.RocHost,
        pointer: *anyopaque,
        new_length: usize,
        alignment: usize,
    ) callconv(std.builtin.CallingConvention.c) *anyopaque {
        _ = roc_host;
        _ = pointer;
        _ = new_length;
        _ = alignment;
        @panic("the response bridge does not reallocate");
    }

    fn ignoreDiagnostic(
        roc_host: *bridge.RocHost,
        bytes: [*]const u8,
        length: usize,
    ) callconv(std.builtin.CallingConvention.c) void {
        _ = roc_host;
        _ = bytes;
        _ = length;
    }
};

fn responseBody(
    bytes: []const u8,
    roc_host: *bridge.RocHost,
) bridge.HttpResponseBody {
    var result: bridge.HttpResponseBody = undefined;
    if (bytes.len == 0) {
        result.tag = bridge.HttpResponseBodyTag.Empty;
        result.payload = std.mem.zeroes(@TypeOf(result.payload));
        return result;
    }

    const list = bridge.RocByteList.fromSlice(bytes, roc_host);
    result.tag = bridge.HttpResponseBodyTag.Bytes;
    const payload: *bridge.RocByteList = @ptrCast(
        @alignCast(&result.payload),
    );
    payload.* = list;
    return result;
}

pub fn response(status: u16, fields: []const Header, body: []const u8, host: *bridge.RocHost) bridge.HttpResponse {
    const headers = bridge.HttpResponseHeaderList.allocate(fields.len, host);
    for (fields, 0..) |field, index| headers.elements_ptr.?[index] = .{
        .name = bridge.GeneratedRocStr.fromSlice(field.name, host),
        .value = bridge.GeneratedRocStr.fromSlice(field.value, host),
    };
    return .{ .status = status, .headers = headers, .trailers = bridge.HttpResponseHeaderList.empty(), .body = responseBody(body, host) };
}
