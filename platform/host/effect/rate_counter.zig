//! `RateCounter`: counts per key in this window of time and the one before it,
//! for rate limits. Only the counting is here: the limits, the
//! keys, and the answers are Roc's.
//!
//! Each counter holds two tables, one per window. A table's slots carry the
//! window they were written in, so moving to the next window changes a number and
//! clears nothing. A table is at most half full, which bounds a probe. A key is
//! kept as a keyed 128-bit hash, so a client can choose neither the slots its keys
//! fall in nor the memory they take.
//!
//! Every thread of the process shares the counters; each has its own lock, held
//! only for the probes. The memory lasts until the process ends.
const std = @import("std");
const sync = @import("../sync.zig");
const abi = @import("../roc_platform_abi.zig");
const allocator_context = @import("../allocator/context.zig");
const runtime = @import("../runtime.zig");
const instant = @import("instant.zig");
const random = @import("random.zig");
const diagnostics = @import("../diagnostics.zig");

pub const maximum_counters = 64;
pub const maximum_keys: u64 = 1 << 28;
pub const maximum_window_seconds: u64 = 365 * 24 * 60 * 60;

const nanoseconds_per_second: u64 = 1_000_000_000;
const nanoseconds_per_millisecond: u64 = 1_000_000;

const Hash128 = std.crypto.auth.siphash.SipHash128(1, 3);

const Slot = extern struct {
    hash: [2]u64,
    /// The window this slot was written in. Zero in a slot never written.
    stamp: u32,
    count: u32,
};

pub const Counts = struct { current: u64, previous: u64, elapsed_ms: u64 };

pub const NewError = error{ Invalid, TableFull, Failed };

pub const Counter = struct {
    lock: sync.Mutex = .{},
    seed: [Hash128.key_length]u8,
    window_ns: u64,
    max_keys: u64,
    start_ns: u64,
    /// The slots of both tables: `capacity` each.
    slots: []Slot,
    capacity: u64,
    /// Which table is this window's.
    active: u1 = 0,
    /// The stamp of each table's window. Zero for a table with nothing in it.
    stamps: [2]u32 = .{ 1, 0 },
    /// The window since `start_ns`.
    window: u64 = 0,
    /// The keys in this window's table.
    used: u64 = 0,

    pub fn init(window_seconds: u64, max_keys: u64, start_ns: u64) NewError!Counter {
        if (window_seconds == 0 or window_seconds > maximum_window_seconds) return error.Invalid;
        if (max_keys == 0 or max_keys > maximum_keys) return error.Invalid;
        const capacity = std.math.ceilPowerOfTwoAssert(u64, @max(max_keys * 2, 8));
        const slots = std.heap.page_allocator.alloc(Slot, capacity * 2) catch return error.Failed;
        // The pages are zero from the system; writing them would touch them all.
        var seed: [Hash128.key_length]u8 = undefined;
        random.fill(&seed);
        return .{
            .seed = seed,
            .window_ns = window_seconds * nanoseconds_per_second,
            .max_keys = max_keys,
            .start_ns = start_ns,
            .slots = slots,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *Counter) void {
        std.heap.page_allocator.free(self.slots);
    }

    /// Adds `amount` to `key` at the time `now_ns`. An `amount` of zero records
    /// nothing. Null when the key is new and the window has every key it may hold.
    pub fn add(self: *Counter, key: []const u8, amount: u64, now_ns: u64) ?Counts {
        var bytes: [Hash128.mac_length]u8 = undefined;
        Hash128.create(&bytes, key, &self.seed);
        const hash: [2]u64 = @bitCast(bytes);
        // A clock behind the start counts as the start.
        const since = now_ns -| self.start_ns;

        self.lock.lock();
        defer self.lock.unlock();
        self.moveTo(since / self.window_ns);
        const previous = self.find(self.active ^ 1, hash);
        const current = if (amount == 0) self.find(self.active, hash) else self.count(hash, amount) orelse return null;
        return .{
            .current = current,
            .previous = previous,
            .elapsed_ms = (since % self.window_ns) / nanoseconds_per_millisecond,
        };
    }

    fn moveTo(self: *Counter, window: u64) void {
        if (window <= self.window) return;
        const stamp = self.stamps[self.active];
        if (window == self.window + 1) {
            self.active ^= 1;
        } else {
            self.stamps[self.active ^ 1] = 0;
        }
        // Odd, so never the zero of an empty table. Wraps after 2 billion windows,
        // past the life of a process: a window is at least a second.
        self.stamps[self.active] = stamp +% 2 | 1;
        self.window = window;
        self.used = 0;
    }

    fn table(self: *Counter, index: u1) []Slot {
        const start = self.capacity * index;
        return self.slots[start .. start + self.capacity];
    }

    fn find(self: *Counter, index: u1, hash: [2]u64) u64 {
        const stamp = self.stamps[index];
        if (stamp == 0) return 0;
        const slots = self.table(index);
        var at = hash[0] & (self.capacity - 1);
        while (true) : (at = (at + 1) & (self.capacity - 1)) {
            const slot = &slots[at];
            if (slot.stamp != stamp) return 0;
            if (std.mem.eql(u64, &slot.hash, &hash)) return slot.count;
        }
    }

    fn count(self: *Counter, hash: [2]u64, amount: u64) ?u64 {
        const stamp = self.stamps[self.active];
        const slots = self.table(self.active);
        var at = hash[0] & (self.capacity - 1);
        while (true) : (at = (at + 1) & (self.capacity - 1)) {
            const slot = &slots[at];
            if (slot.stamp != stamp) {
                if (self.used >= self.max_keys) return null;
                self.used += 1;
                slot.* = .{ .hash = hash, .stamp = stamp, .count = saturated(0, amount) };
                return slot.count;
            }
            if (std.mem.eql(u64, &slot.hash, &hash)) {
                slot.count = saturated(slot.count, amount);
                return slot.count;
            }
        }
    }
};

fn saturated(count: u32, amount: u64) u32 {
    return std.math.cast(u32, @as(u64, count) +| amount) orelse std.math.maxInt(u32);
}

/// The process's counters. A handle is the index plus one. A slot, once filled,
/// never changes until the process ends.
const Table = struct {
    lock: sync.Mutex = .{},
    counters: [maximum_counters]?*Counter = @splat(null),

    fn make(self: *Table, window_seconds: u64, max_keys: u64) NewError!u64 {
        self.lock.lock();
        defer self.lock.unlock();
        const index = std.mem.indexOfScalar(?*Counter, &self.counters, null) orelse return error.TableFull;
        const start = instant.nowNanoseconds() orelse diagnostics.fatal("monotonic clock read failed or is out of range");
        var counter = try Counter.init(window_seconds, max_keys, start);
        errdefer counter.deinit();
        const stored = std.heap.smp_allocator.create(Counter) catch return error.Failed;
        stored.* = counter;
        self.counters[index] = stored;
        return index + 1;
    }

    fn get(self: *Table, handle: u64) ?*Counter {
        if (handle == 0 or handle > maximum_counters) return null;
        self.lock.lock();
        defer self.lock.unlock();
        return self.counters[handle - 1];
    }
};

var table: Table = .{};

fn rocHost() abi.RocHost {
    const context = allocator_context.current() orelse @panic("allocator context is not set");
    return runtime.makeRocHost(@ptrCast(context.host_allocator));
}

pub fn hostedRateCounterNew(window_seconds: u64, max_keys: u64) callconv(std.builtin.CallingConvention.c) abi.HostRateCounterMade {
    var result: abi.HostRateCounterMade = undefined;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    const handle = table.make(window_seconds, max_keys) catch |err| {
        result.tag = switch (err) {
            error.Invalid => abi.HostRateCounterMadeTag.Invalid,
            error.TableFull => abi.HostRateCounterMadeTag.TableFull,
            error.Failed => abi.HostRateCounterMadeTag.Failed,
        };
        return result;
    };
    result.tag = abi.HostRateCounterMadeTag.Made;
    const payload: *u64 = @ptrCast(@alignCast(&result.payload));
    payload.* = handle;
    return result;
}

pub fn hostedRateCounterAdd(handle: u64, key: abi.RocStr, amount: u64) callconv(std.builtin.CallingConvention.c) abi.HostRateCounterCounted {
    var roc_host = rocHost();
    defer key.decref(&roc_host);
    var result: abi.HostRateCounterCounted = undefined;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    const counter = table.get(handle) orelse {
        result.tag = abi.HostRateCounterCountedTag.Unknown;
        return result;
    };
    const now = instant.nowNanoseconds() orelse diagnostics.fatal("monotonic clock read failed or is out of range");
    const counts = counter.add(key.asSlice(), amount, now) orelse {
        result.tag = abi.HostRateCounterCountedTag.Full;
        return result;
    };
    result.tag = abi.HostRateCounterCountedTag.Counted;
    const payload: *@TypeOf(result.payload.counted) = @ptrCast(@alignCast(&result.payload));
    payload.* = .{ .current = counts.current, .previous = counts.previous, .elapsed_ms = counts.elapsed_ms };
    return result;
}

const second = nanoseconds_per_second;

fn testCounter(window_seconds: u64, max_keys: u64) !Counter {
    return Counter.init(window_seconds, max_keys, 1000);
}

test "counts a key, keeps keys apart, and reports the time in the window" {
    var counter = try testCounter(60, 10);
    defer counter.deinit();
    try std.testing.expectEqual(Counts{ .current = 1, .previous = 0, .elapsed_ms = 2000 }, counter.add("a", 1, 1000 + 2 * second).?);
    try std.testing.expectEqual(@as(u64, 3), counter.add("a", 2, 1000 + 3 * second).?.current);
    try std.testing.expectEqual(@as(u64, 1), counter.add("b", 1, 1000 + 3 * second).?.current);
}

test "the next window's previous count is this one; two windows later it is gone" {
    var counter = try testCounter(10, 10);
    defer counter.deinit();
    _ = counter.add("a", 5, 1000);
    const next = counter.add("a", 1, 1000 + 10 * second).?;
    try std.testing.expectEqual(@as(u64, 1), next.current);
    try std.testing.expectEqual(@as(u64, 5), next.previous);
    try std.testing.expectEqual(@as(u64, 0), next.elapsed_ms);
    const after_next = counter.add("a", 1, 1000 + 20 * second).?;
    try std.testing.expectEqual(@as(u64, 1), after_next.current);
    try std.testing.expectEqual(@as(u64, 1), after_next.previous);
    const later = counter.add("a", 1, 1000 + 60 * second).?;
    try std.testing.expectEqual(@as(u64, 1), later.current);
    try std.testing.expectEqual(@as(u64, 0), later.previous);
}

test "window boundaries: just before, at, and after" {
    var counter = try testCounter(10, 10);
    defer counter.deinit();
    _ = counter.add("a", 1, 1000);
    try std.testing.expectEqual(@as(u64, 2), counter.add("a", 1, 1000 + 10 * second - 1).?.current);
    try std.testing.expectEqual(@as(u64, 2), counter.add("a", 1, 1000 + 10 * second).?.previous);
}

test "a full window refuses a new key, goes on counting its keys, and opens with the next" {
    var counter = try testCounter(10, 2);
    defer counter.deinit();
    try std.testing.expect(counter.add("a", 1, 1000) != null);
    try std.testing.expect(counter.add("b", 1, 1000) != null);
    try std.testing.expect(counter.add("c", 1, 1000) == null);
    try std.testing.expectEqual(@as(u64, 2), counter.add("a", 1, 1000).?.current);
    // Refused means not recorded, and reading a new key is not refused.
    try std.testing.expectEqual(@as(u64, 0), counter.add("c", 0, 1000).?.current);
    try std.testing.expectEqual(@as(u64, 1), counter.add("c", 1, 1000 + 10 * second).?.current);
    try std.testing.expectEqual(@as(u64, 2), counter.add("a", 0, 1000 + 10 * second).?.previous);
}

test "reading records nothing" {
    var counter = try testCounter(10, 1);
    defer counter.deinit();
    try std.testing.expectEqual(@as(u64, 0), counter.add("a", 0, 1000).?.current);
    try std.testing.expect(counter.add("b", 1, 1000) != null);
    try std.testing.expectEqual(@as(u64, 1), counter.add("b", 0, 1000).?.current);
}

test "a count stops at its largest value, and a clock behind the start counts as the start" {
    var counter = try testCounter(10, 2);
    defer counter.deinit();
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)), counter.add("a", std.math.maxInt(u64), 1000).?.current);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)), counter.add("a", 1, 1000).?.current);
    try std.testing.expectEqual(@as(u64, 1), counter.add("b", 1, 0).?.current);
}

test "settings out of range are refused" {
    try std.testing.expectError(error.Invalid, Counter.init(0, 1, 0));
    try std.testing.expectError(error.Invalid, Counter.init(maximum_window_seconds + 1, 1, 0));
    try std.testing.expectError(error.Invalid, Counter.init(1, 0, 0));
    try std.testing.expectError(error.Invalid, Counter.init(1, maximum_keys + 1, 0));
}

test "many keys over many windows: counts stay right and tables stay bounded" {
    var counter = try testCounter(1, 1000);
    defer counter.deinit();
    var name: [16]u8 = undefined;
    var window: u64 = 0;
    while (window < 50) : (window += 1) {
        const now = 1000 + window * second;
        var key: u64 = 0;
        while (key < 1000) : (key += 1) {
            const text = try std.fmt.bufPrint(&name, "{d}", .{key});
            const counts = counter.add(text, 1, now).?;
            try std.testing.expectEqual(@as(u64, 1), counts.current);
            try std.testing.expectEqual(@as(u64, if (window == 0) 0 else 1), counts.previous);
        }
        try std.testing.expect(counter.add("one too many", 1, now) == null);
    }
}

test "threads count without losing any" {
    var counter = try testCounter(3600, 10);
    defer counter.deinit();
    const Worker = struct {
        fn run(shared: *Counter) void {
            for (0..10_000) |_| _ = shared.add("a", 1, 1000);
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{&counter});
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u64, 40_000), counter.add("a", 0, 1000).?.current);
}
