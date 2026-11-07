const std = @import("std");
const errno = @import("errno.zig");

const Kevent = std.c.Kevent;
const EVFILT = std.c.EVFILT;
const EV = std.c.EV;
const NOTE = std.c.NOTE;

const E = std.c.E;

/// Kernel identifiers of the loop's single timer and wake event.
const tick_id: usize = 0;
const wake_id: usize = 0;

extern "c" fn close(fd: c_int) c_int;

pub const Error = error{
    PollerCreateFailed,
    PollerChangeFailed,
    PollerWaitFailed,
};

/// The kernel's event record; `wait` reads into a caller-owned buffer.
pub const RawEvent = Kevent;

/// kqueue reports readable and writable separately, one event per record.
pub const events_per_raw: usize = 1;

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

/// Thin kqueue wrapper for one event loop thread. Readable sources are
/// edge-triggered, so the owner must read until the socket would block.
pub const Poller = struct {
    queue: c_int,
    /// Triggering a user event also rewrites its udata, so `wake` resends
    /// the token given at registration.
    wake_token: u64 = 0,

    pub fn init() Error!Poller {
        const queue = std.c.kqueue();
        if (queue == -1) return error.PollerCreateFailed;
        return .{ .queue = queue };
    }

    pub fn deinit(self: *Poller) void {
        _ = close(self.queue);
    }

    /// A readable watchOnce replaces the persistent READ filter. Reinstall
    /// it after a request fiber used the client socket, even if it timed out.
    pub fn restoreReadable(self: *Poller, fd: c_int, token: u64) Error!void {
        try self.watchReadable(fd, token);
    }

    pub fn watchReadable(self: *Poller, fd: c_int, token: u64) Error!void {
        try self.apply(change(
            @intCast(fd),
            EVFILT.READ,
            EV.ADD | EV.CLEAR,
            0,
            0,
            token,
        ));
    }

    /// Reports when the socket's send buffer has room; edge-triggered.
    pub fn watchWritable(self: *Poller, fd: c_int, token: u64) Error!void {
        try self.apply(change(
            @intCast(fd),
            EVFILT.WRITE,
            EV.ADD | EV.CLEAR,
            0,
            0,
            token,
        ));
    }

    /// Reports `fd` once, readable or writable, then forgets it: for a
    /// request fiber waiting on an outbound socket.
    pub fn watchOnce(self: *Poller, fd: c_int, readable: bool, token: u64) Error!void {
        try self.apply(change(@intCast(fd), if (readable) EVFILT.READ else EVFILT.WRITE, EV.ADD | EV.ONESHOT, 0, 0, token));
    }

    /// Forgets a `watchOnce` that has not fired.
    pub fn unwatchOnce(self: *Poller, fd: c_int, readable: bool) Error!void {
        try self.applyIgnoringMissing(change(@intCast(fd), if (readable) EVFILT.READ else EVFILT.WRITE, EV.DELETE, 0, 0, 0));
    }

    /// Stops watching `fd` for reading.
    pub fn unwatchReadable(self: *Poller, fd: c_int) Error!void {
        try self.applyIgnoringMissing(change(
            @intCast(fd),
            EVFILT.READ,
            EV.DELETE,
            0,
            0,
            0,
        ));
    }

    /// `token` is unused; epoll needs it to keep the socket's reading token.
    pub fn unwatchWritable(self: *Poller, fd: c_int, token: u64) Error!void {
        _ = token;
        try self.applyIgnoringMissing(change(
            @intCast(fd),
            EVFILT.WRITE,
            EV.DELETE,
            0,
            0,
            0,
        ));
    }

    /// Arms the loop's timer to fire every `milliseconds`.
    pub fn armRepeatingTimer(self: *Poller, milliseconds: u64, token: u64) Error!void {
        try self.apply(change(
            tick_id,
            EVFILT.TIMER,
            EV.ADD,
            0,
            @intCast(@min(milliseconds, @as(u64, std.math.maxInt(isize)))),
            token,
        ));
    }

    /// Registers a user event another thread can trigger with `wake`.
    pub fn registerWake(self: *Poller, token: u64) Error!void {
        self.wake_token = token;
        try self.apply(change(
            wake_id,
            EVFILT.USER,
            EV.ADD | EV.CLEAR,
            0,
            0,
            token,
        ));
    }

    /// Wakes the loop from any thread.
    pub fn wake(self: *Poller) Error!void {
        try self.apply(change(
            wake_id,
            EVFILT.USER,
            0,
            NOTE.TRIGGER,
            0,
            self.wake_token,
        ));
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
        var limit: std.c.timespec = undefined;
        if (milliseconds) |value| limit = .{ .sec = @intCast(value / 1000), .nsec = @intCast(@as(u64, value % 1000) * std.time.ns_per_ms) };
        const count = std.c.kevent(
            self.queue,
            raw.ptr,
            0,
            raw.ptr,
            @intCast(raw.len),
            if (milliseconds != null) &limit else null,
        );
        if (count == -1) {
            if (errno.lastError() == E.INTR) return events[0..0];
            return error.PollerWaitFailed;
        }
        const ready: usize = @intCast(count);
        for (raw[0..ready], events[0..ready]) |item, *event| {
            event.* = .{
                .kind = switch (item.filter) {
                    EVFILT.READ => Event.Kind.readable,
                    EVFILT.WRITE => Event.Kind.writable,
                    EVFILT.TIMER => Event.Kind.timer,
                    EVFILT.USER => Event.Kind.wake,
                    else => unreachable,
                },
                .token = item.udata,
                .hangup = item.filter == EVFILT.READ and (item.flags & EV.EOF) != 0,
            };
        }
        return events[0..ready];
    }

    fn apply(self: *Poller, item: Kevent) Error!void {
        if (!self.submit(item)) return error.PollerChangeFailed;
    }

    fn applyIgnoringMissing(self: *Poller, item: Kevent) Error!void {
        if (self.submit(item)) return;
        if (errno.lastError() == E.NOENT) return;
        return error.PollerChangeFailed;
    }

    fn submit(self: *Poller, item: Kevent) bool {
        const changes = [1]Kevent{item};
        while (true) {
            var unused: [1]Kevent = undefined;
            if (std.c.kevent(
                self.queue,
                &changes,
                1,
                &unused,
                0,
                null,
            ) != -1) return true;
            if (errno.lastError() != E.INTR) return false;
        }
    }
};

fn change(
    ident: usize,
    filter: i16,
    flags: u16,
    fflags: u32,
    data: isize,
    udata: u64,
) Kevent {
    return .{
        .ident = ident,
        .filter = filter,
        .flags = flags,
        .fflags = fflags,
        .data = data,
        .udata = udata,
    };
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
