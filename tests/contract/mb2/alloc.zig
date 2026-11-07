//! Allocation prefixes select the original domain for free and realloc.
//! Tracking detects individual leaks that arena reset would otherwise hide.
//! Size and metadata occupy the final two prefix words at every alignment.
const std = @import("std");

// Prefix: padding, metadata, size, then user data.
// Metadata bit 0 selects the domain; higher bits store the generation.
const Meta = struct {
    const domain_mask: usize = 1;
    const generation_shift: u6 = 1;

    fn pack(domain: Domain, generation: usize) usize {
        return (generation << generation_shift) | @intFromEnum(domain);
    }

    fn domainOf(meta: usize) Domain {
        return @enumFromInt(meta & domain_mask);
    }

    fn generationOf(meta: usize) usize {
        return meta >> generation_shift;
    }
};

pub const Domain = enum(u1) {
    persistent = 0,
    request = 1,
};

fn prefixBytes(alignment: usize) usize {
    return @max(alignment, 2 * @sizeOf(usize));
}

fn backingAlignment(alignment: usize) std.mem.Alignment {
    return std.mem.Alignment.fromByteUnits(@max(alignment, @alignOf(usize)));
}

fn storedTotalSize(ptr: *const anyopaque) usize {
    const p: *const usize = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize));
    return p.*;
}

fn storedMeta(ptr: *const anyopaque) usize {
    const p: *const usize = @ptrFromInt(@intFromPtr(ptr) - 2 * @sizeOf(usize));
    return p.*;
}

fn basePtr(ptr: *anyopaque, alignment: usize) [*]u8 {
    return @ptrFromInt(@intFromPtr(ptr) - prefixBytes(alignment));
}

pub const Mode = enum {
    general,
    arena,
    tracking,
};

const canary_size = 16;
const canary_byte: u8 = 0xA5;
const poison_byte: u8 = 0xCC;
const freed_byte: u8 = 0xDD;

pub const HostAllocator = struct {
    mode: Mode,

    persistent: std.mem.Allocator,
    arena: std.mem.Allocator,

    generation: usize = 0,

    current_domain: Domain = .persistent,

    persistent_live: i64 = 0,
    request_live: i64 = 0,
    alloc_count: u64 = 0,
    dealloc_count: u64 = 0,

    canary_violations: u64 = 0,
    stale_generation_hits: u64 = 0,
    domain_mismatch: u64 = 0,
    double_free: u64 = 0,
    request_leaks: u64 = 0,

    const Self = @This();

    pub fn enterDomain(self: *Self, domain: Domain) void {
        self.current_domain = domain;
    }
    pub fn resetRequestArena(self: *Self) void {
        if (self.mode == .tracking and self.request_live != 0) {
            self.request_leaks += @intCast(self.request_live);
        }
        self.generation += 1;
        self.request_live = 0;
    }

    pub fn alloc(self: *Self, length: usize, alignment: usize) ?*anyopaque {
        const prefix = prefixBytes(alignment);
        const guard: usize = if (self.mode == .tracking) canary_size else 0;
        const total = prefix + length + guard;

        const backing = switch (self.current_domain) {
            .persistent => self.persistent,
            .request => self.arena,
        };

        const base = backing.rawAlloc(total, backingAlignment(alignment), @returnAddress()) orelse return null;

        const meta_ptr: *usize = @ptrFromInt(@intFromPtr(base) + prefix - 2 * @sizeOf(usize));
        meta_ptr.* = Meta.pack(self.current_domain, self.generation);

        const size_ptr: *usize = @ptrFromInt(@intFromPtr(base) + prefix - @sizeOf(usize));
        size_ptr.* = total;

        const user: [*]u8 = @ptrFromInt(@intFromPtr(base) + prefix);
        std.debug.assert(@intFromPtr(user) % @max(alignment, 1) == 0);

        if (self.mode == .tracking) {
            @memset(user[0..length], poison_byte);
            @memset((user + length)[0..canary_size], canary_byte);
        }

        self.alloc_count += 1;
        switch (self.current_domain) {
            .persistent => self.persistent_live += 1,
            .request => self.request_live += 1,
        }
        return @ptrCast(user);
    }

    pub fn dealloc(self: *Self, ptr: *anyopaque, alignment: usize) void {
        const meta = storedMeta(ptr);
        const domain = Meta.domainOf(meta);
        const gen = Meta.generationOf(meta);
        const total = storedTotalSize(ptr);
        const prefix = prefixBytes(alignment);

        if (domain != self.current_domain) {
            self.domain_mismatch += 1;
        }

        if (self.mode == .tracking and total == 0) {
            self.double_free += 1;
            return;
        }

        if (domain == .request and gen != self.generation) {
            self.stale_generation_hits += 1;
            return;
        }

        if (self.mode == .tracking) {
            const user: [*]u8 = @ptrCast(ptr);
            const user_len = total - prefix - canary_size;
            for (0..canary_size) |i| {
                if ((user + user_len)[i] != canary_byte) {
                    self.canary_violations += 1;
                    break;
                }
            }
            @memset(user[0..user_len], freed_byte);
        }

        self.dealloc_count += 1;
        switch (domain) {
            .persistent => self.persistent_live -= 1,
            .request => self.request_live -= 1,
        }

        switch (self.mode) {
            .arena => {
                if (domain == .persistent) {
                    self.persistent.rawFree(basePtr(ptr, alignment)[0..total], backingAlignment(alignment), @returnAddress());
                }
            },
            .general, .tracking => {
                const size_ptr: *usize = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize));
                size_ptr.* = 0;
                const backing = switch (domain) {
                    .persistent => self.persistent,
                    .request => self.arena,
                };
                backing.rawFree(basePtr(ptr, alignment)[0..total], backingAlignment(alignment), @returnAddress());
            },
        }
    }

    pub fn realloc(self: *Self, ptr: *anyopaque, new_length: usize, alignment: usize) ?*anyopaque {
        const meta = storedMeta(ptr);
        const domain = Meta.domainOf(meta);
        const old_total = storedTotalSize(ptr);
        const prefix = prefixBytes(alignment);

        const saved = self.current_domain;
        self.current_domain = domain;
        defer self.current_domain = saved;

        const new_ptr = self.alloc(new_length, alignment) orelse return null;

        const guard: usize = if (self.mode == .tracking) canary_size else 0;
        const old_user_len = old_total - prefix - guard;
        const copy = @min(old_user_len, new_length);
        const dst: [*]u8 = @ptrCast(new_ptr);
        const src: [*]const u8 = @ptrCast(ptr);
        @memcpy(dst[0..copy], src[0..copy]);

        self.dealloc(ptr, alignment);
        return new_ptr;
    }

    pub fn errorCount(self: *const Self) u64 {
        return self.canary_violations + self.stale_generation_hits +
            self.double_free + self.request_leaks;
    }

    pub fn report(self: *const Self) void {
        std.debug.print(
            \\  mode                   = {s}
            \\  generation             = {d}
            \\  alloc_count            = {d}
            \\  dealloc_count          = {d}
            \\  persistent_live        = {d}
            \\  request_live           = {d}
            \\  --- detected ---
            \\  canary_violations      = {d}
            \\  stale_generation_hits  = {d}
            \\  double_free            = {d}
            \\  request_leaks          = {d}
            \\  --- for reference ---
            \\  domain_mismatch        = {d}   (frees that disagree with the phase; not an error)
            \\
        , .{
            @tagName(self.mode),    self.generation,
            self.alloc_count,       self.dealloc_count,
            self.persistent_live,   self.request_live,
            self.canary_violations, self.stale_generation_hits,
            self.double_free,       self.request_leaks,
            self.domain_mismatch,
        });
    }
};
