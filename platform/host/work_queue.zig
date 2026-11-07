//! The work of a process's Roc threads: each thread takes its next
//! job, then from the injector the acceptor fills, then from its own queue,
//! then steals half of another thread's queue. Every queue has its own lock; work moves
//! between queues only whole.
const std = @import("std");
const fiber = @import("fiber.zig");
const poller_backend = @import("net/poller.zig");
const sync = @import("sync.zig");

pub const Job = union(enum) {
    /// A request the loop read, to run on a new fiber.
    request: u32,
    /// A request fiber whose wait ended, seen by the acceptor while every
    /// Roc thread was busy.
    resumed: *fiber.Fiber,
};

pub const JobQueue = struct {
    mutex: sync.Mutex = .{},
    items: std.ArrayList(Job) = .empty,
    /// Where the queue starts in `items`; taken items before it are dead.
    head: usize = 0,
    /// The jobs queued, kept under the lock and read without it, so a
    /// thread looks at an empty queue without taking its lock.
    count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn deinit(self: *JobQueue) void {
        self.items.deinit(std.heap.smp_allocator);
    }

    pub fn push(self: *JobQueue, job: Job) error{OutOfMemory}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Reuse consumed storage before growing a queue that never becomes empty.
        if (self.items.items.len == self.items.capacity and self.head != 0) {
            const live = self.items.items.len - self.head;
            std.mem.copyForwards(Job, self.items.items[0..live], self.items.items[self.head..]);
            self.items.shrinkRetainingCapacity(live);
            self.head = 0;
        }
        try self.items.append(std.heap.smp_allocator, job);
        self.recount();
    }

    pub fn pop(self: *JobQueue) ?Job {
        if (self.len() == 0) return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        const job = self.popLocked();
        self.recount();
        return job;
    }

    fn popLocked(self: *JobQueue) ?Job {
        if (self.head == self.items.items.len) return null;
        const job = self.items.items[self.head];
        self.head += 1;
        if (self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        }
        return job;
    }

    /// Called with the lock held after any change.
    fn recount(self: *JobQueue) void {
        self.count.store(self.items.items.len - self.head, std.builtin.AtomicOrder.release);
    }

    /// The jobs queued as of a moment ago, read without the lock.
    pub fn len(self: *const JobQueue) usize {
        return self.count.load(std.builtin.AtomicOrder.acquire);
    }

    /// Moves the older half of `self` (at least one job, when it has any)
    /// to the end of `into`. Returns how many moved.
    pub fn stealHalf(self: *JobQueue, into: *JobQueue) error{OutOfMemory}!usize {
        return self.stealHalfWithAllocator(into, std.heap.smp_allocator);
    }

    fn stealHalfWithAllocator(self: *JobQueue, into: *JobQueue, allocator: std.mem.Allocator) error{OutOfMemory}!usize {
        if (self == into or self.len() == 0) return 0;
        // Stable lock ordering also permits simultaneous steals in opposite directions.
        const first = if (@intFromPtr(self) < @intFromPtr(into)) self else into;
        const second = if (first == self) into else self;
        first.mutex.lock();
        defer first.mutex.unlock();
        second.mutex.lock();
        defer second.mutex.unlock();
        const available = self.items.items.len - self.head;
        const count = @min(@as(usize, 64), (available + 1) / 2);
        if (count == 0) return 0;
        // Allocation must succeed before either queue loses ownership.
        try into.items.ensureUnusedCapacity(allocator, count);
        for (0..count) |_| into.items.appendAssumeCapacity(self.popLocked().?);
        self.recount();
        into.recount();
        return count;
    }

    /// Takes out the requests `expired` says waited too long, keeping the
    /// order of the rest, and appends their slots to `into`. Returns how
    /// many it took.
    pub fn takeExpired(
        self: *JobQueue,
        context: anytype,
        comptime expired: fn (@TypeOf(context), u32) bool,
        into: *std.ArrayList(u32),
    ) error{OutOfMemory}!usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const before = into.items.len;
        var kept = self.head;
        for (self.items.items[self.head..]) |job| {
            switch (job) {
                Job.request => |slot| if (expired(context, slot)) {
                    try into.append(std.heap.smp_allocator, slot);
                    continue;
                },
                Job.resumed => {},
            }
            self.items.items[kept] = job;
            kept += 1;
        }
        self.items.shrinkRetainingCapacity(kept);
        if (self.head == kept) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        }
        self.recount();
        return into.items.len - before;
    }
};

/// The process's queues and its idle Roc threads. One idle thread at
/// a time waits on `poller`; the others park on a condition, so an event
/// wakes one thread rather than all of them. A job pushed while a thread is
/// idle wakes a parked one, or the one on the poller.
pub const Jobs = struct {
    injector: JobQueue = .{},
    /// One per Roc thread, by its index.
    queues: []JobQueue = &.{},
    /// Requests queued and not taken yet, in every queue (the
    /// `maximum_queued_requests` counts them).
    queued_requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    idle_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    poller: ?*poller_backend.Poller = null,
    /// Set while an idle thread waits on the poller.
    poller_taken: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    park_lock: sync.Mutex = .{},
    park_ready: sync.Condition = .{},
    /// Parked threads, and the wakes sent to them not yet taken; under
    /// `park_lock`.
    parked: usize = 0,
    wakes: usize = 0,

    /// Makes a queue for each of `threads` Roc threads.
    pub fn init(threads: usize, poller: *poller_backend.Poller) error{OutOfMemory}!Jobs {
        const queues = try std.heap.smp_allocator.alloc(JobQueue, threads);
        for (queues) |*queue| queue.* = .{};
        return .{ .queues = queues, .poller = poller };
    }

    /// Queues a job for any thread, as the acceptor does.
    pub fn push(self: *Jobs, job: Job) error{OutOfMemory}!void {
        try self.pushTo(&self.injector, job);
    }

    /// Queues a job at the end of thread `index`'s own queue, as a Roc
    /// thread does for a request whose head it read or a stream it
    /// continues; idle threads may steal it. The jobs a thread queues run
    /// in the order they came: a request read just now does not go
    /// before those read earlier, as Tokio queues a task its I/O woke.
    pub fn pushOwn(self: *Jobs, index: usize, job: Job) error{OutOfMemory}!void {
        if (job == Job.request) _ = self.queued_requests.fetchAdd(1, std.builtin.AtomicOrder.monotonic);
        const queue = &self.queues[index];
        queue.push(job) catch |err| {
            if (job == Job.request) _ = self.queued_requests.fetchSub(1, std.builtin.AtomicOrder.monotonic);
            return err;
        };
        // One thread is woken for the first job queued; it wakes the next
        // when it finds more (`next`), so a batch of heads read at once
        // does not wake a thread for each.
        if (queue.len() == 1) self.wakeIdle();
    }

    fn pushTo(self: *Jobs, queue: *JobQueue, job: Job) error{OutOfMemory}!void {
        if (job == Job.request) _ = self.queued_requests.fetchAdd(1, std.builtin.AtomicOrder.monotonic);
        queue.push(job) catch |err| {
            if (job == Job.request) _ = self.queued_requests.fetchSub(1, std.builtin.AtomicOrder.monotonic);
            return err;
        };
        self.wakeIdle();
    }

    /// Wakes an idle thread, if any: a parked one, or else the one on the
    /// poller. Pairs with `beginIdle`: a thread counts itself idle before it
    /// looks at the queues a last time, so a job pushed after that look
    /// finds it counted.
    fn wakeIdle(self: *Jobs) void {
        if (self.idle_threads.load(std.builtin.AtomicOrder.seq_cst) == 0) return;
        if (self.unpark()) return;
        const poller = self.poller orelse return;
        poller.wake() catch {};
    }

    /// The next job for thread `index`: the injector's, its queue's, or
    /// half of another thread's queue. When more remain and
    /// another thread is idle, it is woken to take them.
    pub fn next(self: *Jobs, index: usize) ?Job {
        const own = &self.queues[index];
        // The injector before the thread's own queue: what the acceptor
        // queues (a new connection's first request) does not wait behind a
        // run of pipelined requests the thread queued itself.
        const job = self.injector.pop() orelse own.pop() orelse self.steal(index) orelse return null;
        if (job == Job.request) _ = self.queued_requests.fetchSub(1, std.builtin.AtomicOrder.monotonic);
        if (self.injector.len() != 0 or own.len() != 0) self.wakeIdle();
        return job;
    }

    fn steal(self: *Jobs, index: usize) ?Job {
        const own = &self.queues[index];
        for (1..self.queues.len) |offset| {
            const victim = &self.queues[(index + offset) % self.queues.len];
            const moved = victim.stealHalf(own) catch return null;
            if (moved != 0) return own.pop();
        }
        return null;
    }

    /// Counts the calling thread idle; it then looks for a job once more
    /// before it waits (on the poller, or parked), and calls `endIdle` after.
    pub fn beginIdle(self: *Jobs) void {
        _ = self.idle_threads.fetchAdd(1, std.builtin.AtomicOrder.seq_cst);
    }

    pub fn endIdle(self: *Jobs) void {
        _ = self.idle_threads.fetchSub(1, std.builtin.AtomicOrder.seq_cst);
    }

    /// Takes the poller for an idle thread to wait on; false when another
    /// thread waits on it.
    pub fn takePoller(self: *Jobs) bool {
        return self.poller_taken.cmpxchgStrong(false, true, std.builtin.AtomicOrder.acq_rel, std.builtin.AtomicOrder.monotonic) == null;
    }

    /// Whether an idle thread waits on the poller now.
    pub fn pollerTaken(self: *const Jobs) bool {
        return self.poller_taken.load(std.builtin.AtomicOrder.acquire);
    }

    /// Gives up the poller once its wait returns, and wakes a parked thread
    /// to wait on it in its place.
    pub fn releasePoller(self: *Jobs) void {
        self.poller_taken.store(false, std.builtin.AtomicOrder.release);
        _ = self.unpark();
    }

    /// Waits for a wake: a new job, or the poller given up.
    pub fn park(self: *Jobs) void {
        self.park_lock.lock();
        defer self.park_lock.unlock();
        self.parked += 1;
        while (self.wakes == 0) self.park_ready.wait(&self.park_lock);
        self.wakes -= 1;
        self.parked -= 1;
    }

    /// Wakes one parked thread not already being woken. False when none is.
    fn unpark(self: *Jobs) bool {
        self.park_lock.lock();
        defer self.park_lock.unlock();
        if (self.parked <= self.wakes) return false;
        self.wakes += 1;
        self.park_ready.signal();
        return true;
    }

    /// Takes out the requests that waited too long in every queue, appending
    /// their slots to `into`.
    pub fn takeExpired(
        self: *Jobs,
        context: anytype,
        comptime expired: fn (@TypeOf(context), u32) bool,
        into: *std.ArrayList(u32),
    ) error{OutOfMemory}!void {
        var taken = try self.injector.takeExpired(context, expired, into);
        for (self.queues) |*queue| taken += try queue.takeExpired(context, expired, into);
        _ = self.queued_requests.fetchSub(taken, std.builtin.AtomicOrder.monotonic);
    }

    pub fn queuedRequests(self: *const Jobs) usize {
        return self.queued_requests.load(std.builtin.AtomicOrder.monotonic);
    }
};

test "a queue is first in, first out, and a thief takes the older half" {
    var queue = JobQueue{};
    defer queue.deinit();
    var thief = JobQueue{};
    defer thief.deinit();
    for (0..5) |slot| try queue.push(.{ .request = @intCast(slot) });
    try std.testing.expectEqual(@as(u32, 0), queue.pop().?.request);
    try std.testing.expectEqual(@as(usize, 2), try queue.stealHalf(&thief));
    try std.testing.expectEqual(@as(u32, 1), thief.pop().?.request);
    try std.testing.expectEqual(@as(u32, 2), thief.pop().?.request);
    try std.testing.expectEqual(@as(u32, 3), queue.pop().?.request);
    try std.testing.expectEqual(@as(usize, 1), try queue.stealHalf(&thief));
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expectEqual(@as(usize, 0), try queue.stealHalf(&thief));
}

test "expired requests leave the queue, the rest keep their order" {
    var queue = JobQueue{};
    defer queue.deinit();
    // A fiber's job never expires.
    var resumed: fiber.Fiber = undefined;
    for ([_]u32{ 1, 2, 3, 4 }) |slot| try queue.push(.{ .request = slot });
    try queue.push(.{ .resumed = &resumed });
    _ = queue.pop();
    const Even = struct {
        fn expired(_: void, slot: u32) bool {
            return slot % 2 == 0;
        }
    };
    var slots: std.ArrayList(u32) = .empty;
    defer slots.deinit(std.heap.smp_allocator);
    try std.testing.expectEqual(@as(usize, 2), try queue.takeExpired({}, Even.expired, &slots));
    try std.testing.expectEqualSlices(u32, &.{ 2, 4 }, slots.items);
    try std.testing.expectEqual(@as(u32, 3), queue.pop().?.request);
    try std.testing.expectEqual(&resumed, queue.pop().?.resumed);
    try std.testing.expectEqual(@as(?Job, null), queue.pop());
}

test "a thread takes the injector's jobs, then its own, then another thread's" {
    var poller = try poller_backend.Poller.init();
    defer poller.deinit();
    try poller.registerWake(1);
    var jobs = try Jobs.init(2, &poller);
    defer {
        jobs.injector.deinit();
        for (jobs.queues) |*queue| queue.deinit();
        std.heap.smp_allocator.free(jobs.queues);
    }
    var resumed: fiber.Fiber = undefined;
    try jobs.push(.{ .request = 1 });
    try jobs.pushOwn(0, .{ .resumed = &resumed });
    try jobs.pushOwn(1, .{ .request = 3 });
    try std.testing.expectEqual(@as(usize, 2), jobs.queuedRequests());
    try std.testing.expectEqual(@as(u32, 1), jobs.next(0).?.request);
    try std.testing.expectEqual(&resumed, jobs.next(0).?.resumed);
    // Thread 1's job, stolen by thread 0.
    try std.testing.expectEqual(@as(u32, 3), jobs.next(0).?.request);
    try std.testing.expectEqual(@as(?Job, null), jobs.next(1));
    try std.testing.expectEqual(@as(usize, 0), jobs.queuedRequests());
}

test "a job pushed while a thread is idle wakes its poller" {
    var poller = try poller_backend.Poller.init();
    defer poller.deinit();
    try poller.registerWake(1);
    var jobs = try Jobs.init(1, &poller);
    defer {
        jobs.injector.deinit();
        for (jobs.queues) |*queue| queue.deinit();
        std.heap.smp_allocator.free(jobs.queues);
    }
    var raw: [4]poller_backend.RawEvent = undefined;
    var events: [4 * poller_backend.events_per_raw]poller_backend.Event = undefined;
    // Nobody idle: no wake.
    try jobs.push(.{ .request = 1 });
    try std.testing.expectEqual(@as(usize, 0), (try poller.wait(&raw, &events, 0)).len);
    _ = jobs.next(0);
    jobs.beginIdle();
    defer jobs.endIdle();
    try jobs.push(.{ .request = 2 });
    const woken = try poller.wait(&raw, &events, 1000);
    try std.testing.expectEqual(@as(usize, 1), woken.len);
    try std.testing.expectEqual(poller_backend.Event.Kind.wake, woken[0].kind);
}

test "a thread runs the jobs it queued in order, and an idle one may steal them" {
    var poller = try poller_backend.Poller.init();
    defer poller.deinit();
    try poller.registerWake(1);
    var jobs = try Jobs.init(2, &poller);
    defer {
        jobs.injector.deinit();
        for (jobs.queues) |*queue| queue.deinit();
        std.heap.smp_allocator.free(jobs.queues);
    }
    // A request read later does not go before one read earlier.
    for ([_]u32{ 1, 2, 3 }) |slot| try jobs.pushOwn(0, .{ .request = slot });
    try std.testing.expectEqual(@as(u32, 1), jobs.next(0).?.request);
    // Thread 1 steals the older half of what is left.
    try std.testing.expectEqual(@as(u32, 2), jobs.next(1).?.request);
    try std.testing.expectEqual(@as(u32, 3), jobs.next(0).?.request);
    try std.testing.expectEqual(@as(?Job, null), jobs.next(0));
    try std.testing.expectEqual(@as(usize, 0), jobs.queuedRequests());
}

test "a parked thread wakes for a job, and one thread at a time takes the poller" {
    var poller = try poller_backend.Poller.init();
    defer poller.deinit();
    try poller.registerWake(1);
    var jobs = try Jobs.init(2, &poller);
    defer {
        jobs.injector.deinit();
        for (jobs.queues) |*queue| queue.deinit();
        std.heap.smp_allocator.free(jobs.queues);
    }
    try std.testing.expect(jobs.takePoller());
    try std.testing.expect(!jobs.takePoller());
    const Parker = struct {
        fn run(work: *Jobs, taken: *?Job) void {
            work.beginIdle();
            work.park();
            work.endIdle();
            taken.* = work.next(1);
        }
    };
    var taken: ?Job = null;
    const thread = try std.Thread.spawn(.{}, Parker.run, .{ &jobs, &taken });
    // Wait until it has parked, then queue a job: it wakes for it.
    while (true) {
        jobs.park_lock.lock();
        const parked = jobs.parked;
        jobs.park_lock.unlock();
        if (parked == 1) break;
        std.Thread.yield() catch {};
    }
    try jobs.push(.{ .request = 7 });
    thread.join();
    try std.testing.expectEqual(@as(u32, 7), taken.?.request);
    jobs.releasePoller();
    try std.testing.expect(jobs.takePoller());
}

test "failed stealing preserves ownership and order in both queues" {
    var source = JobQueue{};
    defer source.deinit();
    var destination = JobQueue{};
    defer destination.deinit();
    // Empty destination needs its first allocation; failure must leave both jobs.
    try source.push(Job{ .request = 10 });
    try source.push(Job{ .request = 11 });
    var failing = std.testing.FailingAllocator.init(std.heap.smp_allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, source.stealHalfWithAllocator(&destination, failing.allocator()));
    try std.testing.expectEqual(@as(usize, 2), source.len());
    try std.testing.expectEqual(@as(usize, 0), destination.len());
    try std.testing.expectEqual(@as(usize, 1), try source.stealHalf(&destination));
    try std.testing.expectEqual(@as(u32, 10), destination.pop().?.request);
    try std.testing.expectEqual(@as(u32, 11), source.pop().?.request);
}

test "a continuously nonempty queue retains storage bounded by its live depth" {
    var queue = JobQueue{};
    defer queue.deinit();
    try queue.push(Job{ .request = 0 });
    try queue.push(Job{ .request = 1 });
    const capacity = queue.items.capacity;
    for (0..10000) |index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), queue.pop().?.request);
        try queue.push(Job{ .request = @intCast(index + 2) });
    }
    try std.testing.expectEqual(@as(usize, 2), queue.len());
    try std.testing.expectEqual(capacity, queue.items.capacity);
}
