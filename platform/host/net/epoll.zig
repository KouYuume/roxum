const std = @import("std");
const errno = @import("errno.zig");

const linux = std.os.linux;
const EPOLL = linux.EPOLL;
const E = std.c.E;

extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buffer: *anyopaque, length: usize) isize;
extern "c" fn write(fd: c_int, buffer: *const anyopaque, length: usize) isize;

pub const Error = error{
    PollerCreateFailed,
    PollerChangeFailed,
    PollerWaitFailed,
};

/// The kernel's event record; `wait` reads into a caller-owned buffer.
pub const RawEvent = linux.epoll_event;

/// One epoll record can report a socket readable and writable at once; it
/// becomes two events.
pub const events_per_raw: usize = 2;

pub const Event = struct {
    pub const Kind = enum {
        readable,
        writable,
        timer,
        wake,
    };

    kind: Kind,
    /// The token given when the source was registered.
    token: u64,
    /// For a readable socket: the peer closed its side or the connection
    /// failed (`EPOLLRDHUP`, `EPOLLHUP`, `EPOLLERR`; kqueue's `EV_EOF`). Bytes
    /// may still be there to read.
    hangup: bool = false,
};

const socket_readable: u32 = EPOLL.IN | EPOLL.RDHUP | EPOLL.ET;
const socket_readable_writable: u32 = socket_readable | EPOLL.OUT;

/// Thin epoll wrapper for one event loop thread, with the same interface as
/// `kqueue.zig`. Sockets are edge-triggered, so the owner must read until the
/// socket would block. The timer is a `timerfd` and the wake source an
/// `eventfd`; the tokens given for them must differ from every socket token.
pub const Poller = struct {
    epoll: c_int,
    timer: c_int = -1,
    timer_token: u64 = 0,
    wake_source: c_int = -1,
    wake_token: u64 = 0,

    pub fn init() Error!Poller {
        const epoll = std.c.epoll_create1(EPOLL.CLOEXEC);
        if (epoll == -1) return error.PollerCreateFailed;
        return .{ .epoll = epoll };
    }

    pub fn deinit(self: *Poller) void {
        if (self.timer != -1) _ = close(self.timer);
        if (self.wake_source != -1) _ = close(self.wake_source);
        _ = close(self.epoll);
    }

    pub fn watchReadable(self: *Poller, fd: c_int, token: u64) Error!void {
        try self.control(EPOLL.CTL_ADD, fd, socket_readable, token);
    }

    /// Reports when the socket's send buffer has room; edge-triggered. The
    /// socket must already be watched for reading: epoll keeps one interest
    /// set per descriptor, so this widens it.
    pub fn watchWritable(self: *Poller, fd: c_int, token: u64) Error!void {
        try self.control(EPOLL.CTL_MOD, fd, socket_readable_writable, token);
    }

    /// Reports `fd` once, readable or writable, then disarms it: for a
    /// request fiber waiting on an outbound socket. A descriptor
    /// left registered by an earlier one is re-armed.
    pub fn watchOnce(self: *Poller, fd: c_int, readable: bool, token: u64) Error!void {
        const direction: u32 = if (readable) EPOLL.IN | EPOLL.RDHUP else EPOLL.OUT;
        const interest: u32 = direction | EPOLL.ONESHOT;
        var event = RawEvent{ .events = interest, .data = .{ .u64 = token } };
        if (std.c.epoll_ctl(self.epoll, EPOLL.CTL_MOD, fd, &event) == 0) return;
        if (errno.lastError() != E.NOENT) return error.PollerChangeFailed;
        try self.control(EPOLL.CTL_ADD, fd, interest, token);
    }

    /// Forgets a `watchOnce` registration.
    pub fn unwatchOnce(self: *Poller, fd: c_int, readable: bool) Error!void {
        _ = readable;
        var event = RawEvent{ .events = 0, .data = .{ .u64 = 0 } };
        if (std.c.epoll_ctl(self.epoll, EPOLL.CTL_DEL, fd, &event) == 0) return;
        if (errno.lastError() == E.NOENT) return;
        return error.PollerChangeFailed;
    }

    /// Stops watching `fd`. Needed before closing a descriptor another
    /// process shares, such as the listener: epoll keeps the registration
    /// until every descriptor for the socket is closed.
    pub fn unwatchReadable(self: *Poller, fd: c_int) Error!void {
        var event = RawEvent{ .events = 0, .data = .{ .u64 = 0 } };
        if (std.c.epoll_ctl(self.epoll, EPOLL.CTL_DEL, fd, &event) == 0) return;
        if (errno.lastError() == E.NOENT) return;
        return error.PollerChangeFailed;
    }

    /// Puts back a socket's `watchReadable` registration after a `watchOnce`
    /// on the same socket, which epoll keeps as the one interest set of the
    /// descriptor: a request fiber reading from or writing to its client.
    /// A timed-out wait may have removed the registration entirely.
    /// Edge-triggered as before; epoll reports the socket at once if
    /// it is already readable.
    pub fn restoreReadable(self: *Poller, fd: c_int, token: u64) Error!void {
        var event = RawEvent{ .events = socket_readable, .data = .{ .u64 = token } };
        if (std.c.epoll_ctl(self.epoll, EPOLL.CTL_MOD, fd, &event) == 0) return;
        if (errno.lastError() != E.NOENT) return error.PollerChangeFailed;
        try self.control(EPOLL.CTL_ADD, fd, socket_readable, token);
    }

    /// Narrows the interest back to reading. epoll replaces the token on
    /// every modification, so the caller passes it again.
    pub fn unwatchWritable(self: *Poller, fd: c_int, token: u64) Error!void {
        var event = RawEvent{ .events = socket_readable, .data = .{ .u64 = token } };
        if (std.c.epoll_ctl(self.epoll, EPOLL.CTL_MOD, fd, &event) == 0) return;
        if (errno.lastError() == E.NOENT) return;
        return error.PollerChangeFailed;
    }

    /// Arms the loop's timer to fire every `milliseconds`.
    pub fn armRepeatingTimer(self: *Poller, milliseconds: u64, token: u64) Error!void {
        std.debug.assert(self.timer == -1);
        std.debug.assert(milliseconds > 0);
        const flags: linux.TFD = .{ .CLOEXEC = true, .NONBLOCK = true };
        const timer = std.c.timerfd_create(linux.timerfd_clockid_t.MONOTONIC, @bitCast(flags));
        if (timer == -1) return error.PollerChangeFailed;
        errdefer _ = close(timer);

        const interval = linux.timespec{
            .sec = @intCast(milliseconds / std.time.ms_per_s),
            .nsec = @intCast((milliseconds % std.time.ms_per_s) * std.time.ns_per_ms),
        };
        const schedule = linux.itimerspec{ .it_interval = interval, .it_value = interval };
        if (std.c.timerfd_settime(timer, 0, &schedule, null) == -1) return error.PollerChangeFailed;
        try self.control(EPOLL.CTL_ADD, timer, EPOLL.IN, token);
        self.timer = timer;
        self.timer_token = token;
    }

    /// Registers the event another thread can trigger with `wake`.
    pub fn registerWake(self: *Poller, token: u64) Error!void {
        std.debug.assert(self.wake_source == -1);
        const wake_source = std.c.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (wake_source == -1) return error.PollerChangeFailed;
        errdefer _ = close(wake_source);
        try self.control(EPOLL.CTL_ADD, wake_source, EPOLL.IN, token);
        self.wake_source = wake_source;
        self.wake_token = token;
    }

    /// Wakes the loop from any thread.
    pub fn wake(self: *Poller) Error!void {
        const increment: u64 = 1;
        while (true) {
            if (write(self.wake_source, &increment, @sizeOf(u64)) == @sizeOf(u64)) return;
            switch (errno.lastError()) {
                E.INTR => continue,
                // The counter is saturated, so a wake is already pending.
                E.AGAIN => return,
                else => return error.PollerChangeFailed,
            }
        }
    }

    /// Blocks until at least one event is ready. An interrupted wait returns
    /// no events.
    /// Waits for events, at most `milliseconds` when given.
    pub fn wait(
        self: *Poller,
        raw: []RawEvent,
        events: []Event,
        milliseconds: ?u32,
    ) Error![]Event {
        std.debug.assert(events.len >= raw.len * events_per_raw);
        const count = std.c.epoll_wait(self.epoll, raw.ptr, @intCast(raw.len), if (milliseconds) |value| @intCast(value) else -1);
        if (count == -1) {
            if (errno.lastError() == E.INTR) return events[0..0];
            return error.PollerWaitFailed;
        }
        var ready: usize = 0;
        for (raw[0..@intCast(count)]) |item| {
            const token = item.data.u64;
            if (self.timer != -1 and token == self.timer_token) {
                drain(self.timer);
                events[ready] = .{ .kind = Event.Kind.timer, .token = token };
                ready += 1;
                continue;
            }
            if (self.wake_source != -1 and token == self.wake_token) {
                drain(self.wake_source);
                events[ready] = .{ .kind = Event.Kind.wake, .token = token };
                ready += 1;
                continue;
            }
            // Errors and hang-ups are reported to both directions, as kqueue
            // reports EV_EOF on whichever filter is registered.
            const failed = (item.events & (EPOLL.ERR | EPOLL.HUP)) != 0;
            if (failed or (item.events & (EPOLL.IN | EPOLL.RDHUP)) != 0) {
                events[ready] = .{ .kind = Event.Kind.readable, .token = token, .hangup = failed or (item.events & EPOLL.RDHUP) != 0 };
                ready += 1;
            }
            if (failed or (item.events & EPOLL.OUT) != 0) {
                events[ready] = .{ .kind = Event.Kind.writable, .token = token };
                ready += 1;
            }
        }
        return events[0..ready];
    }

    fn control(self: *Poller, operation: u32, fd: c_int, interest: u32, token: u64) Error!void {
        var event = RawEvent{ .events = interest, .data = .{ .u64 = token } };
        if (std.c.epoll_ctl(self.epoll, operation, fd, &event) == -1) return error.PollerChangeFailed;
    }
};

/// Resets a timerfd or eventfd counter so a level-triggered source stops
/// reporting until it fires again.
fn drain(fd: c_int) void {
    var count: u64 = undefined;
    while (read(fd, &count, @sizeOf(u64)) == -1 and errno.lastError() == E.INTR) {}
}

test "repeating timer fires with its token" {
    var poller = try Poller.init();
    defer poller.deinit();
    try poller.armRepeatingTimer(1, 0xabc);

    var raw: [4]RawEvent = undefined;
    var events: [4 * events_per_raw]Event = undefined;
    var fired: usize = 0;
    while (fired < 2) {
        for (try poller.wait(&raw, &events, null)) |event| {
            try std.testing.expectEqual(Event.Kind.timer, event.kind);
            try std.testing.expectEqual(@as(u64, 0xabc), event.token);
            fired += 1;
        }
    }
}

test "wake from another thread reaches the loop" {
    var poller = try Poller.init();
    defer poller.deinit();
    try poller.registerWake(0x55);

    const Waker = struct {
        fn run(target: *Poller) void {
            target.wake() catch unreachable;
        }
    };
    const thread = try std.Thread.spawn(.{}, Waker.run, .{&poller});
    defer thread.join();

    var raw: [4]RawEvent = undefined;
    var events: [4 * events_per_raw]Event = undefined;
    const ready = try poller.wait(&raw, &events, null);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(Event.Kind.wake, ready[0].kind);
    try std.testing.expectEqual(@as(u64, 0x55), ready[0].token);
}

test "a socket reports readable, then writable once watched" {
    var poller = try Poller.init();
    defer poller.deinit();
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
    defer _ = close(pair[0]);
    defer _ = close(pair[1]);

    try poller.watchReadable(pair[0], 7);
    const byte: u8 = 1;
    try std.testing.expectEqual(@as(isize, 1), write(pair[1], &byte, 1));

    var raw: [4]RawEvent = undefined;
    var events: [4 * events_per_raw]Event = undefined;
    var ready = try poller.wait(&raw, &events, null);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(Event.Kind.readable, ready[0].kind);
    try std.testing.expectEqual(@as(u64, 7), ready[0].token);

    try poller.watchWritable(pair[0], 7);
    ready = try poller.wait(&raw, &events, null);
    var saw_writable = false;
    for (ready) |event| {
        try std.testing.expectEqual(@as(u64, 7), event.token);
        if (event.kind == Event.Kind.writable) saw_writable = true;
    }
    try std.testing.expect(saw_writable);
    try poller.unwatchWritable(pair[0], 7);
}
test "a one-shot watch reports once and can be withdrawn" {
    var poller = try Poller.init();
    defer poller.deinit();
    var ends: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &ends));
    defer _ = close(ends[0]);
    defer _ = close(ends[1]);
    var raw: [4]RawEvent = undefined;
    var events: [4 * events_per_raw]Event = undefined;

    try poller.watchOnce(ends[0], true, 0x51);
    _ = std.c.write(ends[1], "x", 1);
    const first = try poller.wait(&raw, &events, 100);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqual(@as(u64, 0x51), first[0].token);
    // Fired once: still readable, but nothing more is reported.
    try std.testing.expectEqual(@as(usize, 0), (try poller.wait(&raw, &events, 0)).len);

    try poller.watchOnce(ends[0], true, 0x52);
    try poller.unwatchOnce(ends[0], true);
    try std.testing.expectEqual(@as(usize, 0), (try poller.wait(&raw, &events, 0)).len);
    try poller.unwatchOnce(ends[0], true);
}

test "restore readable after a fired or cancelled one-shot keeps reporting new data" {
    for ([_]bool{ false, true }) |cancelled| {
        var poller = try Poller.init();
        defer poller.deinit();
        var pair: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
        defer _ = close(pair[0]);
        defer _ = close(pair[1]);
        var raw: [4]RawEvent = undefined;
        var events: [4 * events_per_raw]Event = undefined;
        var byte: [1]u8 = undefined;
        try poller.watchReadable(pair[0], 7);
        try poller.watchOnce(pair[0], true, 9);
        if (cancelled) {
            try poller.unwatchOnce(pair[0], true);
        } else {
            try std.testing.expectEqual(@as(isize, 1), std.c.write(pair[1], "x", 1));
            const ready = try poller.wait(&raw, &events, 100);
            try std.testing.expectEqual(@as(usize, 1), ready.len);
            try std.testing.expectEqual(@as(u64, 9), ready[0].token);
            try std.testing.expectEqual(@as(isize, 1), std.c.read(pair[0], &byte, 1));
        }
        try poller.restoreReadable(pair[0], 7);
        // It must remain persistent, not merely wake the next request once.
        for (0..2) |_| {
            try std.testing.expectEqual(@as(isize, 1), std.c.write(pair[1], "y", 1));
            const ready = try poller.wait(&raw, &events, 100);
            try std.testing.expectEqual(@as(usize, 1), ready.len);
            try std.testing.expectEqual(@as(u64, 7), ready[0].token);
            try std.testing.expectEqual(Event.Kind.readable, ready[0].kind);
            try std.testing.expectEqual(@as(isize, 1), std.c.read(pair[0], &byte, 1));
        }
    }
}
