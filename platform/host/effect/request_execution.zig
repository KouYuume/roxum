//! Current-request execution controls. The owner callback serializes deadline
//! changes with expiry and response commitment; no transport pointers reach Roc.
const std = @import("std");
const abi = @import("../roc_platform_abi.zig");
const fiber = @import("../fiber.zig");
const fiber_wait = @import("../fiber_wait.zig");

pub const Active = struct {
    context: *anyopaque,
    /// Null duration reads elapsed time; a duration also tightens the deadline.
    /// Null result means execution ended and must not return to application code.
    apply: *const fn (*anyopaque, ?u64) ?u64,
};

fn active() ?Active {
    const locals = fiber.currentLocals() orelse return null;
    return locals.request_execution;
}

fn apply(current: Active, duration: ?u64) u64 {
    if (current.apply(current.context, duration)) |elapsed| return elapsed;
    const target = fiber.current() orelse unreachable;
    _ = target.stop.cmpxchgStrong(fiber.Stop.none, fiber.Stop.client_gone, std.builtin.AtomicOrder.acq_rel, std.builtin.AtomicOrder.acquire);
    fiber_wait.cancelCurrent();
}

pub fn hostedElapsed() callconv(std.builtin.CallingConvention.c) abi.HostRequestExecutionElapsed {
    var result = std.mem.zeroes(abi.HostRequestExecutionElapsed);
    const current = active() orelse {
        result.tag = abi.HostRequestExecutionElapsedTag.Unavailable;
        return result;
    };
    const elapsed = apply(current, null);
    result.tag = abi.HostRequestExecutionElapsedTag.Elapsed;
    const payload: *u64 = @ptrCast(@alignCast(&result.payload));
    payload.* = elapsed;
    return result;
}

pub fn hostedLimit(duration: u64) callconv(std.builtin.CallingConvention.c) bool {
    const current = active() orelse return false;
    _ = apply(current, duration);
    return true;
}

test "execution controls are unavailable outside a request fiber" {
    try std.testing.expectEqual(abi.HostRequestExecutionElapsedTag.Unavailable, hostedElapsed().tag);
    try std.testing.expect(!hostedLimit(0));
    try std.testing.expect(!hostedLimit(std.math.maxInt(u64)));
}

test "execution controls follow their fiber and stop without returning after closure" {
    const Probe = struct {
        elapsed: ?u64,
        seen: [2]u64 = @splat(0),
        limit: ?u64 = null,
        returned: bool = false,

        fn control(ptr: *anyopaque, duration: ?u64) ?u64 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (duration) |value| self.limit = value;
            return self.elapsed;
        }

        fn run(target: *fiber.Fiber) void {
            const self: *@This() = @ptrCast(@alignCast(target.userdata.?));
            target.locals.request_execution = .{ .context = self, .apply = control };
            const first = hostedElapsed();
            self.seen[0] = first.payload.elapsed;
            fiber.suspendCurrent();
            const second = hostedElapsed();
            self.seen[1] = second.payload.elapsed;
            self.returned = hostedLimit(std.math.maxInt(u64));
        }

        fn reused(target: *fiber.Fiber) void {
            const self: *@This() = @ptrCast(@alignCast(target.userdata.?));
            self.returned = hostedElapsed().tag == abi.HostRequestExecutionElapsedTag.Unavailable and !hostedLimit(0);
        }
    };
    var live = Probe{ .elapsed = std.math.maxInt(u64) };
    var closing = Probe{ .elapsed = 7 };
    const a = try fiber.Fiber.create();
    defer a.destroy();
    const b = try fiber.Fiber.create();
    defer b.destroy();
    a.prepare(Probe.run, &live);
    b.prepare(Probe.run, &closing);
    fiber.resumeFiber(a);
    fiber.resumeFiber(b);
    closing.elapsed = null;
    fiber.resumeFiber(b);
    fiber.resumeFiber(a);
    try std.testing.expectEqualSlices(u64, &.{ std.math.maxInt(u64), std.math.maxInt(u64) }, &live.seen);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), live.limit);
    try std.testing.expect(live.returned and a.finished and !a.cancelled);
    try std.testing.expect(b.cancelled and b.finished and !closing.returned);
    try std.testing.expectEqual(@as(u64, 7), closing.seen[0]);
    b.prepare(Probe.reused, &closing);
    fiber.resumeFiber(b);
    try std.testing.expect(closing.returned and b.finished and !b.cancelled);
    try std.testing.expectEqual(abi.HostRequestExecutionElapsedTag.Unavailable, hostedElapsed().tag);
}
