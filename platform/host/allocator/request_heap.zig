//! Reclaims dead values immediately, with bounded reuse and request-wide cleanup.
//!
//! A cached heap packs small values into slabs: pages split into slots of
//! one size class. Larger values each get a block of their own, rounded up
//! to whole pages, so a page per small value would make a handler that
//! builds thousands of short strings hold thousands of pages.
const std = @import("std");
const request_memory = @import("request_memory.zig");

pub const RequestHeap = struct {
    backing: std.mem.Allocator,
    first: ?*Node = null,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    cache_enabled: bool = false,
    cached_bytes: usize = 0,
    cached: [17]?*Node = @splat(null),
    /// For a heap split off with `detachLive`: the heap whose cache this one
    /// uses, the shared heap of the Roc thread running it now. When its
    /// request goes on on another thread, `useCacheOf` moves it to that
    /// thread's cache, so each cache is still touched by one thread only.
    cache_owner: ?*RequestHeap = null,
    /// Every slab holding a live value. A slab whose last value is freed goes
    /// back to the page cache at once.
    slabs: ?*Slab = null,
    /// Per size class, the slabs with a free slot.
    open_slabs: [slot_classes]?*Slab = @splat(null),
    /// A cached heap's part of the worker's live bytes; a heap with a cache
    /// owner counts in the owner's, which is touched by its thread only.
    share: ?*request_memory.Share = null,

    /// Bounds retained storage per Roc thread, including page rounding.
    pub const cache_limit: usize = 1024 * 1024;
    pub const largest_cached_block: usize = 64 * 1024;

    /// Values up to this size, with alignment up to `slot_alignment`, go in
    /// slabs: size classes 16, 32, ..., 1024 bytes.
    pub const largest_slot: usize = 1024;
    const smallest_slot: usize = 16;
    const slot_alignment: usize = 16;
    const slot_classes = std.math.log2_int(usize, largest_slot) - std.math.log2_int(usize, smallest_slot) + 1;

    /// The header at the start of a slab page; slots follow it.
    const Slab = struct {
        previous: ?*Slab,
        next: ?*Slab,
        previous_open: ?*Slab = null,
        next_open: ?*Slab = null,
        open: bool = false,
        class: u8,
        live: usize = 0,
        /// The offset of the first slot never handed out.
        unused: usize,
        free: ?*FreeSlot = null,
    };

    const FreeSlot = struct {
        next: ?*FreeSlot,
    };

    const Node = struct {
        previous: ?*Node,
        next: ?*Node,
        length: usize,
        capacity: usize,
        alignment: std.mem.Alignment,
    };

    pub fn init(backing: std.mem.Allocator) RequestHeap {
        return .{ .backing = backing };
    }

    /// Confined to one Roc thread. The backing allocator must support page alignment.
    pub fn initCached(backing: std.mem.Allocator) RequestHeap {
        return .{ .backing = backing, .cache_enabled = true, .share = request_memory.takeShare() };
    }

    pub fn allocator(self: *RequestHeap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocate,
            .resize = resize,
            .remap = std.mem.Allocator.noRemap,
            .free = release,
        } };
    }

    /// Moves the live blocks to a new heap that shares this heap's cache, and
    /// leaves this heap empty for the next request. A streaming response that
    /// outlives its request keeps its values in the new heap.
    /// Every slab holds a live value, so all of them move.
    pub fn detachLive(self: *RequestHeap) RequestHeap {
        const detached = RequestHeap{
            .backing = self.backing,
            .first = self.first,
            .live_bytes = self.live_bytes,
            .peak_bytes = self.live_bytes,
            .cache_owner = self.cacheHeap(),
            .slabs = self.slabs,
            .open_slabs = self.open_slabs,
        };
        self.first = null;
        self.slabs = null;
        self.open_slabs = @splat(null);
        self.live_bytes = 0;
        self.peak_bytes = 0;
        return detached;
    }

    /// Live bytes change here only, so the worker's total
    /// (`request_memory`) follows every heap.
    fn addLive(self: *RequestHeap, bytes: usize) void {
        self.live_bytes += bytes;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        if (self.cacheHeap().share) |share| share.grow(bytes) else request_memory.grow(bytes);
    }

    fn subLive(self: *RequestHeap, bytes: usize) void {
        self.live_bytes -= bytes;
        if (self.cacheHeap().share) |share| share.shrink(bytes) else request_memory.shrink(bytes);
    }

    /// Points a detached heap at `owner`'s cache: its pages come from and go
    /// back to the cache of the thread now running its request. A cached
    /// page is a whole page, so any thread's cache can take it.
    pub fn useCacheOf(self: *RequestHeap, owner: *RequestHeap) void {
        std.debug.assert(self.cache_owner != null);
        self.cache_owner = owner.cacheHeap();
    }

    fn cacheHeap(self: *RequestHeap) *RequestHeap {
        return self.cache_owner orelse self;
    }

    pub fn reset(self: *RequestHeap) void {
        while (self.first) |node| self.remove(node);
        while (self.slabs) |slab| {
            self.subLive(slab.live * slotSize(slab.class));
            self.unlinkSlab(slab);
            self.givePage(@ptrCast(slab));
        }
        self.peak_bytes = 0;
    }

    pub fn deinit(self: *RequestHeap) void {
        self.reset();
        // A detached heap's cache belongs to its owner.
        if (self.cache_owner != null) return;
        if (self.share) |share| request_memory.giveShare(share);
        self.share = null;
        for (&self.cached) |*head| {
            while (head.*) |node| {
                head.* = node.next;
                self.backing.rawFree(@as([*]u8, @ptrCast(node))[0..node.capacity], node.alignment, @returnAddress());
            }
        }
        self.cached_bytes = 0;
    }

    fn offset(alignment: std.mem.Alignment) usize {
        return std.mem.alignForward(usize, @sizeOf(Node), alignment.toByteUnits());
    }

    fn allocate(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *RequestHeap = @ptrCast(@alignCast(context));
        if (self.slotClass(length, alignment)) |class| return self.allocateSlot(class);
        const store = self.cacheHeap();
        const actual_alignment = alignment.max(std.mem.Alignment.of(Node));
        const total = std.math.add(usize, offset(actual_alignment), length) catch return null;
        const capacity = if (store.cache_enabled) cacheCapacity(total, actual_alignment) else null;
        const backing_alignment = if (capacity != null) std.mem.Alignment.fromByteUnits(std.heap.pageSize()) else actual_alignment;
        const bytes = blk: {
            if (capacity) |size| {
                const head = &store.cached[std.math.log2_int(usize, size)];
                if (head.*) |node| {
                    head.* = node.next;
                    store.cached_bytes -= size;
                    break :blk @as([*]u8, @ptrCast(node));
                }
            }
            break :blk self.backing.rawAlloc(capacity orelse total, backing_alignment, ra) orelse return null;
        };
        const node: *Node = @ptrCast(@alignCast(bytes));
        node.* = .{ .previous = null, .next = self.first, .length = total, .capacity = capacity orelse total, .alignment = backing_alignment };
        if (self.first) |first| first.previous = node;
        self.first = node;
        self.addLive(total);
        return bytes + offset(actual_alignment);
    }

    /// Grows or shrinks a block in place when the new size fits the block's
    /// capacity. Cached blocks are rounded up to a power of two, so most
    /// small growths succeed without a copy.
    /// A slot keeps its size class: a free decides by length whether the value
    /// is in a slab, so a resize that would move it across that line fails.
    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, new_length: usize, _: usize) bool {
        const self: *RequestHeap = @ptrCast(@alignCast(context));
        const class = self.slotClass(bytes.len, alignment);
        if (class != self.slotClass(new_length, alignment)) return false;
        if (class != null) return true;
        const actual_alignment = alignment.max(std.mem.Alignment.of(Node));
        const node: *Node = @ptrCast(@alignCast(bytes.ptr - offset(actual_alignment)));
        const total = std.math.add(usize, offset(actual_alignment), new_length) catch return false;
        if (total > node.capacity) return false;
        self.subLive(node.length);
        self.addLive(total);
        node.length = total;
        return true;
    }

    fn release(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, _: usize) void {
        const self: *RequestHeap = @ptrCast(@alignCast(context));
        if (self.slotClass(bytes.len, alignment)) |class| return self.releaseSlot(bytes.ptr, class);
        const actual_alignment = alignment.max(std.mem.Alignment.of(Node));
        const node: *Node = @ptrCast(@alignCast(bytes.ptr - offset(actual_alignment)));
        self.remove(node);
    }

    fn remove(self: *RequestHeap, node: *Node) void {
        if (node.previous) |previous| previous.next = node.next else self.first = node.next;
        if (node.next) |next| next.previous = node.previous;
        self.subLive(node.length);
        // Decide by capacity, not length: after an in-place shrink the length
        // no longer tells which size class the block came from. Only blocks
        // whose capacity is exactly a class size go back to the cache.
        const store = self.cacheHeap();
        if (store.cache_enabled and cacheCapacity(node.capacity, node.alignment) == node.capacity and
            node.capacity <= cache_limit - store.cached_bytes)
        {
            const head = &store.cached[std.math.log2_int(usize, node.capacity)];
            node.next = head.*;
            head.* = node;
            store.cached_bytes += node.capacity;
            return;
        }
        self.backing.rawFree(@as([*]u8, @ptrCast(node))[0..node.capacity], node.alignment, @returnAddress());
    }

    /// The size class for a value that goes in a slab, or null for a block.
    fn slotClass(self: *RequestHeap, length: usize, alignment: std.mem.Alignment) ?u8 {
        if (!self.cacheHeap().cache_enabled) return null;
        if (length > largest_slot or alignment.toByteUnits() > slot_alignment) return null;
        const size = std.math.ceilPowerOfTwoAssert(usize, @max(length, smallest_slot));
        return @intCast(std.math.log2_int(usize, size) - std.math.log2_int(usize, smallest_slot));
    }

    fn slotSize(class: u8) usize {
        return smallest_slot << @intCast(class);
    }

    fn firstSlot() usize {
        return std.mem.alignForward(usize, @sizeOf(Slab), slot_alignment);
    }

    fn allocateSlot(self: *RequestHeap, class: u8) ?[*]u8 {
        const size = slotSize(class);
        const slab = self.open_slabs[class] orelse self.newSlab(class) orelse return null;
        const page: [*]u8 = @ptrCast(slab);
        const slot: [*]u8 = if (slab.free) |free| blk: {
            slab.free = free.next;
            break :blk @ptrCast(free);
        } else blk: {
            const at = slab.unused;
            slab.unused += size;
            break :blk page + at;
        };
        slab.live += 1;
        if (slab.free == null and slab.unused + size > std.heap.pageSize()) self.closeSlab(slab);
        self.addLive(size);
        return slot;
    }

    fn releaseSlot(self: *RequestHeap, slot: [*]u8, class: u8) void {
        const slab: *Slab = @ptrFromInt(std.mem.alignBackward(usize, @intFromPtr(slot), std.heap.pageSize()));
        std.debug.assert(slab.class == class);
        const free: *FreeSlot = @ptrCast(@alignCast(slot));
        free.next = slab.free;
        slab.free = free;
        slab.live -= 1;
        self.subLive(slotSize(class));
        if (slab.live == 0) {
            self.unlinkSlab(slab);
            self.givePage(@ptrCast(slab));
        } else if (!slab.open) {
            self.openSlab(slab);
        }
    }

    fn newSlab(self: *RequestHeap, class: u8) ?*Slab {
        const page = self.takePage() orelse return null;
        const slab: *Slab = @ptrCast(@alignCast(page));
        slab.* = .{ .previous = null, .next = self.slabs, .class = class, .unused = firstSlot() };
        if (self.slabs) |first| first.previous = slab;
        self.slabs = slab;
        self.openSlab(slab);
        return slab;
    }

    fn openSlab(self: *RequestHeap, slab: *Slab) void {
        const head = &self.open_slabs[slab.class];
        slab.previous_open = null;
        slab.next_open = head.*;
        if (head.*) |first| first.previous_open = slab;
        head.* = slab;
        slab.open = true;
    }

    fn closeSlab(self: *RequestHeap, slab: *Slab) void {
        if (slab.previous_open) |previous| previous.next_open = slab.next_open else self.open_slabs[slab.class] = slab.next_open;
        if (slab.next_open) |next| next.previous_open = slab.previous_open;
        slab.open = false;
    }

    fn unlinkSlab(self: *RequestHeap, slab: *Slab) void {
        if (slab.open) self.closeSlab(slab);
        if (slab.previous) |previous| previous.next = slab.next else self.slabs = slab.next;
        if (slab.next) |next| next.previous = slab.previous;
    }

    /// A page for a slab, from the cache when it has one.
    fn takePage(self: *RequestHeap) ?[*]u8 {
        const store = self.cacheHeap();
        const page = std.heap.pageSize();
        const head = &store.cached[std.math.log2_int(usize, page)];
        if (head.*) |node| {
            head.* = node.next;
            store.cached_bytes -= page;
            return @ptrCast(node);
        }
        return self.backing.rawAlloc(page, std.mem.Alignment.fromByteUnits(page), @returnAddress());
    }

    fn givePage(self: *RequestHeap, bytes: [*]u8) void {
        const store = self.cacheHeap();
        const page = std.heap.pageSize();
        const alignment = std.mem.Alignment.fromByteUnits(page);
        if (page <= cache_limit - store.cached_bytes) {
            const node: *Node = @ptrCast(@alignCast(bytes));
            const head = &store.cached[std.math.log2_int(usize, page)];
            node.* = .{ .previous = null, .next = head.*, .length = 0, .capacity = page, .alignment = alignment };
            head.* = node;
            store.cached_bytes += page;
            return;
        }
        self.backing.rawFree(bytes[0..page], alignment, @returnAddress());
    }

    fn cacheCapacity(total: usize, alignment: std.mem.Alignment) ?usize {
        const page_size = std.heap.pageSize();
        if (total > largest_cached_block or page_size > largest_cached_block or alignment.toByteUnits() > page_size) return null;
        return std.math.ceilPowerOfTwo(usize, @max(total, page_size)) catch null;
    }
};

test "cache capacity covers page and upper size boundaries" {
    const alignment = std.mem.Alignment.of(usize);
    const page = std.heap.pageSize();
    for ([_]usize{ page - 1, page, page + 1 }) |size| {
        const expected: ?usize = if (size > RequestHeap.largest_cached_block) null else if (size > page) page * 2 else page;
        try std.testing.expectEqual(expected, RequestHeap.cacheCapacity(size, alignment));
    }
    const limit = RequestHeap.largest_cached_block;
    try std.testing.expectEqual(@as(?usize, limit), RequestHeap.cacheCapacity(limit - 1, alignment));
    try std.testing.expectEqual(@as(?usize, limit), RequestHeap.cacheCapacity(limit, alignment));
    try std.testing.expectEqual(@as(?usize, null), RequestHeap.cacheCapacity(limit + 1, alignment));
    // Alignment inputs are powers of two: nearest valid values around a page.
    for ([_]usize{ page / 2, page, page * 2 }) |bytes| {
        const expected: ?usize = if (bytes <= page) page else null;
        try std.testing.expectEqual(expected, RequestHeap.cacheCapacity(1, std.mem.Alignment.fromByteUnits(bytes)));
    }
}

test "cached heap reuses freed blocks and caps retained storage" {
    // A page is the smallest valid capacity increment. Also exercise the
    // largest eligible class, whose cached blocks have the same budget.
    for ([_]usize{ std.heap.pageSize(), RequestHeap.largest_cached_block }) |capacity| {
        var heap = RequestHeap.initCached(std.testing.allocator);
        defer heap.deinit();
        const allocator = heap.allocator();
        const alignment = std.mem.Alignment.of(usize);
        const length = capacity - RequestHeap.offset(alignment);
        const count = RequestHeap.cache_limit / capacity;
        const blocks = try std.testing.allocator.alloc([*]u8, count + 1);
        defer std.testing.allocator.free(blocks);
        for (blocks) |*block| block.* = allocator.rawAlloc(length, alignment, @returnAddress()) orelse return error.OutOfMemory;
        // Budget - one page, budget, and budget + one page are the nearest
        // valid boundaries in the first case. Excess blocks go to backing.
        for (blocks, 0..) |block, index| {
            allocator.rawFree(block[0..length], alignment, @returnAddress());
            try std.testing.expectEqual(@min(index + 1, count) * capacity, heap.cached_bytes);
        }
        const reused = allocator.rawAlloc(length, alignment, @returnAddress()) orelse return error.OutOfMemory;
        try std.testing.expectEqual(@intFromPtr(blocks[count - 1]), @intFromPtr(reused));
        // Emergency reset also returns a still-live allocation to the bounded cache.
        heap.reset();
        try std.testing.expectEqual(@as(usize, 0), heap.live_bytes);
        try std.testing.expectEqual(RequestHeap.cache_limit, heap.cached_bytes);
    }
}

test "cached heap preserves live values on allocation failure and reuses without backing allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var heap = RequestHeap.initCached(failing.allocator());
    defer heap.deinit();
    const allocator = heap.allocator();
    const alignment = std.mem.Alignment.of(usize);
    // Past the largest slot, so each value takes a block from the backing.
    const length = RequestHeap.largest_slot + 1;
    const first = allocator.rawAlloc(length, alignment, @returnAddress()) orelse return error.OutOfMemory;
    first[0] = 42;
    const live = heap.live_bytes;
    // First backing allocation succeeds; the next must fail without changing ownership.
    try std.testing.expectEqual(@as(?[*]u8, null), allocator.rawAlloc(length, alignment, @returnAddress()));
    try std.testing.expectEqual(live, heap.live_bytes);
    try std.testing.expectEqual(@as(u8, 42), first[0]);
    allocator.rawFree(first[0..length], alignment, @returnAddress());
    const reused = allocator.rawAlloc(length, alignment, @returnAddress()) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@intFromPtr(first), @intFromPtr(reused));
    heap.reset();
    try std.testing.expectEqual(@as(usize, 0), heap.live_bytes);
}

test "a block resizes in place up to its capacity and no further" {
    var heap = RequestHeap.initCached(std.heap.page_allocator);
    defer heap.deinit();
    const allocator = heap.allocator();
    const page = std.heap.pageSize();
    const header = RequestHeap.offset(std.mem.Alignment.of(RequestHeap.Node));

    const smallest_block = RequestHeap.largest_slot + 1;
    const bytes = try allocator.alloc(u8, smallest_block);
    // The block holds one page; the largest in-place size fills it exactly.
    const largest = page - header;
    try std.testing.expect(allocator.resize(bytes, largest - 1));
    try std.testing.expect(allocator.resize(bytes, largest));
    try std.testing.expect(!allocator.resize(bytes, largest + 1));
    try std.testing.expectEqual(page, heap.live_bytes);
    // A block cannot shrink into slot sizes, which a free would look for in a slab.
    try std.testing.expect(!allocator.resize(bytes, RequestHeap.largest_slot));
    try std.testing.expect(allocator.resize(bytes, smallest_block));
    try std.testing.expectEqual(header + smallest_block, heap.live_bytes);
    allocator.free(@as([]u8, bytes.ptr[0..smallest_block]));
    try std.testing.expectEqual(@as(usize, 0), heap.live_bytes);
    // The shrunk block returns to the cache for its original class.
    try std.testing.expectEqual(page, heap.cached_bytes);
}

test "a shrunk uncached block is freed, not cached under a smaller class" {
    var heap = RequestHeap.initCached(std.heap.page_allocator);
    defer heap.deinit();
    const allocator = heap.allocator();
    const bytes = try allocator.alloc(u8, RequestHeap.largest_cached_block + 1);
    const small_block = RequestHeap.largest_slot + 1;
    try std.testing.expect(allocator.resize(bytes, small_block));
    allocator.free(@as([]u8, bytes.ptr[0..small_block]));
    try std.testing.expectEqual(@as(usize, 0), heap.cached_bytes);
}

test "a detached heap keeps its blocks and returns them to the shared cache" {
    var heap = RequestHeap.initCached(std.heap.page_allocator);
    defer heap.deinit();
    const page = std.heap.pageSize();

    const length = RequestHeap.largest_slot + 1;
    const kept = try heap.allocator().alloc(u8, length);
    var detached = heap.detachLive();
    try std.testing.expectEqual(@as(usize, 0), heap.live_bytes);
    try std.testing.expect(detached.live_bytes > 0);

    // The request heap serves the next request while the detached block lives.
    const next = try heap.allocator().alloc(u8, length);
    heap.allocator().free(next);
    try std.testing.expectEqual(page, heap.cached_bytes);

    // The detached heap allocates from and frees into the shared cache.
    const step = try detached.allocator().alloc(u8, length);
    try std.testing.expectEqual(@as(usize, 0), heap.cached_bytes);
    detached.allocator().free(step);
    detached.allocator().free(kept);
    try std.testing.expectEqual(@as(usize, 0), detached.live_bytes);
    try std.testing.expectEqual(2 * page, heap.cached_bytes);
    detached.deinit();
}

test "a detached heap moved to another thread uses that thread's cache" {
    var first = RequestHeap.initCached(std.heap.page_allocator);
    defer first.deinit();
    var second = RequestHeap.initCached(std.heap.page_allocator);
    defer second.deinit();
    const page = std.heap.pageSize();

    const length = RequestHeap.largest_slot + 1;
    const kept = try first.allocator().alloc(u8, length);
    const small = try first.allocator().alloc(u8, 16);
    var detached = first.detachLive();
    detached.useCacheOf(&second);

    // Blocks and slab pages made on the first thread go back to the second.
    detached.allocator().free(kept);
    detached.allocator().free(small);
    try std.testing.expectEqual(@as(usize, 0), first.cached_bytes);
    try std.testing.expectEqual(2 * page, second.cached_bytes);
    const step = try detached.allocator().alloc(u8, length);
    try std.testing.expectEqual(page, second.cached_bytes);
    detached.allocator().free(step);
    detached.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.cached_bytes);
    try std.testing.expectEqual(2 * page, second.cached_bytes);
}

test "slot classes cover the smallest and largest slot and the alignment limit" {
    var heap = RequestHeap.initCached(std.heap.page_allocator);
    defer heap.deinit();
    const alignment = std.mem.Alignment.of(usize);
    const Case = struct { length: usize, class: ?u8 };
    for ([_]Case{
        .{ .length = 1, .class = 0 },
        .{ .length = 15, .class = 0 },
        .{ .length = 16, .class = 0 },
        .{ .length = 17, .class = 1 },
        .{ .length = RequestHeap.largest_slot - 1, .class = RequestHeap.slot_classes - 1 },
        .{ .length = RequestHeap.largest_slot, .class = RequestHeap.slot_classes - 1 },
        .{ .length = RequestHeap.largest_slot + 1, .class = null },
    }) |case| try std.testing.expectEqual(case.class, heap.slotClass(case.length, alignment));
    // Alignments are powers of two: below, at, and above the slot alignment.
    for ([_]usize{ 8, 16, 32 }) |bytes| {
        const expected: ?u8 = if (bytes <= RequestHeap.slot_alignment) 0 else null;
        try std.testing.expectEqual(expected, heap.slotClass(1, std.mem.Alignment.fromByteUnits(bytes)));
    }
    // An uncached heap gives every value a block of its own.
    var plain = RequestHeap.init(std.testing.allocator);
    defer plain.deinit();
    try std.testing.expectEqual(@as(?u8, null), plain.slotClass(1, alignment));
}

test "small values share a slab page until it is full" {
    var heap = RequestHeap.initCached(std.heap.page_allocator);
    defer heap.deinit();
    const allocator = heap.allocator();
    const page = std.heap.pageSize();
    for ([_]usize{ 16, RequestHeap.largest_slot }) |size| {
        const per_slab = (page - RequestHeap.firstSlot()) / size;
        const values = try std.testing.allocator.alloc([]u8, per_slab + 1);
        defer std.testing.allocator.free(values);
        for (values) |*value| value.* = try allocator.alloc(u8, size);
        // The last slot of the first page, and the first of the next.
        const first_page = std.mem.alignBackward(usize, @intFromPtr(values[0].ptr), page);
        try std.testing.expectEqual(first_page, std.mem.alignBackward(usize, @intFromPtr(values[per_slab - 1].ptr), page));
        try std.testing.expect(first_page != std.mem.alignBackward(usize, @intFromPtr(values[per_slab].ptr), page));
        try std.testing.expectEqual((per_slab + 1) * size, heap.live_bytes);
        for (values) |value| @memset(value, 0xA5);
        for (values) |value| allocator.free(value);
        try std.testing.expectEqual(@as(usize, 0), heap.live_bytes);
        try std.testing.expectEqual(@as(?*RequestHeap.Slab, null), heap.slabs);
    }
    // Both pages went back to the cache.
    try std.testing.expectEqual(2 * page, heap.cached_bytes);
}

test "a freed slot is reused and a slot resizes only within its class" {
    var heap = RequestHeap.initCached(std.heap.page_allocator);
    defer heap.deinit();
    const allocator = heap.allocator();
    const keep = try allocator.alloc(u8, 24);
    const freed = try allocator.alloc(u8, 24);
    allocator.free(freed);
    const reused = try allocator.alloc(u8, 32);
    try std.testing.expectEqual(@intFromPtr(freed.ptr), @intFromPtr(reused.ptr));
    // 32 is the class's size; 17 its smallest member; 33 and 16 are outside.
    try std.testing.expect(allocator.resize(reused, 17));
    try std.testing.expect(!allocator.resize(@as([]u8, reused.ptr[0..17]), 16));
    try std.testing.expect(!allocator.resize(@as([]u8, reused.ptr[0..17]), 33));
    allocator.free(@as([]u8, reused.ptr[0..17]));
    allocator.free(keep);
    try std.testing.expectEqual(@as(usize, 0), heap.live_bytes);
}

test "reset and detach hand over slabs" {
    var heap = RequestHeap.initCached(std.heap.page_allocator);
    defer heap.deinit();
    const page = std.heap.pageSize();

    _ = try heap.allocator().alloc(u8, 16);
    heap.reset();
    try std.testing.expectEqual(@as(usize, 0), heap.live_bytes);
    try std.testing.expectEqual(page, heap.cached_bytes);

    // A stream keeps its slab; the request heap starts the next request with none.
    const kept = try heap.allocator().alloc(u8, 16);
    var detached = heap.detachLive();
    try std.testing.expectEqual(@as(?*RequestHeap.Slab, null), heap.slabs);
    try std.testing.expectEqual(@as(usize, 16), detached.live_bytes);
    const next = try heap.allocator().alloc(u8, 16);
    try std.testing.expect(std.mem.alignBackward(usize, @intFromPtr(next.ptr), page) !=
        std.mem.alignBackward(usize, @intFromPtr(kept.ptr), page));
    heap.allocator().free(next);
    // The detached heap fills its own slab and frees into the shared cache.
    const step = try detached.allocator().alloc(u8, 16);
    try std.testing.expectEqual(std.mem.alignBackward(usize, @intFromPtr(kept.ptr), page), std.mem.alignBackward(usize, @intFromPtr(step.ptr), page));
    detached.allocator().free(step);
    detached.allocator().free(kept);
    try std.testing.expectEqual(@as(usize, 0), detached.live_bytes);
    try std.testing.expectEqual(2 * page, heap.cached_bytes);
    detached.deinit();
}
