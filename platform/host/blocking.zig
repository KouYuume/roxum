//! Work that blocks its thread, such as reading a file, done on threads of
//! its own. A regular file cannot be waited for with epoll or kqueue:
//! a read that misses the page cache waits for the disk inside the system
//! call. On a request fiber only the fiber waits for the job, and the Roc
//! thread serves other requests (tokio's `spawn_blocking`); off a fiber, as
//! in `init!`, the job runs on the spot.
const std = @import("std");
const fiber = @import("fiber.zig");
const fiber_wait = @import("fiber_wait.zig");
const sync = @import("sync.zig");

/// Threads that run jobs, started the first time a job waits on a fiber.
/// Jobs are short (a read of at most a buffer, a compression step), so a
/// few threads keep the disk and the CPUs busy without many idle stacks.
const thread_count = 4;

pub const Job = struct {
    run: *const fn (job: *Job) void,
    /// The fiber waiting for the job, and the wait it is in, for the thread
    /// to wake it.
    target: *fiber.Fiber = undefined,
    serial: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    next: ?*Job = null,
};

const Queue = struct {
    mutex: sync.Mutex = .{},
    ready: sync.Condition = .{},
    head: ?*Job = null,
    tail: ?*Job = null,
    threads_started: usize = 0,

    /// False when no thread could be started; the caller runs the job.
    fn push(self: *Queue, job: *Job) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.threads_started < thread_count) {
            const thread = std.Thread.spawn(.{}, work, .{self}) catch break;
            thread.detach();
            self.threads_started += 1;
        }
        if (self.threads_started == 0) return false;
        if (self.tail) |tail| tail.next = job else self.head = job;
        self.tail = job;
        self.ready.signal();
        return true;
    }

    fn pop(self: *Queue) *Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.head) |job| {
                self.head = job.next;
                if (self.head == null) self.tail = null;
                job.next = null;
                return job;
            }
            self.ready.wait(&self.mutex);
        }
    }
};

var queue: Queue = .{};

fn work(owner: *Queue) void {
    while (true) {
        const job = owner.pop();
        job.run(job);
        // Read before `done`: once it is set the waiter may free the job.
        const target = job.target;
        const serial = job.serial.load(std.builtin.AtomicOrder.acquire);
        job.done.store(true, std.builtin.AtomicOrder.release);
        fiber_wait.wake(target, serial);
    }
}

/// How long a wait lasts before it looks at `done` again, should the job's
/// wait end without its wake.
const recheck_nanoseconds: u64 = 50 * std.time.ns_per_ms;

/// Runs `job` and returns once it is done. The job always finishes, as it
/// may write to memory its caller owns: while the fiber waits for it, a
/// written body's watch is set aside, and a gone client or a drain
/// is seen at the request's next wait.
pub fn run(job: *Job) void {
    const target = fiber.current() orelse return job.run(job);
    const locals = fiber.currentLocals() orelse unreachable;
    const guard = locals.stream_guard;
    locals.stream_guard = null;
    defer locals.stream_guard = guard;
    job.target = target;
    // The wait below is the next one `waitSocket` numbers. The fiber always
    // enters it, even when the job is already done: a wake that came first
    // is kept for that wait (`Fiber.woken_serial`), and would otherwise end
    // a later wait of the fiber's, such as a write to the client, at once.
    job.serial.store(target.wait_serial + 1, std.builtin.AtomicOrder.release);
    if (!queue.push(job)) return job.run(job);
    _ = fiber_wait.waitSocket(-1, 0, std.math.maxInt(u64));
    while (!job.done.load(std.builtin.AtomicOrder.acquire)) {
        const now = monotonic() orelse 0;
        _ = fiber_wait.waitSocket(-1, 0, now +| recheck_nanoseconds);
    }
}

fn monotonic() ?u64 {
    var now: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &now) != 0) return null;
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

test "off a fiber a job runs on the spot" {
    const Counter = struct {
        job: Job = .{ .run = step },
        count: u32 = 0,

        fn step(job: *Job) void {
            const self: *@This() = @fieldParentPtr("job", job);
            self.count += 1;
        }
    };
    var counter = Counter{};
    run(&counter.job);
    try std.testing.expectEqual(@as(u32, 1), counter.count);
}
