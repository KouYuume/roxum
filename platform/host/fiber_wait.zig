//! Waiting for a socket on a request fiber. The fiber suspends, keeping the
//! request's state in its own `Locals`, and the Roc thread serves other
//! requests until the socket is ready or the deadline passes.
const std = @import("std");
const allocator_context = @import("allocator/context.zig");
const fiber = @import("fiber.zig");
const net = @import("net.zig");
const scheduler = @import("scheduler.zig");

pub const Outcome = fiber.Wait.Outcome;

/// The process's waiting fibers, once the Roc threads run.
pub var waits: ?*scheduler.Waits = null;

/// The `net.tcp.fiber_wait` hook.
pub fn waitSocketHook(socket: c_int, events: i16, expires_at_nanoseconds: u64) ?net.FiberWait {
    const outcome = waitSocket(socket, events, expires_at_nanoseconds) orelse return null;
    return switch (outcome) {
        Outcome.ready => net.FiberWait.ready,
        Outcome.timed_out => net.FiberWait.timed_out,
    };
}

/// Suspends the running request fiber until `socket` reports any of the
/// `poll` events, an error, or a hang-up, or until the deadline passes.
/// Returns null off a fiber (the loop thread, or code the scheduler does not
/// run), where the caller waits by itself.
pub fn waitSocket(socket: c_int, events: i16, expires_at_nanoseconds: u64) ?Outcome {
    const target = fiber.current() orelse return null;
    const locals = fiber.currentLocals() orelse unreachable;
    if (socket >= 0 and socket == locals.client_socket) {
        if (locals.client_watch_replaced) |replaced| replaced.* = true;
    }
    const guard = (fiber.currentLocals() orelse unreachable).stream_guard orelse {
        target.wait_serial += 1;
        target.wait = .{
            .socket = socket,
            .events = events,
            .expires_at_nanoseconds = expires_at_nanoseconds,
        };
        fiber.suspendCurrent();
        return target.wait.outcome;
    };
    return waitGuarded(target, guard, socket, events, expires_at_nanoseconds);
}

/// A wait of a request writing its response body. The connection
/// wakes the fiber if the client goes, or when the worker drains and the
/// body may end then; the wait then ends as timed out, so the
/// effect that waited cleans up what it holds (a socket half connected, a
/// place in a pool) and the request stops as that effect returns to Roc
/// (`stopIfStreamEnds`). When the body has been quiet for the keep-alive
/// interval, the fiber writes the keep-alive bytes and waits again. A wait
/// on the client socket itself (to write the body) puts back the
/// connection's registration after; a drain never stops it, so a part is
/// never cut.
fn waitGuarded(target: *fiber.Fiber, guard: *fiber.StreamGuard, socket: c_int, events: i16, expires_at_nanoseconds: u64) Outcome {
    const own_socket = socket == guard.client_socket;
    const stopping = if (own_socket) fiber.Stop.client_gone else fiber.Stop.drained;
    while (true) {
        // A keep-alive write is itself a part of the body: none goes into
        // the middle of another.
        const beats = guard.keep_alive_nanoseconds != 0 and !guard.writing;
        const beat_at = if (beats) guard.last_write_at +| guard.keep_alive_nanoseconds else std.math.maxInt(u64);
        target.wait_serial += 1;
        // Waiting to write to the client, the connection's registration is
        // replaced by this one (epoll): a gone client fails the wait.
        if (stops(target, stopping)) return Outcome.timed_out;
        if (!own_socket) {
            const stop = guard.arm(guard.context, target, target.wait_serial, guard.ends_on_drain);
            if (stop != fiber.Stop.none) return stopWith(target, stop);
        }
        target.wait = .{
            .socket = socket,
            .events = events,
            .expires_at_nanoseconds = @min(expires_at_nanoseconds, beat_at),
        };
        fiber.suspendCurrent();
        if (own_socket) guard.restore(guard.context) else guard.disarm(guard.context);
        if (stops(target, stopping)) return Outcome.timed_out;
        const outcome = target.wait.outcome;
        if (outcome == Outcome.timed_out and beats and expires_at_nanoseconds > beat_at) {
            const now = net.monotonicNanoseconds() catch return outcome;
            if (now >= beat_at and now < expires_at_nanoseconds) {
                if (!guard.beat(guard.context)) return stopWith(target, fiber.Stop.client_gone);
                continue;
            }
        }
        return outcome;
    }
}

/// Whether the request stops, for a wait that `at_least` stops: a drain
/// stops waits for anything but the client socket.
fn stops(target: *fiber.Fiber, at_least: fiber.Stop) bool {
    const stop = target.stop.load(std.builtin.AtomicOrder.acquire);
    return stop != fiber.Stop.none and @intFromEnum(stop) <= @intFromEnum(at_least);
}

fn stopWith(target: *fiber.Fiber, stop: fiber.Stop) Outcome {
    _ = target.stop.cmpxchgStrong(fiber.Stop.none, stop, std.builtin.AtomicOrder.acq_rel, std.builtin.AtomicOrder.acquire);
    return Outcome.timed_out;
}

/// Stops the running request if its client went while it wrote its body
///, or the worker drains and the body may end then, ending
/// the body cleanly first. Effects that wait call it as they return to
/// Roc, after cleaning up, so nothing they held is left behind.
pub fn stopIfStreamEnds() void {
    const target = fiber.current() orelse return;
    switch (target.stop.load(std.builtin.AtomicOrder.acquire)) {
        fiber.Stop.none => return,
        fiber.Stop.client_gone => {},
        fiber.Stop.drained => if ((fiber.currentLocals() orelse unreachable).stream_guard) |guard| guard.end(guard.context),
    }
    cancelCurrent();
}

/// Wakes a request writing its body, while it waits, to stop it : the wait ends and the request stops as its effect returns. Any
/// thread may call it; `serial` names the wait.
pub fn wakeStopped(target: *fiber.Fiber, serial: u64, stop: fiber.Stop) void {
    _ = stopWith(target, stop);
    wake(target, serial);
}

/// Ends a deadline-only wait at once, as when the connection a request
/// waits for comes back to its pool; any thread may call it. `serial` names
/// the wait (`Fiber.wait_serial` once it started), so a late wake for an
/// earlier wait does nothing. Without the process's waits, as in tests,
/// the wait ends here.
pub fn wake(target: *fiber.Fiber, serial: u64) void {
    if (waits) |set| return set.wake(target, serial);
    if (target.wait_serial != serial) return;
    target.wait.expires_at_nanoseconds = 0;
}

pub fn onFiber() bool {
    return fiber.current() != null;
}

/// Ends the running request fiber because its client went: the
/// fiber suspends for good, and the scheduler cleans up after it as after
/// a crash, without a crash's log.
pub fn cancelCurrent() noreturn {
    const target = fiber.current() orelse unreachable;
    target.cancelled = true;
    target.finished = true;
    fiber.suspendCurrent();
    unreachable;
}

/// Ends the running request fiber after its Roc code crashed: the
/// fiber suspends for good. The scheduler sees `crashed` and cleans up after
/// the request.
pub fn abandonCurrent() noreturn {
    const target = fiber.current() orelse unreachable;
    target.crashed = true;
    target.finished = true;
    fiber.suspendCurrent();
    unreachable;
}

test "off a fiber the caller waits by itself" {
    try std.testing.expectEqual(@as(?Outcome, null), waitSocket(0, 1, 0));
}

test "a waiting fiber keeps its state" {
    const Probe = struct {
        var seen: ?allocator_context.Context = null;
        var outcome: ?Outcome = null;
        fn start(_: *fiber.Fiber) void {
            allocator_context.setCurrent(.{ .host_allocator = undefined, .domain = @import("allocator/domain.zig").Domain.request, .generation = 7 });
            outcome = waitSocket(0, 1, 0);
            seen = allocator_context.current();
            allocator_context.clearCurrent();
        }
    };
    const target = try fiber.Fiber.create();
    defer target.destroy();
    target.prepare(Probe.start, null);
    fiber.resumeFiber(target);
    try std.testing.expect(!target.finished);
    // The scheduler sees no context while the fiber waits.
    try std.testing.expectEqual(@as(?allocator_context.Context, null), allocator_context.current());
    try std.testing.expectEqual(@as(i16, 1), target.wait.events);
    target.wait.outcome = Outcome.timed_out;
    fiber.resumeFiber(target);
    try std.testing.expect(target.finished);
    try std.testing.expectEqual(@as(?Outcome, Outcome.timed_out), Probe.outcome);
    try std.testing.expectEqual(@as(usize, 7), Probe.seen.?.generation);
}
