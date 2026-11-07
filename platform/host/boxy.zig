//! Whether the app links Roc's erased-callable runtime ("boxy").
//!
//! The runtime keeps one state per process and updates it without a lock:
//! each erased callable an app builds (a `Box`ed function, such as a stream
//! producer) is registered in a shared table (roc-lang/roc#12267, and the
//! registration in Roc's `src/eval/boxy_abi.zig`). An app that links the
//! runtime is safe only while one thread runs its Roc code. The host's own
//! entry passes no function value, so an app links the runtime only when it
//! builds erased callables itself.
//!
//! The host reads its own executable's symbol table once, at startup: a weak
//! reference to the runtime would be simpler, but Zig does not mark one weak
//! in Mach-O, so an app without the runtime would not link. An executable
//! without a symbol table (stripped) counts as linking the runtime, so a
//! doubt costs threads, never safety.
const std = @import("std");
const builtin = @import("builtin");

/// What the symbol table says about the runtime's initializer, which
/// generated code calls before anything else when the app uses the runtime.
pub const Presence = enum {
    present,
    absent,
    /// No symbol table, or one this code cannot read.
    unknown,
};

const symbol = "roc_boxy_init_embedded";

var cached: ?Presence = null;

/// True unless the executable's symbol table shows the runtime is absent.
pub fn linked() bool {
    const presence = cached orelse blk: {
        const found = scanSelf();
        cached = found;
        break :blk found;
    };
    return presence != Presence.absent;
}

fn scanSelf() Presence {
    var path_buffer: [std.c.PATH_MAX]u8 = undefined;
    const path = selfPath(&path_buffer) orelse return Presence.unknown;
    const file = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (file < 0) return Presence.unknown;
    defer _ = std.c.close(file);
    // The size by seeking to the end: Zig's libc bindings have no fstat on
    // every target.
    const end = std.c.lseek(file, 0, std.c.SEEK.END);
    if (end <= 0) return Presence.unknown;
    const size: usize = @intCast(end);
    const mapped = std.c.mmap(null, size, .{ .READ = true }, .{ .TYPE = @FieldType(std.c.MAP, "TYPE").PRIVATE }, file, 0);
    if (mapped == std.c.MAP_FAILED) return Presence.unknown;
    defer _ = std.c.munmap(@alignCast(mapped), size);
    const bytes: [*]const u8 = @ptrCast(mapped);
    return scan(bytes[0..size]);
}

extern "c" fn _NSGetExecutablePath(buffer: [*]u8, size: *u32) c_int;

fn selfPath(buffer: *[std.c.PATH_MAX]u8) ?[*:0]const u8 {
    switch (builtin.os.tag) {
        std.Target.Os.Tag.macos => {
            var size: u32 = buffer.len;
            if (_NSGetExecutablePath(buffer, &size) != 0) return null;
            return @ptrCast(buffer);
        },
        std.Target.Os.Tag.linux => {
            const length = std.c.readlink("/proc/self/exe", buffer, buffer.len - 1);
            if (length <= 0) return null;
            buffer[@intCast(length)] = 0;
            return @ptrCast(buffer);
        },
        else => return null,
    }
}

/// Looks for the runtime's initializer among the defined symbols of a
/// 64-bit little-endian Mach-O or ELF image.
pub fn scan(bytes: []const u8) Presence {
    if (bytes.len < 4) return Presence.unknown;
    if (read(u32, bytes, 0) == 0xfeedfacf) return scanMachO(bytes);
    if (std.mem.eql(u8, bytes[0..4], "\x7fELF")) return scanElf(bytes);
    return Presence.unknown;
}

fn read(comptime T: type, bytes: []const u8, offset: usize) ?T {
    if (offset > bytes.len or bytes.len - offset < @sizeOf(T)) return null;
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], std.builtin.Endian.little);
}

/// The NUL-terminated name at `offset` in a string table.
fn nameAt(strings: []const u8, offset: usize) ?[]const u8 {
    if (offset >= strings.len) return null;
    const end = std.mem.indexOfScalarPos(u8, strings, offset, 0) orelse return null;
    return strings[offset..end];
}

fn scanMachO(bytes: []const u8) Presence {
    const lc_symtab: u32 = 0x2;
    const commands = read(u32, bytes, 16) orelse return Presence.unknown;
    var offset: usize = 32;
    for (0..commands) |_| {
        const command = read(u32, bytes, offset) orelse return Presence.unknown;
        const size = read(u32, bytes, offset + 4) orelse return Presence.unknown;
        if (size < 8) return Presence.unknown;
        if (command == lc_symtab) {
            const symbols_at = read(u32, bytes, offset + 8) orelse return Presence.unknown;
            const count = read(u32, bytes, offset + 12) orelse return Presence.unknown;
            const strings_at = read(u32, bytes, offset + 16) orelse return Presence.unknown;
            const strings_size = read(u32, bytes, offset + 20) orelse return Presence.unknown;
            if (@as(usize, strings_at) + strings_size > bytes.len) return Presence.unknown;
            const strings = bytes[strings_at..][0..strings_size];
            for (0..count) |index| {
                const entry = @as(usize, symbols_at) + index * 16;
                const name_at = read(u32, bytes, entry) orelse return Presence.unknown;
                const kind = read(u8, bytes, entry + 4) orelse return Presence.unknown;
                // Not a debugging entry, and defined (N_TYPE is not N_UNDF).
                if (kind & 0xe0 != 0 or kind & 0x0e == 0) continue;
                const name = nameAt(strings, name_at) orelse continue;
                if (name.len == symbol.len + 1 and name[0] == '_' and std.mem.eql(u8, name[1..], symbol)) return Presence.present;
            }
            return Presence.absent;
        }
        offset += size;
    }
    return Presence.unknown;
}

fn scanElf(bytes: []const u8) Presence {
    // 64-bit, little-endian.
    if (bytes.len < 0x40 or bytes[4] != 2 or bytes[5] != 1) return Presence.unknown;
    const sections_at = read(u64, bytes, 0x28) orelse return Presence.unknown;
    const section_size = read(u16, bytes, 0x3a) orelse return Presence.unknown;
    const section_count = read(u16, bytes, 0x3c) orelse return Presence.unknown;
    if (section_size < 0x40) return Presence.unknown;
    var found_table = false;
    for (0..section_count) |index| {
        const header = sections_at + index * section_size;
        const kind = read(u32, bytes, header + 4) orelse return Presence.unknown;
        if (kind != 2) continue; // SHT_SYMTAB
        found_table = true;
        const table_at = read(u64, bytes, header + 0x18) orelse return Presence.unknown;
        const table_size = read(u64, bytes, header + 0x20) orelse return Presence.unknown;
        const link = read(u32, bytes, header + 0x28) orelse return Presence.unknown;
        const entry_size = read(u64, bytes, header + 0x38) orelse return Presence.unknown;
        if (entry_size < 24 or link >= section_count) return Presence.unknown;
        const strings_header = sections_at + @as(u64, link) * section_size;
        const strings_at = read(u64, bytes, strings_header + 0x18) orelse return Presence.unknown;
        const strings_size = read(u64, bytes, strings_header + 0x20) orelse return Presence.unknown;
        if (strings_at + strings_size > bytes.len or table_at + table_size > bytes.len) return Presence.unknown;
        const strings = bytes[strings_at..][0..strings_size];
        var entry = table_at;
        while (entry + 24 <= table_at + table_size) : (entry += entry_size) {
            const name_at = read(u32, bytes, entry) orelse return Presence.unknown;
            const section = read(u16, bytes, entry + 6) orelse return Presence.unknown;
            if (section == 0) continue; // SHN_UNDEF
            const name = nameAt(strings, name_at) orelse continue;
            if (std.mem.eql(u8, name, symbol)) return Presence.present;
        }
    }
    return if (found_table) Presence.absent else Presence.unknown;
}

const testing = std.testing;

/// A Mach-O image with one LC_SYMTAB holding the given symbols, each
/// defined (`N_SECT`) or not.
fn machOImage(buffer: []u8, symbols: []const struct { name: []const u8, defined: bool }) []const u8 {
    @memset(buffer, 0);
    std.mem.writeInt(u32, buffer[0..4], 0xfeedfacf, std.builtin.Endian.little);
    std.mem.writeInt(u32, buffer[16..20], 1, std.builtin.Endian.little);
    const command = buffer[32..];
    std.mem.writeInt(u32, command[0..4], 0x2, std.builtin.Endian.little);
    std.mem.writeInt(u32, command[4..8], 24, std.builtin.Endian.little);
    const symbols_at: u32 = 64;
    const strings_at: u32 = symbols_at + @as(u32, @intCast(symbols.len)) * 16;
    var string_length: u32 = 1;
    for (symbols, 0..) |item, index| {
        const entry = buffer[symbols_at + index * 16 ..];
        std.mem.writeInt(u32, entry[0..4], string_length, std.builtin.Endian.little);
        entry[4] = if (item.defined) 0x0f else 0x01;
        @memcpy(buffer[strings_at + string_length ..][0..item.name.len], item.name);
        string_length += @intCast(item.name.len + 1);
    }
    std.mem.writeInt(u32, command[8..12], symbols_at, std.builtin.Endian.little);
    std.mem.writeInt(u32, command[12..16], @intCast(symbols.len), std.builtin.Endian.little);
    std.mem.writeInt(u32, command[16..20], strings_at, std.builtin.Endian.little);
    std.mem.writeInt(u32, command[20..24], string_length, std.builtin.Endian.little);
    return buffer[0 .. strings_at + string_length];
}

test "a Mach-O image with the runtime defined, only referenced, or absent" {
    var buffer: [512]u8 = undefined;
    try testing.expectEqual(Presence.present, scan(machOImage(&buffer, &.{ .{ .name = "_main", .defined = true }, .{ .name = "_roc_boxy_init_embedded", .defined = true } })));
    try testing.expectEqual(Presence.absent, scan(machOImage(&buffer, &.{.{ .name = "_roc_boxy_init_embedded", .defined = false }})));
    try testing.expectEqual(Presence.absent, scan(machOImage(&buffer, &.{.{ .name = "_roc_boxy_init_embeddedX", .defined = true }})));
    try testing.expectEqual(Presence.absent, scan(machOImage(&buffer, &.{})));
}

test "an image this code cannot read counts as unknown" {
    try testing.expectEqual(Presence.unknown, scan(""));
    try testing.expectEqual(Presence.unknown, scan("#!/bin/sh\n"));
    var buffer: [512]u8 = undefined;
    const image = machOImage(&buffer, &.{.{ .name = "_roc_boxy_init_embedded", .defined = true }});
    // Cut inside the symbol table.
    try testing.expectEqual(Presence.unknown, scan(image[0..70]));
}

test "an ELF image with a symbol table, and one without" {
    var buffer: [1024]u8 = undefined;
    @memset(&buffer, 0);
    @memcpy(buffer[0..4], "\x7fELF");
    buffer[4] = 2;
    buffer[5] = 1;
    const sections_at: u64 = 0x100;
    std.mem.writeInt(u64, buffer[0x28..0x30], sections_at, std.builtin.Endian.little);
    std.mem.writeInt(u16, buffer[0x3a..0x3c], 0x40, std.builtin.Endian.little);
    std.mem.writeInt(u16, buffer[0x3c..0x3e], 3, std.builtin.Endian.little);
    // Section 1: .symtab at 0x300 with two entries; section 2: .strtab at 0x380.
    const symtab = buffer[sections_at + 0x40 ..];
    std.mem.writeInt(u32, symtab[4..8], 2, std.builtin.Endian.little);
    std.mem.writeInt(u64, symtab[0x18..0x20], 0x300, std.builtin.Endian.little);
    std.mem.writeInt(u64, symtab[0x20..0x28], 48, std.builtin.Endian.little);
    std.mem.writeInt(u32, symtab[0x28..0x2c], 2, std.builtin.Endian.little);
    std.mem.writeInt(u64, symtab[0x38..0x40], 24, std.builtin.Endian.little);
    const strtab = buffer[sections_at + 0x80 ..];
    std.mem.writeInt(u32, strtab[4..8], 3, std.builtin.Endian.little);
    std.mem.writeInt(u64, strtab[0x18..0x20], 0x380, std.builtin.Endian.little);
    std.mem.writeInt(u64, strtab[0x20..0x28], 64, std.builtin.Endian.little);
    @memcpy(buffer[0x381..][0..symbol.len], symbol);
    // Entry 0 is the null symbol; entry 1 names the runtime, undefined.
    std.mem.writeInt(u32, buffer[0x318..0x31c], 1, std.builtin.Endian.little);
    try testing.expectEqual(Presence.absent, scan(&buffer));
    // Defined in section 5.
    std.mem.writeInt(u16, buffer[0x31e..0x320], 5, std.builtin.Endian.little);
    try testing.expectEqual(Presence.present, scan(&buffer));
    // Without the symbol table section: stripped.
    std.mem.writeInt(u32, symtab[4..8], 1, std.builtin.Endian.little);
    try testing.expectEqual(Presence.unknown, scan(&buffer));
}

test "this test executable has a symbol table without the runtime" {
    if (builtin.os.tag != std.Target.Os.Tag.macos and builtin.os.tag != std.Target.Os.Tag.linux) return error.SkipZigTest;
    try testing.expectEqual(Presence.absent, scanSelf());
}
