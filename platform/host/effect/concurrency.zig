//! `Concurrency`: how many requests hold a key at once, for limits such as one
//! export at a time for each user. Model cannot change and
//! Roc has no shared mutable value, so this needs the host. Only the counting is
//! here: the keys, the limits, and the answers are Roc's.
//!
//! A request holds what it acquired in its fiber's `Locals`, and the server gives
//! it back when the request ends, however it ends. Roc has no way to release one:
//! a forgotten release, a crash, or a client that went away cannot leave a key
//! held. A request that uses no limiter pays one comparison when it ends.
//!
//! A key is kept as a keyed 128-bit hash, in a table at most half full, and leaves
//! the table when its last holder ends. Each limiter has its own lock, held only
//! for the probes. Every thread of the process shares the limiters; the memory
//! lasts until the process ends.
const std = @import("std");
const sync = @import("../sync.zig");
const abi = @import("../roc_platform_abi.zig");
const allocator_context = @import("../allocator/context.zig");
const fiber = @import("../fiber.zig");
const runtime = @import("../runtime.zig");
const random = @import("random.zig");

pub const maximum_limiters = 64;
pub const maximum_keys: u64 = 1 << 28;
/// How many keys one request may hold at once.
pub const maximum_held = 8;

const Hash128 = std.crypto.auth.siphash.SipHash128(1, 3);

const Slot = extern struct {
    hash: [2]u64,
    /// The requests holding the key. Zero in an empty slot.
    count: u32,
    padding: u32 = 0,
};

pub const Acquire = union(enum) {
    acquired: [2]u64,
    at_limit,
    full,
};

pub const NewError = error{ Invalid, TableFull, Failed };

pub const Limiter = struct {
    lock: sync.Mutex = .{},
    seed: [Hash128.key_length]u8,
    max_keys: u64,
    slots: []Slot,
    /// The keys held now.
    used: u64 = 0,

    pub fn init(max_keys: u64) NewError!Limiter {
        if (max_keys == 0 or max_keys > maximum_keys) return error.Invalid;
        const capacity = std.math.ceilPowerOfTwoAssert(u64, @max(max_keys * 2, 8));
        // The pages are zero from the system, and an empty slot is a zero count;
        // writing them would touch them all. `alloc` would fill them in a debug build.
        const bytes = std.heap.page_allocator.rawAlloc(capacity * @sizeOf(Slot), std.mem.Alignment.of(Slot), @returnAddress()) orelse return error.Failed;
        const slots = @as([*]Slot, @ptrCast(@alignCast(bytes)))[0..capacity];
        var seed: [Hash128.key_length]u8 = undefined;
        random.fill(&seed);
        return .{ .seed = seed, .max_keys = max_keys, .slots = slots };
    }

    pub fn deinit(self: *Limiter) void {
        std.heap.page_allocator.free(self.slots);
    }

    fn hashOf(self: *const Limiter, key: []const u8) [2]u64 {
        var out: [Hash128.mac_length]u8 = undefined;
        Hash128.create(&out, key, &self.seed);
        return .{ std.mem.readInt(u64, out[0..8], std.builtin.Endian.little), std.mem.readInt(u64, out[8..16], std.builtin.Endian.little) };
    }

    fn mask(self: *const Limiter) u64 {
        return self.slots.len - 1;
    }

    /// The slot holding `hash`, or the empty slot where it would go.
    fn probe(self: *const Limiter, hash: [2]u64) u64 {
        var index = hash[0] & self.mask();
        while (self.slots[index].count != 0 and !std.mem.eql(u64, &self.slots[index].hash, &hash)) {
            index = (index + 1) & self.mask();
        }
        return index;
    }

    pub fn acquire(self: *Limiter, key: []const u8, limit: u64) Acquire {
        const hash = self.hashOf(key);
        self.lock.lock();
        defer self.lock.unlock();
        const slot = &self.slots[self.probe(hash)];
        if (slot.count >= limit or slot.count == std.math.maxInt(u32)) return Acquire.at_limit;
        if (slot.count == 0) {
            if (self.used >= self.max_keys) return Acquire.full;
            self.used += 1;
            slot.hash = hash;
        }
        slot.count += 1;
        return Acquire{ .acquired = hash };
    }

    pub fn release(self: *Limiter, hash: [2]u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        var empty = self.probe(hash);
        std.debug.assert(self.slots[empty].count > 0);
        self.slots[empty].count -= 1;
        if (self.slots[empty].count > 0) return;
        self.used -= 1;
        // Move back any key the emptied slot would hide from its probe.
        var next = empty;
        while (true) {
            next = (next + 1) & self.mask();
            if (self.slots[next].count == 0) break;
            const home = self.slots[next].hash[0] & self.mask();
            if (((next -% home) & self.mask()) >= ((next -% empty) & self.mask())) {
                self.slots[empty] = self.slots[next];
                empty = next;
            }
        }
        self.slots[empty].count = 0;
    }
};

/// What a request holds, in its fiber's `Locals`.
pub const Held = struct {
    count: u8 = 0,
    entries: [maximum_held]Entry = undefined,

    const Entry = struct { limiter: *Limiter, hash: [2]u64 };

    pub fn isEmpty(self: *const Held) bool {
        return self.count == 0;
    }
};

/// Gives back what a request held when it stopped or ended.
pub fn releaseHeldBy(target: *fiber.Fiber) void {
    const held = &target.locals.concurrency;
    if (held.isEmpty()) return;
    for (held.entries[0..held.count]) |entry| entry.limiter.release(entry.hash);
    held.count = 0;
}

const Table = struct {
    lock: sync.Mutex = .{},
    limiters: [maximum_limiters]?*Limiter = @splat(null),
    used: usize = 0,

    fn make(self: *Table, max_keys: u64) NewError!u64 {
        var limiter = try Limiter.init(max_keys);
        errdefer limiter.deinit();
        const kept = std.heap.page_allocator.create(Limiter) catch return error.Failed;
        errdefer std.heap.page_allocator.destroy(kept);
        kept.* = limiter;
        self.lock.lock();
        defer self.lock.unlock();
        if (self.used == maximum_limiters) return error.TableFull;
        self.limiters[self.used] = kept;
        self.used += 1;
        return self.used;
    }

    fn get(self: *Table, handle: u64) ?*Limiter {
        if (handle == 0 or handle > maximum_limiters) return null;
        self.lock.lock();
        defer self.lock.unlock();
        return self.limiters[handle - 1];
    }
};

var table: Table = .{};

fn rocHost() abi.RocHost {
    const context = allocator_context.current() orelse @panic("allocator context is not set");
    return runtime.makeRocHost(@ptrCast(context.host_allocator));
}

pub fn hostedConcurrencyNew(max_keys: u64) callconv(std.builtin.CallingConvention.c) abi.HostConcurrencyMade {
    var result: abi.HostConcurrencyMade = undefined;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    const handle = table.make(max_keys) catch |err| {
        result.tag = switch (err) {
            error.Invalid => abi.HostConcurrencyMadeTag.Invalid,
            error.TableFull => abi.HostConcurrencyMadeTag.TableFull,
            error.Failed => abi.HostConcurrencyMadeTag.Failed,
        };
        return result;
    };
    result.tag = abi.HostConcurrencyMadeTag.Made;
    const payload: *u64 = @ptrCast(@alignCast(&result.payload));
    payload.* = handle;
    return result;
}

pub fn hostedConcurrencyAcquire(handle: u64, key: abi.RocStr, limit: u64) callconv(std.builtin.CallingConvention.c) abi.HostConcurrencyAcquired {
    var roc_host = rocHost();
    defer key.decref(&roc_host);
    const limiter = table.get(handle) orelse return abi.HostConcurrencyAcquired.unknown;
    const locals = fiber.currentLocals() orelse return abi.HostConcurrencyAcquired.outside_request;
    const held = &locals.concurrency;
    if (held.count == maximum_held) return abi.HostConcurrencyAcquired.too_many;
    switch (limiter.acquire(key.asSlice(), limit)) {
        Acquire.acquired => |hash| {
            held.entries[held.count] = .{ .limiter = limiter, .hash = hash };
            held.count += 1;
            return abi.HostConcurrencyAcquired.acquired;
        },
        Acquire.at_limit => return abi.HostConcurrencyAcquired.at_limit,
        Acquire.full => return abi.HostConcurrencyAcquired.full,
    }
}

fn testLimiter(max_keys: u64) !Limiter {
    return Limiter.init(max_keys);
}

test "a key holds up to its limit and opens when one ends" {
    var limiter = try testLimiter(10);
    defer limiter.deinit();
    const first = limiter.acquire("a", 2).acquired;
    const second = limiter.acquire("a", 2).acquired;
    try std.testing.expect(limiter.acquire("a", 2) == Acquire.at_limit);
    limiter.release(first);
    try std.testing.expect(limiter.acquire("a", 2) == Acquire.acquired);
    limiter.release(second);
}

test "limits of 0 and 1, and keys held apart" {
    var limiter = try testLimiter(10);
    defer limiter.deinit();
    try std.testing.expect(limiter.acquire("a", 0) == Acquire.at_limit);
    try std.testing.expectEqual(@as(u64, 0), limiter.used);
    _ = limiter.acquire("a", 1);
    try std.testing.expect(limiter.acquire("a", 1) == Acquire.at_limit);
    try std.testing.expect(limiter.acquire("b", 1) == Acquire.acquired);
}

test "a full limiter refuses a new key, goes on with its keys, and opens when a key ends" {
    var limiter = try testLimiter(2);
    defer limiter.deinit();
    const a = limiter.acquire("a", 5).acquired;
    _ = limiter.acquire("b", 5);
    try std.testing.expect(limiter.acquire("c", 5) == Acquire.full);
    const again = limiter.acquire("a", 5).acquired;
    limiter.release(a);
    try std.testing.expect(limiter.acquire("c", 5) == Acquire.full);
    limiter.release(again);
    try std.testing.expect(limiter.acquire("c", 5) == Acquire.acquired);
}

test "settings out of range are refused" {
    try std.testing.expectError(error.Invalid, Limiter.init(0));
    try std.testing.expectError(error.Invalid, Limiter.init(maximum_keys + 1));
}

test "keys stay reachable as others leave, across colliding probes" {
    var limiter = try testLimiter(4);
    defer limiter.deinit();
    // Hashes chosen by hand so that they share and wrap around a table's probes.
    const end = limiter.slots.len - 1;
    const hashes = [_][2]u64{ .{ end, 1 }, .{ end, 2 }, .{ end, 3 }, .{ 0, 4 } };
    for (hashes) |hash| {
        const slot = &limiter.slots[limiter.probe(hash)];
        slot.hash = hash;
        slot.count = 1;
        limiter.used += 1;
    }
    for (hashes, 0..) |hash, index| {
        limiter.release(hash);
        for (hashes[index + 1..]) |remaining| {
            try std.testing.expectEqual(@as(u32, 1), limiter.slots[limiter.probe(remaining)].count);
        }
    }
    try std.testing.expectEqual(@as(u64, 0), limiter.used);
    for (limiter.slots) |slot| try std.testing.expectEqual(@as(u32, 0), slot.count);
}

test "many keys come and go: the table stays bounded and right" {
    var limiter = try testLimiter(100);
    defer limiter.deinit();
    var name: [16]u8 = undefined;
    var held: [100][2]u64 = undefined;
    var round: u64 = 0;
    while (round < 200) : (round += 1) {
        for (&held, 0..) |*hash, index| {
            const text = try std.fmt.bufPrint(&name, "{d}", .{round * 7 + index});
            hash.* = limiter.acquire(text, 1).acquired;
        }
        try std.testing.expect(limiter.acquire("one too many", 1) == Acquire.full);
        for (held) |hash| limiter.release(hash);
        try std.testing.expectEqual(@as(u64, 0), limiter.used);
    }
}

test "threads never go past the limit, and lose nothing" {
    var limiter = try testLimiter(10);
    defer limiter.deinit();
    const Worker = struct {
        fn run(shared: *Limiter, inside: *std.atomic.Value(u32), over: *std.atomic.Value(bool)) void {
            for (0..10_000) |_| {
                switch (shared.acquire("a", 3)) {
                    Acquire.acquired => |hash| {
                        if (inside.fetchAdd(1, std.builtin.AtomicOrder.acq_rel) >= 3) over.store(true, std.builtin.AtomicOrder.release);
                        _ = inside.fetchSub(1, std.builtin.AtomicOrder.acq_rel);
                        shared.release(hash);
                    },
                    Acquire.at_limit, Acquire.full => {},
                }
            }
        }
    };
    var inside = std.atomic.Value(u32).init(0);
    var over = std.atomic.Value(bool).init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &limiter, &inside, &over });
    for (threads) |thread| thread.join();
    try std.testing.expect(!over.load(std.builtin.AtomicOrder.acquire));
    try std.testing.expectEqual(@as(u64, 0), limiter.used);
}
