//! Routes Roc allocations to persistent or request backing allocators.

const std = @import("std");
const Meta = @import("meta.zig").Meta;
const Prefix = @import("prefix.zig").Prefix;

pub const Domain = @import("domain.zig").Domain;
pub const max_generation = Meta.max_generation;

pub const AllocationMetadata = struct {
    domain: Domain,
    generation: usize,
};

pub fn allocationMetadata(
    pointer: *const anyopaque,
) AllocationMetadata {
    const meta = Prefix.storedMeta(pointer);
    return .{
        .domain = Meta.domainOf(meta),
        .generation = Meta.generationOf(meta),
    };
}

pub const HostAllocator = struct {
    persistent_allocator: std.mem.Allocator,
    request_allocator: std.mem.Allocator,

    pub fn alloc(
        self: *HostAllocator,
        domain: Domain,
        generation: usize,
        length: usize,
        alignment: usize,
    ) ?*anyopaque {
        if (!isValidAlignment(alignment)) return null;

        const total_size = checkedTotalSize(
            length,
            alignment,
        ) orelse return null;

        const backing = self.allocatorFor(domain);

        const base = backing.rawAlloc(
            total_size,
            Prefix.backingAlignment(alignment),
            @returnAddress(),
        ) orelse return null;

        return Prefix.write(
            base,
            alignment,
            total_size,
            Meta.pack(domain, generation),
        );
    }

    pub fn dealloc(
        self: *HostAllocator,
        ptr: *anyopaque,
        alignment: usize,
    ) void {
        std.debug.assert(isValidAlignment(alignment));

        const meta = Prefix.storedMeta(ptr);
        const domain = Meta.domainOf(meta);
        const total_size = Prefix.storedTotalSize(ptr);
        const backing = self.allocatorFor(domain);

        backing.rawFree(
            Prefix.basePtr(ptr, alignment)[0..total_size],
            Prefix.backingAlignment(alignment),
            @returnAddress(),
        );
    }

    pub fn realloc(
        self: *HostAllocator,
        ptr: *anyopaque,
        new_length: usize,
        alignment: usize,
    ) ?*anyopaque {
        if (!isValidAlignment(alignment)) return null;

        const new_total_size = checkedTotalSize(
            new_length,
            alignment,
        ) orelse return null;

        const old_meta = Prefix.storedMeta(ptr);
        const domain = Meta.domainOf(old_meta);
        const generation = Meta.generationOf(old_meta);
        const old_total_size = Prefix.storedTotalSize(ptr);
        const old_base = Prefix.basePtr(ptr, alignment);
        const backing = self.allocatorFor(domain);

        // Growing or shrinking in place keeps the data where it is; only the
        // stored size changes.
        if (backing.rawResize(
            old_base[0..old_total_size],
            Prefix.backingAlignment(alignment),
            new_total_size,
            @returnAddress(),
        )) {
            return Prefix.write(old_base, alignment, new_total_size, old_meta);
        }

        const new_base = backing.rawAlloc(
            new_total_size,
            Prefix.backingAlignment(alignment),
            @returnAddress(),
        ) orelse return null;

        const copy_size = @min(
            old_total_size,
            new_total_size,
        );
        @memcpy(
            new_base[0..copy_size],
            old_base[0..copy_size],
        );

        const new_ptr = Prefix.write(
            new_base,
            alignment,
            new_total_size,
            Meta.pack(domain, generation),
        );

        backing.rawFree(
            old_base[0..old_total_size],
            Prefix.backingAlignment(alignment),
            @returnAddress(),
        );

        return new_ptr;
    }

    fn checkedTotalSize(
        length: usize,
        alignment: usize,
    ) ?usize {
        const prefix_length = Prefix.byteLength(alignment);
        if (length > std.math.maxInt(usize) - prefix_length) return null;
        return prefix_length + length;
    }

    fn isValidAlignment(alignment: usize) bool {
        return alignment != 0 and
            std.math.isPowerOfTwo(alignment);
    }

    fn allocatorFor(
        self: *const HostAllocator,
        domain: Domain,
    ) std.mem.Allocator {
        return switch (domain) {
            Domain.persistent => self.persistent_allocator,
            Domain.request => self.request_allocator,
        };
    }
};

test "isValidAlignment enforces positive powers of two" {
    try std.testing.expect(
        !HostAllocator.isValidAlignment(0),
    );
    try std.testing.expect(
        HostAllocator.isValidAlignment(1),
    );
    try std.testing.expect(
        HostAllocator.isValidAlignment(2),
    );
    try std.testing.expect(
        !HostAllocator.isValidAlignment(3),
    );
    try std.testing.expect(
        HostAllocator.isValidAlignment(4),
    );
}

test "checkedTotalSize handles length and overflow boundaries" {
    const alignment: usize = 16;
    const prefix = Prefix.byteLength(alignment);
    const max_length = std.math.maxInt(usize) - prefix;

    try std.testing.expectEqual(
        @as(?usize, prefix),
        HostAllocator.checkedTotalSize(0, alignment),
    );
    try std.testing.expectEqual(
        @as(?usize, std.math.maxInt(usize) - 1),
        HostAllocator.checkedTotalSize(max_length - 1, alignment),
    );
    try std.testing.expectEqual(
        @as(?usize, std.math.maxInt(usize)),
        HostAllocator.checkedTotalSize(max_length, alignment),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        HostAllocator.checkedTotalSize(max_length + 1, alignment),
    );
}

test "HostAllocator alloc and realloc preserve request metadata" {
    var host = HostAllocator{
        .persistent_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
    };

    const old_length: usize = 24;
    const new_length: usize = old_length + 1;
    const alignment: usize = 16;

    const old_ptr = host.alloc(
        Domain.request,
        7,
        old_length,
        alignment,
    ) orelse return error.OutOfMemory;

    const old_meta = Prefix.storedMeta(old_ptr);

    try std.testing.expectEqual(
        Domain.request,
        Meta.domainOf(old_meta),
    );
    try std.testing.expectEqual(
        @as(usize, 7),
        Meta.generationOf(old_meta),
    );

    const new_ptr = host.realloc(
        old_ptr,
        new_length,
        alignment,
    ) orelse {
        host.dealloc(old_ptr, alignment);
        return error.OutOfMemory;
    };
    defer host.dealloc(new_ptr, alignment);

    try std.testing.expectEqual(
        Prefix.byteLength(alignment) + new_length,
        Prefix.storedTotalSize(new_ptr),
    );

    const new_meta = Prefix.storedMeta(new_ptr);

    try std.testing.expectEqual(
        Domain.request,
        Meta.domainOf(new_meta),
    );
    try std.testing.expectEqual(
        @as(usize, 7),
        Meta.generationOf(new_meta),
    );
}
