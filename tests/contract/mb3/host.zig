//! Verify allocation context across all compiler backends.
//! Compiled extern allocation calls have no env argument; generated host helpers use the vtable.
const std = @import("std");
const abi = @import("roc_platform_abi");

const RequestContext = struct {
    request_id: u64,
    allocs: u64 = 0,
};

threadlocal var current_request: ?*RequestContext = null;

const Domain = enum { persistent, request };

const Stats = struct {
    persistent_allocs: u64 = 0,
    request_allocs: u64 = 0,
    context_missing: u64 = 0,
    per_request: [8]u64 = @as([8]u64, @splat(0)),
    extern_allocs: u64 = 0,
    vtable_allocs: u64 = 0,
    vtable_deallocs: u64 = 0,
};

var stats: Stats = .{};
threadlocal var phase: Domain = .persistent;

fn hostAlloc(length: usize, alignment: usize) callconv(std.builtin.CallingConvention.c) ?*anyopaque {
    const Header = extern struct {
        raw: *anyopaque,
        length: usize,
    };
    const user_alignment = @max(alignment, @alignOf(usize));
    const total = length + @sizeOf(Header) + user_alignment - 1;
    const raw = std.c.malloc(total) orelse return null;
    const user: [*]u8 = @ptrFromInt(std.mem.alignForward(
        usize,
        @intFromPtr(raw) + @sizeOf(Header),
        user_alignment,
    ));

    const header: *Header = @ptrFromInt(@intFromPtr(user) - @sizeOf(Header));
    header.* = .{ .raw = raw, .length = length };

    switch (phase) {
        .persistent => stats.persistent_allocs += 1,
        .request => {
            stats.request_allocs += 1;
            if (current_request) |ctx| {
                ctx.allocs += 1;
                if (ctx.request_id < stats.per_request.len) {
                    stats.per_request[ctx.request_id] += 1;
                }
            } else {
                stats.context_missing += 1;
            }
        },
    }
    return @ptrCast(user);
}

fn hostDealloc(ptr: *anyopaque, alignment: usize) callconv(std.builtin.CallingConvention.c) void {
    _ = alignment;
    const Header = extern struct { raw: *anyopaque, length: usize };
    const header: *const Header = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(Header));
    std.c.free(header.raw);
}

fn hostRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(std.builtin.CallingConvention.c) ?*anyopaque {
    const Header = extern struct { raw: *anyopaque, length: usize };
    const old_header: *const Header = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(Header));
    const copy_length = @min(old_header.length, new_length);
    const new_ptr = hostAlloc(new_length, alignment) orelse return null;
    const dst: [*]u8 = @ptrCast(new_ptr);
    const src: [*]const u8 = @ptrCast(ptr);
    @memcpy(dst[0..copy_length], src[0..copy_length]);
    hostDealloc(ptr, alignment);
    return new_ptr;
}

export fn roc_alloc(length: usize, alignment: usize) callconv(std.builtin.CallingConvention.c) *anyopaque {
    stats.extern_allocs += 1;
    return hostAlloc(length, alignment) orelse @panic("out of memory");
}
export fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(std.builtin.CallingConvention.c) void {
    hostDealloc(ptr, alignment);
}
export fn roc_realloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(std.builtin.CallingConvention.c) *anyopaque {
    return hostRealloc(ptr, new_length, alignment) orelse @panic("out of memory");
}
export fn roc_dbg(bytes: [*]const u8, len: usize) callconv(std.builtin.CallingConvention.c) void {
    std.debug.print("[dbg] {s}\n", .{bytes[0..len]});
}
export fn roc_expect_failed(bytes: [*]const u8, len: usize) callconv(std.builtin.CallingConvention.c) void {
    std.debug.print("[expect failed] {s}\n", .{bytes[0..len]});
}
export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(std.builtin.CallingConvention.c) noreturn {
    std.debug.print("[crashed] {s}\n", .{bytes[0..len]});
    std.process.exit(1);
}

pub fn main() !void {
    std.debug.print("MB-3 req-ctx spike\n\n", .{});

    phase = .persistent;
    current_request = null;
    const root = abi.roc_init();
    const init_allocs = stats.persistent_allocs;

    std.debug.print("after init:\n", .{});
    std.debug.print("  persistent_allocs = {d}\n\n", .{init_allocs});

    var req: u64 = 0;
    while (req < 4) : (req += 1) {
        var ctx = RequestContext{ .request_id = req };

        phase = .request;
        current_request = &ctx;
        defer {
            current_request = null;
            phase = .persistent;
        }

        abi.increfBox(root, 1);
        const reply = abi.roc_handle(root, req);

        const slice = rocStrSlice(&reply);
        std.debug.print("req {d}: allocs={d} reply=\"{s}\"\n", .{ req, ctx.allocs, slice });

        reply.decref(&roc_host);
    }

    abi.decrefBox(root, &roc_host);

    std.debug.print("\nresult:\n", .{});
    std.debug.print("  persistent_allocs = {d}\n", .{stats.persistent_allocs});
    std.debug.print("  request_allocs    = {d}\n", .{stats.request_allocs});
    std.debug.print("  context_missing   = {d}   <- 0 when the context arrived\n", .{stats.context_missing});
    std.debug.print("  per_request       = [{d}, {d}, {d}, {d}]\n", .{
        stats.per_request[0], stats.per_request[1],
        stats.per_request[2], stats.per_request[3],
    });

    std.debug.print("\noption A (RocOps.env):\n", .{});
    std.debug.print("  extern roc_alloc  = {d} (no env argument)\n", .{stats.extern_allocs});
    std.debug.print("  vtable roc_alloc  = {d} (host helpers only)\n", .{stats.vtable_allocs});
    std.debug.print("  vtable roc_dealloc= {d} (sees env)\n", .{stats.vtable_deallocs});

    const ok = stats.context_missing == 0 and stats.request_allocs > 0;
    std.debug.print("\n  {s}\n", .{if (ok) "PASS — the context arrived through a thread-local" else "FAIL"});
    if (!ok) std.process.exit(1);
}

fn rocStrSlice(s: *const abi.RocStr) []const u8 {
    return s.asSlice();
}

fn vtAlloc(host: *abi.RocHost, length: usize, alignment: usize) callconv(std.builtin.CallingConvention.c) *anyopaque {
    if (@intFromPtr(host.env) != 0) stats.vtable_allocs += 1;
    return hostAlloc(length, alignment) orelse @panic("out of memory");
}
fn vtDealloc(host: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(std.builtin.CallingConvention.c) void {
    if (@intFromPtr(host.env) != 0) stats.vtable_deallocs += 1;
    hostDealloc(ptr, alignment);
}
fn vtRealloc(host: *abi.RocHost, ptr: *anyopaque, new_length: usize, alignment: usize) callconv(std.builtin.CallingConvention.c) *anyopaque {
    _ = host;
    return hostRealloc(ptr, new_length, alignment) orelse @panic("out of memory");
}
fn vtDbg(host: *abi.RocHost, bytes: [*]const u8, len: usize) callconv(std.builtin.CallingConvention.c) void {
    _ = host;
    std.debug.print("[dbg] {s}\n", .{bytes[0..len]});
}
fn vtExpectFailed(host: *abi.RocHost, bytes: [*]const u8, len: usize) callconv(std.builtin.CallingConvention.c) void {
    _ = host;
    std.debug.print("[expect failed] {s}\n", .{bytes[0..len]});
}
fn vtCrashed(host: *abi.RocHost, bytes: [*]const u8, len: usize) callconv(std.builtin.CallingConvention.c) void {
    _ = host;
    std.debug.print("[crashed] {s}\n", .{bytes[0..len]});
    std.process.exit(1);
}

var env_marker: u64 = 0xEE;

var roc_host: abi.RocHost = .{
    .env = @ptrCast(&env_marker),
    .roc_alloc = &vtAlloc,
    .roc_dealloc = &vtDealloc,
    .roc_realloc = &vtRealloc,
    .roc_dbg = &vtDbg,
    .roc_expect_failed = &vtExpectFailed,
    .roc_crashed = &vtCrashed,
};
