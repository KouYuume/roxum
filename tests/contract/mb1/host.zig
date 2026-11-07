//! Retain a root Box across consuming calls and verify the allocation baseline.
//! Direct refcount inspection is test instrumentation, not a production ABI API.
//!   MB1_ITERATIONS=1000000 ./mb1-small

const std = @import("std");
const abi = @import("roc_platform_abi");

const canary_size = 16;
const canary_byte: u8 = 0xA5;
const poison_byte: u8 = 0xCC;
const max_tracked = 4096;

const Allocation = struct {
    raw: ?[*]u8 = null,
    user: ?[*]u8 = null,
    length: usize = 0,
    alignment: usize = 0,
    live: bool = false,
};

const Tracker = struct {
    allocations: [max_tracked]Allocation = [_]Allocation{.{}} ** max_tracked,
    alloc_count: u64 = 0,
    dealloc_count: u64 = 0,
    live_count: u64 = 0,
    peak_live: u64 = 0,
    canary_violations: u64 = 0,
    slot_exhausted: u64 = 0,

    fn slotFor(self: *Tracker, user: [*]u8) ?*Allocation {
        for (&self.allocations) |*a| {
            if (a.live and a.user == user) return a;
        }
        return null;
    }

    fn freeSlot(self: *Tracker) ?*Allocation {
        for (&self.allocations) |*a| {
            if (!a.live) return a;
        }
        return null;
    }

    fn alloc(self: *Tracker, length: usize, alignment: usize) ?*anyopaque {
        // [canary][padding for alignment][user data][canary]
        const total = canary_size + alignment - 1 + length + canary_size;
        const raw_opt = std.c.malloc(total);
        const raw: [*]u8 = @ptrCast(raw_opt orelse return null);

        const user_addr = std.mem.alignForward(usize, @intFromPtr(raw) + canary_size, alignment);
        const user: [*]u8 = @ptrFromInt(user_addr);

        @memset((user - canary_size)[0..canary_size], canary_byte);
        @memset(user[0..length], poison_byte);
        @memset((user + length)[0..canary_size], canary_byte);

        const slot = self.freeSlot() orelse {
            self.slot_exhausted += 1;
            std.c.free(raw);
            return null;
        };
        slot.* = .{ .raw = raw, .user = user, .length = length, .alignment = alignment, .live = true };

        self.alloc_count += 1;
        self.live_count += 1;
        if (self.live_count > self.peak_live) self.peak_live = self.live_count;
        return @ptrCast(user);
    }

    fn checkCanaries(self: *Tracker, a: *const Allocation) void {
        const user = a.user orelse return;
        for (0..canary_size) |i| {
            if ((user - canary_size)[i] != canary_byte) {
                self.canary_violations += 1;
                return;
            }
            if ((user + a.length)[i] != canary_byte) {
                self.canary_violations += 1;
                return;
            }
        }
    }

    fn dealloc(self: *Tracker, ptr: *anyopaque) void {
        const user: [*]u8 = @ptrCast(ptr);
        const slot = self.slotFor(user) orelse {
            self.canary_violations += 1;
            return;
        };
        self.checkCanaries(slot);
        std.c.free(slot.raw.?);
        slot.live = false;
        self.dealloc_count += 1;
        self.live_count -= 1;
    }
};

var tracker: Tracker = .{};

export fn roc_alloc(length: usize, alignment: usize) callconv(std.builtin.CallingConvention.c) *anyopaque {
    return tracker.alloc(length, alignment) orelse @panic("out of memory");
}

export fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(std.builtin.CallingConvention.c) void {
    _ = alignment;
    tracker.dealloc(ptr);
}

export fn roc_realloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(std.builtin.CallingConvention.c) *anyopaque {
    const user: [*]u8 = @ptrCast(ptr);
    const old = tracker.slotFor(user) orelse @panic("realloc of an unknown pointer");
    const old_len = old.length;

    const new_ptr = tracker.alloc(new_length, alignment) orelse @panic("out of memory");
    const dst: [*]u8 = @ptrCast(new_ptr);
    @memcpy(dst[0..@min(old_len, new_length)], user[0..@min(old_len, new_length)]);
    tracker.dealloc(ptr);
    return new_ptr;
}

export fn roc_dbg(bytes: [*]const u8, len: usize) callconv(std.builtin.CallingConvention.c) void {
    std.debug.print("[roc dbg] {s}\n", .{bytes[0..len]});
}

export fn roc_expect_failed(bytes: [*]const u8, len: usize) callconv(std.builtin.CallingConvention.c) void {
    std.debug.print("[roc expect failed] {s}\n", .{bytes[0..len]});
}

export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(std.builtin.CallingConvention.c) noreturn {
    std.debug.print("[roc crashed] {s}\n", .{bytes[0..len]});
    std.process.exit(1);
}

fn refcountOf(box: ?*anyopaque) isize {
    const data: [*]u8 = @ptrCast(box orelse return 0);
    const rc: *const isize = @ptrFromInt(@intFromPtr(data) - @sizeOf(isize));
    return rc.*;
}

fn envU64(name: [*:0]const u8, default: u64) u64 {
    const raw = std.c.getenv(name) orelse return default;
    const slice = std.mem.span(raw);
    return std.fmt.parseInt(u64, slice, 10) catch default;
}

fn envFlag(name: [*:0]const u8) bool {
    const raw = std.c.getenv(name) orelse return false;
    return std.mem.span(raw).len > 0;
}
fn nowNanos() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    const iterations: u64 = envU64("MB1_ITERATIONS", 1_000_000);
    const use_incref = !envFlag("MB1_NO_INCREF");

    std.debug.print("MB-1 box-model spike\n", .{});
    std.debug.print("  iterations : {d}\n", .{iterations});
    std.debug.print("  incref     : {s}\n", .{if (use_incref) "on" else "OFF (observing the breakage)"});
    std.debug.print("\n", .{});

    const root = abi.roc_init();
    const baseline_live = tracker.live_count;
    const rc_after_init = refcountOf(root);

    std.debug.print("after init:\n", .{});
    std.debug.print("  live_alloc_count = {d}  (baseline)\n", .{baseline_live});
    std.debug.print("  refcount(root)   = {d}\n", .{rc_after_init});
    std.debug.print("\n", .{});

    if (use_incref) abi.increfBox(root, 1);
    const rc_before_call = refcountOf(root);
    const first = abi.roc_handle(root, 1);
    const rc_after_call = refcountOf(root);

    std.debug.print("first call:\n", .{});
    std.debug.print("  rc after incref = {d}\n", .{rc_before_call});
    std.debug.print("  rc after call   = {d}   <- one less if Roc decref'd it\n", .{rc_after_call});
    std.debug.print("  return value     = {d}\n", .{first});
    std.debug.print("  live          = {d}  (baseline={d})\n", .{ tracker.live_count, baseline_live });
    std.debug.print("\n", .{});

    const started_at = nowNanos();
    var leaked_at: ?u64 = null;
    var i: u64 = 1;
    while (i < iterations) : (i += 1) {
        if (use_incref) abi.increfBox(root, 1);
        _ = abi.roc_handle(root, i);

        if (leaked_at == null and tracker.live_count != baseline_live) {
            leaked_at = i;
        }
    }
    const elapsed_ns = nowNanos() - started_at;

    const ok = tracker.live_count == baseline_live and
        tracker.canary_violations == 0 and
        tracker.slot_exhausted == 0;

    std.debug.print("result:\n", .{});
    std.debug.print("  elapsed           = {d:.3} ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0});
    std.debug.print("  per call          = {d:.1} ns\n", .{@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations))});
    std.debug.print("  alloc_count       = {d}\n", .{tracker.alloc_count});
    std.debug.print("  dealloc_count     = {d}\n", .{tracker.dealloc_count});
    std.debug.print("  live_count        = {d}  (baseline={d})\n", .{ tracker.live_count, baseline_live });
    std.debug.print("  peak_live         = {d}\n", .{tracker.peak_live});
    std.debug.print("  canary_violations = {d}\n", .{tracker.canary_violations});
    std.debug.print("  slot_exhausted    = {d}\n", .{tracker.slot_exhausted});
    std.debug.print("  refcount(root)    = {d}\n", .{refcountOf(root)});
    if (leaked_at) |at| {
        std.debug.print("  ⚠️ first iteration where live left the baseline: {d}\n", .{at});
    }
    std.debug.print("\n  {s}\n", .{if (ok) "PASS" else "FAIL"});

    if (!ok) std.process.exit(1);
}
