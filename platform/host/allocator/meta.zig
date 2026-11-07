const std = @import("std");
const Domain = @import("domain.zig").Domain;

pub const Meta = struct {
    const domain_mask: usize = 1;
    pub const max_generation: usize = std.math.maxInt(usize) >> 1;

    pub fn pack(domain: Domain, generation: usize) usize {
        std.debug.assert(generation <= max_generation);
        return (generation << 1) | @intFromEnum(domain);
    }

    pub fn domainOf(meta: usize) Domain {
        return @enumFromInt(meta & domain_mask);
    }

    pub fn generationOf(meta: usize) usize {
        return meta >> 1;
    }
};

test "Meta packs domain and generation" {
    try std.testing.expectEqual(
        @as(usize, 0),
        Meta.pack(Domain.persistent, 0),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        Meta.pack(Domain.request, 0),
    );
    try std.testing.expectEqual(
        @as(usize, 10),
        Meta.pack(Domain.persistent, 5),
    );
    try std.testing.expectEqual(
        @as(usize, 11),
        Meta.pack(Domain.request, 5),
    );
}

test "Meta unpacks domain and generation" {
    const request_meta = Meta.pack(Domain.request, 5);

    try std.testing.expectEqual(
        Domain.request,
        Meta.domainOf(request_meta),
    );
    try std.testing.expectEqual(
        @as(usize, 5),
        Meta.generationOf(request_meta),
    );

    const persistent_meta = Meta.pack(Domain.persistent, 5);

    try std.testing.expectEqual(
        Domain.persistent,
        Meta.domainOf(persistent_meta),
    );
    try std.testing.expectEqual(
        @as(usize, 5),
        Meta.generationOf(persistent_meta),
    );
}

test "Meta round trips maximum generation" {
    const meta = Meta.pack(
        Domain.request,
        Meta.max_generation,
    );

    try std.testing.expectEqual(
        std.math.maxInt(usize),
        meta,
    );
    try std.testing.expectEqual(
        Domain.request,
        Meta.domainOf(meta),
    );
    try std.testing.expectEqual(
        Meta.max_generation,
        Meta.generationOf(meta),
    );
}
