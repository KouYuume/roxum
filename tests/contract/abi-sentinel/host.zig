//! Semantic ABI sentinel for compiler/glue compatibility.
//! The two directions are intentionally independent:
//! - `roc_inspect` makes Roc interpret a host-built value and returns a scalar score.
//! - `roc_produce` makes Roc build a value that the host checks field by field.
//! An identity round trip could let the same layout mistake cancel in both directions.

const std = @import("std");
const abi = @import("roc_platform_abi");

const expected_code: u64 = 0x0102030405060708;
const expected_pair_right: u64 = 0x1112131415161718;
const expected_pair_left: u16 = 0x1234;
const expected_byte: u8 = 0xA5;
const short_bytes = "abcdefghijklmnopqrstuvw";
const boundary_heap_bytes = "abcdefghijklmnopqrstuvwx";
const allocation_magic: usize = 0x524f58554d414249;

const AllocationHeader = extern struct {
    raw: *anyopaque,
    length: usize,
    magic: usize,
};

const Tracker = struct {
    live_count: usize = 0,
    peak_live: usize = 0,
    alloc_count: usize = 0,
    dealloc_count: usize = 0,

    fn alloc(self: *Tracker, length: usize, alignment: usize) ?*anyopaque {
        const user_alignment = @max(alignment, @alignOf(usize));
        const total = @sizeOf(AllocationHeader) + user_alignment - 1 + length;
        const raw = std.c.malloc(total) orelse return null;
        const user_address = std.mem.alignForward(
            usize,
            @intFromPtr(raw) + @sizeOf(AllocationHeader),
            user_alignment,
        );
        const header: *AllocationHeader = @ptrFromInt(
            user_address - @sizeOf(AllocationHeader),
        );
        header.* = .{
            .raw = raw,
            .length = length,
            .magic = allocation_magic,
        };

        self.live_count += 1;
        self.alloc_count += 1;
        self.peak_live = @max(self.peak_live, self.live_count);
        return @ptrFromInt(user_address);
    }

    fn dealloc(self: *Tracker, pointer: *anyopaque) void {
        const header = headerFor(pointer);
        if (header.magic != allocation_magic) {
            std.debug.print("invalid or duplicate ABI sentinel free\n", .{});
            std.process.exit(1);
        }
        header.magic = 0;
        std.c.free(header.raw);
        self.live_count -= 1;
        self.dealloc_count += 1;
    }

    fn realloc(
        self: *Tracker,
        pointer: *anyopaque,
        new_length: usize,
        alignment: usize,
    ) ?*anyopaque {
        const old_length = headerFor(pointer).length;
        const new_pointer = self.alloc(new_length, alignment) orelse return null;
        const source: [*]const u8 = @ptrCast(pointer);
        const destination: [*]u8 = @ptrCast(new_pointer);
        const copy_length = @min(old_length, new_length);
        @memcpy(destination[0..copy_length], source[0..copy_length]);
        self.dealloc(pointer);
        return new_pointer;
    }
};

var tracker: Tracker = .{};

fn headerFor(pointer: *anyopaque) *AllocationHeader {
    return @ptrFromInt(@intFromPtr(pointer) - @sizeOf(AllocationHeader));
}

export fn roc_alloc(length: usize, alignment: usize) callconv(std.builtin.CallingConvention.c) *anyopaque {
    return tracker.alloc(length, alignment) orelse @panic("out of memory");
}

export fn roc_dealloc(pointer: *anyopaque, alignment: usize) callconv(std.builtin.CallingConvention.c) void {
    _ = alignment;
    tracker.dealloc(pointer);
}

export fn roc_realloc(
    pointer: *anyopaque,
    new_length: usize,
    alignment: usize,
) callconv(std.builtin.CallingConvention.c) *anyopaque {
    return tracker.realloc(pointer, new_length, alignment) orelse @panic("out of memory");
}

export fn roc_dbg(bytes: [*]const u8, length: usize) callconv(std.builtin.CallingConvention.c) void {
    std.debug.print("[roc dbg] {s}\n", .{bytes[0..length]});
}

export fn roc_expect_failed(bytes: [*]const u8, length: usize) callconv(std.builtin.CallingConvention.c) void {
    std.debug.print("[roc expect failed] {s}\n", .{bytes[0..length]});
}

export fn roc_crashed(bytes: [*]const u8, length: usize) callconv(std.builtin.CallingConvention.c) noreturn {
    std.debug.print("[roc crashed] {s}\n", .{bytes[0..length]});
    std.process.exit(1);
}

fn vtableAlloc(
    roc_host: *abi.RocHost,
    length: usize,
    alignment: usize,
) callconv(std.builtin.CallingConvention.c) *anyopaque {
    _ = roc_host;
    return tracker.alloc(length, alignment) orelse @panic("out of memory");
}

fn vtableDealloc(
    roc_host: *abi.RocHost,
    pointer: *anyopaque,
    alignment: usize,
) callconv(std.builtin.CallingConvention.c) void {
    _ = roc_host;
    _ = alignment;
    tracker.dealloc(pointer);
}

fn vtableRealloc(
    roc_host: *abi.RocHost,
    pointer: *anyopaque,
    new_length: usize,
    alignment: usize,
) callconv(std.builtin.CallingConvention.c) *anyopaque {
    _ = roc_host;
    return tracker.realloc(pointer, new_length, alignment) orelse @panic("out of memory");
}

fn vtableDbg(
    roc_host: *abi.RocHost,
    bytes: [*]const u8,
    length: usize,
) callconv(std.builtin.CallingConvention.c) void {
    _ = roc_host;
    roc_dbg(bytes, length);
}

fn vtableExpectFailed(
    roc_host: *abi.RocHost,
    bytes: [*]const u8,
    length: usize,
) callconv(std.builtin.CallingConvention.c) void {
    _ = roc_host;
    roc_expect_failed(bytes, length);
}

fn vtableCrashed(
    roc_host: *abi.RocHost,
    bytes: [*]const u8,
    length: usize,
) callconv(std.builtin.CallingConvention.c) void {
    _ = roc_host;
    std.debug.print("[roc crashed] {s}\n", .{bytes[0..length]});
    std.process.exit(1);
}

var environment_marker: u8 = 0;
var helper_context: abi.RocHost = .{
    .env = @ptrCast(&environment_marker),
    .roc_alloc = &vtableAlloc,
    .roc_dealloc = &vtableDealloc,
    .roc_realloc = &vtableRealloc,
    .roc_dbg = &vtableDbg,
    .roc_expect_failed = &vtableExpectFailed,
    .roc_crashed = &vtableCrashed,
};

fn choiceFor(case_id: u8) abi.AbiChoice {
    var choice = std.mem.zeroes(abi.AbiChoice);
    switch (case_id) {
        0 => choice.tag = abi.AbiChoiceTag.Empty,
        1 => {
            choice.tag = abi.AbiChoiceTag.Byte;
            choice.payload.byte = expected_byte;
        },
        2 => {
            choice.tag = abi.AbiChoiceTag.Pair;
            choice.payload.pair = .{
                .left = expected_pair_left,
                .right = expected_pair_right,
            };
        },
        3 => {
            choice.tag = abi.AbiChoiceTag.Text;
            choice.payload.text = abi.RocStr.fromSlice(
                boundary_heap_bytes,
                &helper_context,
            );
        },
        else => unreachable,
    }
    return choice;
}

fn probeFor(case_id: u8) abi.AbiProbe {
    return .{
        .choice = choiceFor(case_id),
        .code = expected_code,
        .empty = abi.RocStr.fromSlice("", &helper_context),
        .list_empty = abi.RocListWith(u8, false).fromSlice(&.{}, &helper_context),
        .list_many = abi.RocListWith(u8, false).fromSlice(
            &.{ 0x11, 0x22, 0x33 },
            &helper_context,
        ),
        .list_one = abi.RocListWith(u8, false).fromSlice(
            &.{expected_byte},
            &helper_context,
        ),
        .long = abi.RocStr.fromSlice(boundary_heap_bytes, &helper_context),
        .short = abi.RocStr.fromSlice(short_bytes, &helper_context),
    };
}

fn expect(condition: bool, message: []const u8) !void {
    if (condition) return;
    std.debug.print("ABI sentinel assertion failed: {s}\n", .{message});
    return error.AbiSentinelMismatch;
}

fn expectBytes(actual: []const u8, expected: []const u8, field: []const u8) !void {
    if (std.mem.eql(u8, actual, expected)) return;
    std.debug.print(
        "ABI sentinel field mismatch: {s}: expected={any} actual={any}\n",
        .{ field, expected, actual },
    );
    return error.AbiSentinelMismatch;
}

fn checkProducedProbe(probe: *const abi.AbiProbe, case_id: u8) !void {
    try expect(probe.code == expected_code, "code");
    try expectBytes(probe.empty.asSlice(), "", "empty");
    try expectBytes(probe.short.asSlice(), short_bytes, "short");

    var expected_long_buffer: [24]u8 = undefined;
    @memcpy(expected_long_buffer[0..23], short_bytes);
    expected_long_buffer[23] = '0' + case_id;
    try expectBytes(probe.long.asSlice(), &expected_long_buffer, "long");

    try expect(probe.list_empty.items().len == 0, "list_empty");
    try expectBytes(probe.list_one.items(), &.{case_id}, "list_one");
    try expectBytes(
        probe.list_many.items(),
        &.{ 0x11, 0x22, case_id },
        "list_many",
    );

    switch (case_id) {
        0 => try expect(probe.choice.tag == abi.AbiChoiceTag.Empty, "choice Empty"),
        1 => {
            try expect(probe.choice.tag == abi.AbiChoiceTag.Byte, "choice Byte tag");
            try expect(probe.choice.payload_byte() == expected_byte, "choice Byte payload");
        },
        2 => {
            try expect(probe.choice.tag == abi.AbiChoiceTag.Pair, "choice Pair tag");
            const pair = probe.choice.payload_pair();
            try expect(pair.left == expected_pair_left, "choice Pair left");
            try expect(pair.right == expected_pair_right, "choice Pair right");
        },
        3 => {
            try expect(probe.choice.tag == abi.AbiChoiceTag.Text, "choice Text tag");
            try expectBytes(
                probe.choice.payload_text().asSlice(),
                &expected_long_buffer,
                "choice Text payload",
            );
        },
        else => unreachable,
    }
}

pub fn main() !void {
    const expected_scores = [_]u64{ 255, 383, 639, 1151 };

    for (expected_scores, 0..) |expected_score, index| {
        const case_id: u8 = @intCast(index);
        const score = abi.roc_inspect(probeFor(case_id));
        try expect(score == expected_score, "host-to-Roc field or tag mapping");
        try expect(tracker.live_count == 0, "host-to-Roc ownership baseline");
    }

    for (0..4) |index| {
        const case_id: u8 = @intCast(index);
        const probe = abi.roc_produce(case_id);
        try checkProducedProbe(&probe, case_id);
        probe.decref(&helper_context);
        try expect(tracker.live_count == 0, "Roc-to-host ownership baseline");
    }

    try expect(tracker.alloc_count > 0, "heap allocation coverage");
    try expect(tracker.alloc_count == tracker.dealloc_count, "balanced allocation counts");
    std.debug.print(
        "ABI sentinel: fields, variants, boundaries, and ownership verified (allocs={d}, peak={d})\n",
        .{ tracker.alloc_count, tracker.peak_live },
    );
}
