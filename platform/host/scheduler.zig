//! Request fibers: a thread's pool of stacks to run requests on, and
//! the process's fibers waiting for a socket or a deadline. A waiting
//! fiber's socket is watched once in a poller, so whichever thread receives
//! the event resumes the fiber; nothing polls the waiting sockets one by
//! one. Errors and hang-ups end a wait as readiness does: the read or write
//! that follows reports them.
const std = @import("std");
const fiber = @import("fiber.zig");
const net = @import("net.zig");
const poller_backend = @import("net/poller.zig");
const sync = @import("sync.zig");

/// Stacks a thread keeps for reuse once their requests end. A burst of
/// waiting requests may create more; the extra stacks are unmapped when
/// they end.
const maximum_idle_fibers = 64;

pub const Error = error{ OutOfMemory, PollerChangeFailed, ClockFailed };

/// A waiting fiber's poller token: the wait's slot in the high half, and in
/// the low half its generation with the top bit set. Connection tokens keep
/// the low half below 2^24 (a slot number), and the loop's own tokens have
/// all bits of the high half set, so neither can look like one.
pub fn isFiberToken(token: u64) bool {
    return (token & 0x8000_0000) != 0 and (token >> 32) != 0xffff_ffff;
}

fn fiberToken(slot: u32, generation: u32) u64 {
    return (@as(u64, slot) << 32) | 0x8000_0000 | (generation & 0x7fff_ffff);
}

/// A thread's stacks for new requests.
pub const FiberPool = struct {
    idle: std.ArrayList(*fiber.Fiber) = .empty,

    pub fn deinit(self: *FiberPool) void {
        for (self.idle.items) |target| target.destroy();
        self.idle.deinit(std.heap.smp_allocator);
    }

    /// A stack for a new request, prepared to run `start`.
    pub fn acquire(self: *FiberPool, start: *const fn (*fiber.Fiber) void, userdata: ?*anyopaque) error{OutOfMemory}!*fiber.Fiber {
        const target = self.idle.pop() orelse try fiber.Fiber.create();
        target.prepare(start, userdata);
        return target;
    }

    /// Takes back the stack of a finished request, whichever thread
    /// started it.
    pub fn release(self: *FiberPool, target: *fiber.Fiber) void {
        std.debug.assert(target.finished);
        if (self.idle.items.len >= maximum_idle_fibers) return target.destroy();
        self.idle.append(std.heap.smp_allocator, target) catch target.destroy();
    }
};

const Waiting = struct { target: *fiber.Fiber, generation: u32 };

/// The process's waiting fibers. Any thread registers a fiber that just
/// suspended, and any thread collects the ones whose wait ended.
pub const Waits = struct {
    mutex: sync.Mutex = .{},
    /// Waits in progress, by slot; a free slot is null.
    slots: std.ArrayList(?Waiting) = .empty,
    free_slots: std.ArrayList(u32) = .empty,
    waiting: usize = 0,
    generation: u32 = 0,
    /// No waiting deadline is earlier. Read without the lock to decide
    /// whether to look; the maximum means nothing waits for a deadline.
    earliest: std.atomic.Value(u64) = std.atomic.Value(u64).init(std.math.maxInt(u64)),
    /// The deadline the thread blocked on the poller sleeps until, 0 while
    /// none is: a wait registered with an earlier deadline wakes it. Not
    /// `earliest`, which can be earlier than what that thread sleeps until
    /// while a wake is not collected yet (`wake` sets it to 0), and later
    /// again once it is. Under `mutex`, with what it is compared to.
    armed: u64 = 0,
    poller: *poller_backend.Poller,

    pub fn deinit(self: *Waits) void {
        self.slots.deinit(std.heap.smp_allocator);
        self.free_slots.deinit(std.heap.smp_allocator);
    }

    /// Records a fiber that suspended in `fiber_wait.waitSocket`, watching
    /// its socket (if it has one; a deadline-only wait has none). A wake
    /// that came first ends the wait at once.
    pub fn addWaiting(self: *Waits, target: *fiber.Fiber) Error!void {
        const sooner = try self.register(target);
        // The thread waiting on the poller sleeps past this deadline: it
        // wakes to wait until this one.
        if (sooner) self.poller.wake() catch {};
    }

    /// Returns whether the wait ends before the deadline the thread blocked
    /// on the poller sleeps until.
    fn register(self: *Waits, target: *fiber.Fiber) Error!bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = self.free_slots.pop() orelse blk: {
            try self.slots.append(std.heap.smp_allocator, null);
            break :blk @as(u32, @intCast(self.slots.items.len - 1));
        };
        errdefer self.free_slots.append(std.heap.smp_allocator, slot) catch {};
        self.generation +%= 1;
        if (target.wait.socket >= 0) {
            self.poller.watchOnce(target.wait.socket, readable(target), fiberToken(slot, self.generation)) catch return error.PollerChangeFailed;
        }
        target.wait.slot = slot;
        self.slots.items[slot] = .{ .target = target, .generation = self.generation };
        self.waiting += 1;
        if (target.woken_serial == target.wait_serial) target.wait.expires_at_nanoseconds = 0;
        self.lowerEarliest(target.wait.expires_at_nanoseconds);
        return target.wait.expires_at_nanoseconds < self.armed;
    }

    fn lowerEarliest(self: *Waits, deadline: u64) void {
        if (deadline >= self.earliest.load(std.builtin.AtomicOrder.monotonic)) return;
        self.earliest.store(deadline, std.builtin.AtomicOrder.release);
    }

    /// Ends a deadline-only wait at once, as when the connection a request
    /// waits for comes back to its pool. `serial` names the wait; a wake for
    /// a wait that has not registered yet is kept for it.
    pub fn wake(self: *Waits, target: *fiber.Fiber, serial: u64) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            target.woken_serial = serial;
            if (target.wait_serial != serial) return;
            const slot = target.wait.slot;
            if (slot >= self.slots.items.len) return;
            const entry = self.slots.items[slot] orelse return;
            if (entry.target != target) return;
            target.wait.expires_at_nanoseconds = 0;
            self.earliest.store(0, std.builtin.AtomicOrder.release);
        }
        // A thread waiting on the poller collects it.
        self.poller.wake() catch {};
    }

    /// The poller reported a waiting fiber's socket: the fiber to resume,
    /// ready unless its deadline has passed, which takes precedence. Null
    /// for a stale token, of a wait that already ended.
    pub fn onEvent(self: *Waits, token: u64, now: u64) error{OutOfMemory}!?*fiber.Fiber {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot: u32 = @intCast(token >> 32);
        if (slot >= self.slots.items.len) return null;
        const entry = self.slots.items[slot] orelse return null;
        if (fiberToken(slot, entry.generation) != token) return null;
        entry.target.wait.outcome = waitOutcome(now, entry.target.wait.expires_at_nanoseconds, true).?;
        try self.finish(slot);
        return entry.target;
    }

    /// Moves the fibers whose deadline has passed to `ready`, timed out.
    pub fn collectExpired(self: *Waits, now: u64, ready: *std.ArrayList(*fiber.Fiber)) Error!void {
        if (now < self.earliest.load(std.builtin.AtomicOrder.acquire)) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        // Another collector may have processed this deadline while we waited
        // for the lock. Avoid scanning the slots again in that case.
        if (now < self.earliest.load(std.builtin.AtomicOrder.acquire)) return;
        var earliest: u64 = std.math.maxInt(u64);
        for (self.slots.items, 0..) |item, index| {
            const entry = item orelse continue;
            const wait = &entry.target.wait;
            if (now >= wait.expires_at_nanoseconds) {
                if (wait.socket >= 0) {
                    self.poller.unwatchOnce(wait.socket, readable(entry.target)) catch return error.PollerChangeFailed;
                }
                wait.outcome = .timed_out;
                try self.finish(@intCast(index));
                try ready.append(std.heap.smp_allocator, entry.target);
            } else {
                earliest = @min(earliest, wait.expires_at_nanoseconds);
            }
        }
        self.earliest.store(earliest, std.builtin.AtomicOrder.release);
    }

    /// How long the thread about to block on the poller may sleep, as
    /// `millisecondsUntilEarliest`; until `endBlockingWait`, a wait that
    /// registers with an earlier deadline wakes it.
    pub fn beginBlockingWait(self: *Waits, now: u64) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.armed = self.earliest.load(std.builtin.AtomicOrder.acquire);
        return untilDeadline(self.armed, now);
    }

    /// A thread that looked at the poller without blocking took a wake meant
    /// for the thread blocked on it: the process has one poller, and a wake
    /// goes to whichever thread looks first. It is passed on.
    pub fn passOnWake(self: *Waits) void {
        const blocked = blocked: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blocked self.armed != 0;
        };
        if (blocked) self.poller.wake() catch {};
    }

    /// The blocked thread's wait on the poller returned: it looks at the
    /// waits again before it blocks next, so none needs to wake it.
    pub fn endBlockingWait(self: *Waits) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.armed = 0;
    }

    /// How long a thread may wait for events before a deadline passes,
    /// rounded up so a fiber is never resumed early; null without waits.
    pub fn millisecondsUntilEarliest(self: *const Waits, now: u64) ?u32 {
        return untilDeadline(self.earliest.load(std.builtin.AtomicOrder.acquire), now);
    }

    fn untilDeadline(earliest: u64, now: u64) ?u32 {
        if (earliest == std.math.maxInt(u64)) return null;
        if (earliest <= now) return 0;
        const milliseconds = 1 + (earliest - now - 1) / std.time.ns_per_ms;
        return @intCast(@min(milliseconds, @as(u64, std.math.maxInt(i32))));
    }

    pub fn hasWaiting(self: *Waits) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.waiting != 0;
    }

    fn finish(self: *Waits, slot: u32) error{OutOfMemory}!void {
        self.slots.items[slot] = null;
        self.waiting -= 1;
        try self.free_slots.append(std.heap.smp_allocator, slot);
    }
};

fn readable(target: *const fiber.Fiber) bool {
    return (target.wait.events & std.c.POLL.OUT) == 0;
}

fn waitOutcome(now: u64, deadline: u64, ready: bool) ?fiber.Wait.Outcome {
    if (now >= deadline) return fiber.Wait.Outcome.timed_out;
    if (ready) return fiber.Wait.Outcome.ready;
    return null;
}

test "deadline boundary takes precedence over readiness" {
    for ([_]bool{ false, true }) |ready| {
        try std.testing.expectEqual(if (ready) fiber.Wait.Outcome.ready else null, waitOutcome(99, 100, ready));
        try std.testing.expectEqual(fiber.Wait.Outcome.timed_out, waitOutcome(100, 100, ready));
        try std.testing.expectEqual(fiber.Wait.Outcome.timed_out, waitOutcome(101, 100, ready));
    }
}

test "fiber tokens never look like connection or loop tokens" {
    try std.testing.expect(isFiberToken(fiberToken(0, 0)));
    try std.testing.expect(isFiberToken(fiberToken(4095, 0x7fff_ffff)));
    // A connection token: generation in the high half, a slot below 2^24.
    try std.testing.expect(!isFiberToken((@as(u64, 0xffff_fffe) << 32) | 0xff_ffff));
    // The loop's own tokens.
    for (0..8) |offset| try std.testing.expect(!isFiberToken(std.math.maxInt(u64) - offset));
}

const testing = std.testing;
const fiber_wait = @import("fiber_wait.zig");

const WaitProbe = struct {
    socket: c_int,
    expires_at: u64,
    outcome: ?fiber_wait.Outcome = null,

    fn start(target: *fiber.Fiber) void {
        const self: *WaitProbe = @ptrCast(@alignCast(target.userdata.?));
        self.outcome = fiber_wait.waitSocket(self.socket, std.c.POLL.IN, self.expires_at);
    }
};

fn socketPair() ![2]c_int {
    var ends: [2]c_int = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &ends) != 0) return error.SocketPairFailed;
    return ends;
}

/// Waits on the poller and hands fiber events to the waits.
fn pump(waits: *Waits, ready: *std.ArrayList(*fiber.Fiber)) !void {
    var raw: [8]poller_backend.RawEvent = undefined;
    var events: [8 * poller_backend.events_per_raw]poller_backend.Event = undefined;
    const now = try net.monotonicNanoseconds();
    for (try waits.poller.wait(&raw, &events, waits.millisecondsUntilEarliest(now))) |event| {
        if (!isFiberToken(event.token)) continue;
        if (try waits.onEvent(event.token, try net.monotonicNanoseconds())) |target| try ready.append(std.heap.smp_allocator, target);
    }
    try waits.collectExpired(try net.monotonicNanoseconds(), ready);
}

const TestSetup = struct {
    poller: poller_backend.Poller,
    waits: Waits,
    pool: FiberPool,

    fn init(self: *TestSetup) !void {
        self.poller = try poller_backend.Poller.init();
        try self.poller.registerWake(std.math.maxInt(u64) - 1);
        self.waits = .{ .poller = &self.poller };
        self.pool = .{};
    }

    fn deinit(self: *TestSetup) void {
        self.pool.deinit();
        self.waits.deinit();
        self.poller.deinit();
    }
};

test "a waiting fiber resumes when its socket becomes readable" {
    var setup: TestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    const ends = try socketPair();
    defer _ = std.c.close(ends[0]);
    defer _ = std.c.close(ends[1]);

    var probe = WaitProbe{ .socket = ends[0], .expires_at = (try net.monotonicNanoseconds()) + 10 * std.time.ns_per_s };
    const target = try setup.pool.acquire(WaitProbe.start, &probe);
    fiber.resumeFiber(target);
    try testing.expect(!target.finished);
    try setup.waits.addWaiting(target);

    var ready: std.ArrayList(*fiber.Fiber) = .empty;
    defer ready.deinit(std.heap.smp_allocator);
    _ = std.c.write(ends[1], "x", 1);
    try pump(&setup.waits, &ready);
    try testing.expectEqual(@as(usize, 1), ready.items.len);
    try testing.expect(!setup.waits.hasWaiting());
    fiber.resumeFiber(ready.items[0]);
    try testing.expect(target.finished);
    try testing.expectEqual(@as(?fiber_wait.Outcome, .ready), probe.outcome);
    setup.pool.release(target);
}

test "a deadline sooner than the blocked poller's wakes it, whatever the earliest is" {
    var setup: TestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    const ends = try socketPair();
    defer _ = std.c.close(ends[0]);
    defer _ = std.c.close(ends[1]);

    // A thread blocks on the poller with no deadline; then a wake ends a
    // wait it has not collected, which makes `earliest` 0.
    const now = try net.monotonicNanoseconds();
    try testing.expectEqual(@as(?u32, null), setup.waits.beginBlockingWait(now));
    setup.waits.earliest.store(0, std.builtin.AtomicOrder.release);
    // A newly registered deadline must wake the thread blocked without a deadline.
    var probe = WaitProbe{ .socket = ends[0], .expires_at = now + 100 * std.time.ns_per_ms };
    const target = try setup.pool.acquire(WaitProbe.start, &probe);
    fiber.resumeFiber(target);
    try testing.expect(try setup.waits.register(target));
    // A thread not blocked looks at the waits before it blocks: nothing to
    // wake.
    setup.waits.endBlockingWait();
    var later = WaitProbe{ .socket = ends[1], .expires_at = now + 200 * std.time.ns_per_ms };
    const other = try setup.pool.acquire(WaitProbe.start, &later);
    fiber.resumeFiber(other);
    try testing.expect(!try setup.waits.register(other));

    var ready: std.ArrayList(*fiber.Fiber) = .empty;
    defer ready.deinit(std.heap.smp_allocator);
    setup.waits.earliest.store(0, std.builtin.AtomicOrder.release);
    while (ready.items.len < 2) {
        try setup.waits.collectExpired(try net.monotonicNanoseconds(), &ready);
        try pump(&setup.waits, &ready);
    }
    for (ready.items) |resumed| fiber.resumeFiber(resumed);
    setup.pool.release(target);
    setup.pool.release(other);
}

test "a wake a thread took without blocking is passed on to the blocked one" {
    var setup: TestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var raw: [4]poller_backend.RawEvent = undefined;
    var events: [4 * poller_backend.events_per_raw]poller_backend.Event = undefined;
    // Nobody is blocked: nothing to pass on.
    setup.waits.passOnWake();
    try testing.expectEqual(@as(usize, 0), (try setup.poller.wait(&raw, &events, 0)).len);
    // A thread is blocked until some deadline: the wake is sent again.
    setup.waits.earliest.store(1, std.builtin.AtomicOrder.release);
    _ = setup.waits.beginBlockingWait(0);
    setup.waits.passOnWake();
    const reported = try setup.poller.wait(&raw, &events, 0);
    try testing.expectEqual(@as(usize, 1), reported.len);
    try testing.expectEqual(poller_backend.Event.Kind.wake, reported[0].kind);
    setup.waits.endBlockingWait();
    setup.waits.passOnWake();
    try testing.expectEqual(@as(usize, 0), (try setup.poller.wait(&raw, &events, 0)).len);
}

test "a waiting fiber times out at its deadline" {
    var setup: TestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    const ends = try socketPair();
    defer _ = std.c.close(ends[0]);
    defer _ = std.c.close(ends[1]);

    const started = try net.monotonicNanoseconds();
    var probe = WaitProbe{ .socket = ends[0], .expires_at = started + 20 * std.time.ns_per_ms };
    const target = try setup.pool.acquire(WaitProbe.start, &probe);
    fiber.resumeFiber(target);
    try setup.waits.addWaiting(target);

    var ready: std.ArrayList(*fiber.Fiber) = .empty;
    defer ready.deinit(std.heap.smp_allocator);
    while (ready.items.len == 0) try pump(&setup.waits, &ready);
    try testing.expect((try net.monotonicNanoseconds()) >= probe.expires_at);
    fiber.resumeFiber(ready.items[0]);
    try testing.expectEqual(@as(?fiber_wait.Outcome, .timed_out), probe.outcome);
    // The timed-out wait no longer reports the socket.
    _ = std.c.write(ends[1], "x", 1);
    var raw: [4]poller_backend.RawEvent = undefined;
    var events: [4 * poller_backend.events_per_raw]poller_backend.Event = undefined;
    try testing.expectEqual(@as(usize, 0), (try setup.poller.wait(&raw, &events, 0)).len);
    setup.pool.release(target);
}

test "readiness cannot resume an expired fiber successfully" {
    var setup: TestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    const ends = try socketPair();
    defer _ = std.c.close(ends[0]);
    defer _ = std.c.close(ends[1]);
    var probe = WaitProbe{ .socket = ends[0], .expires_at = 1 };
    const target = try setup.pool.acquire(WaitProbe.start, &probe);
    fiber.resumeFiber(target);
    try setup.waits.addWaiting(target);
    _ = std.c.write(ends[1], "x", 1);
    var ready: std.ArrayList(*fiber.Fiber) = .empty;
    defer ready.deinit(std.heap.smp_allocator);
    try pump(&setup.waits, &ready);
    fiber.resumeFiber(target);
    defer setup.pool.release(target);
    try testing.expectEqual(fiber.Wait.Outcome.timed_out, probe.outcome.?);
}

test "a deadline-only wait ends early when woken, from any thread" {
    var setup: TestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var probe = WaitProbe{ .socket = -1, .expires_at = (try net.monotonicNanoseconds()) + 10 * std.time.ns_per_s };
    const target = try setup.pool.acquire(WaitProbe.start, &probe);
    fiber.resumeFiber(target);
    try setup.waits.addWaiting(target);
    var ready: std.ArrayList(*fiber.Fiber) = .empty;
    defer ready.deinit(std.heap.smp_allocator);
    try setup.waits.collectExpired(try net.monotonicNanoseconds(), &ready);
    try testing.expectEqual(@as(usize, 0), ready.items.len);
    const Other = struct {
        fn wake(waits: *Waits, woken: *fiber.Fiber, serial: u64) void {
            waits.wake(woken, serial);
        }
    };
    // A wake for an earlier wait does nothing; the current one ends it.
    const stale = try std.Thread.spawn(.{}, Other.wake, .{ &setup.waits, target, target.wait_serial - 1 });
    stale.join();
    try setup.waits.collectExpired(try net.monotonicNanoseconds(), &ready);
    try testing.expectEqual(@as(usize, 0), ready.items.len);
    const current = try std.Thread.spawn(.{}, Other.wake, .{ &setup.waits, target, target.wait_serial });
    current.join();
    try testing.expectEqual(@as(?u32, 0), setup.waits.millisecondsUntilEarliest(try net.monotonicNanoseconds()));
    try setup.waits.collectExpired(try net.monotonicNanoseconds(), &ready);
    try testing.expectEqual(@as(usize, 1), ready.items.len);
    fiber.resumeFiber(target);
    setup.pool.release(target);
}

test "a wake that comes before the wait registers is kept for it" {
    var setup: TestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var probe = WaitProbe{ .socket = -1, .expires_at = (try net.monotonicNanoseconds()) + 10 * std.time.ns_per_s };
    const target = try setup.pool.acquire(WaitProbe.start, &probe);
    fiber.resumeFiber(target);
    // The fiber has suspended but is not registered yet.
    setup.waits.wake(target, target.wait_serial);
    try setup.waits.addWaiting(target);
    var ready: std.ArrayList(*fiber.Fiber) = .empty;
    defer ready.deinit(std.heap.smp_allocator);
    try setup.waits.collectExpired(try net.monotonicNanoseconds(), &ready);
    try testing.expectEqual(@as(usize, 1), ready.items.len);
    fiber.resumeFiber(target);
    setup.pool.release(target);
}
