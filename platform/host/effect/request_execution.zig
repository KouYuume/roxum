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
    decode_response: ?abi.HttpResponse = null,
    on_decode_exhausted: ?*const fn (*anyopaque, abi.HttpResponse) void = null,
    limit_trailers: ?*const fn (*anyopaque, u64, []const abi.HttpResponseHeader) u8 = null,
    limit_response: ?*const fn (*anyopaque, u64, abi.HttpResponse, *abi.RocHost) Result = null,
};

pub const Result = enum { installed, invalid, closed };

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

pub fn hostedBeginDecode(bytes: abi.RocListWith(u8, false)) callconv(std.builtin.CallingConvention.c) abi.HostRequestExecutionDecodeInput {
    const allocator_context = @import("../allocator/context.zig");
    const runtime = @import("../runtime.zig");
    const context = allocator_context.current() orelse @panic("allocator context is not set");
    var host = runtime.makeRocHost(@ptrCast(context.host_allocator));
    defer bytes.decref(&host);
    var result = std.mem.zeroes(abi.HostRequestExecutionDecodeInput);
    result.tag = abi.HostRequestExecutionDecodeInputTag.Unavailable;
    if (active() == null) return result;
    allocator_context.beginDecode() catch |err| {
        if (err == error.OutOfMemory) result.tag = abi.HostRequestExecutionDecodeInputTag.Exhausted;
        return result;
    };
    // A decoder may return its input or a slice of it without allocating.
    const copy = @import("../bridge/request.zig").rocByteListFromSliceChecked(bytes.items(), .{
        .roc_host = &host,
        .try_alloc = runtime.tryAllocWithHost,
    }) catch {
        allocator_context.endDecode();
        result.tag = abi.HostRequestExecutionDecodeInputTag.Exhausted;
        return result;
    };
    result.tag = abi.HostRequestExecutionDecodeInputTag.Input;
    const payload: *abi.RocListWith(u8, false) = @ptrCast(@alignCast(&result.payload));
    payload.* = copy;
    return result;
}

pub fn hostedBeginDecodeWithResponse(bytes: abi.RocListWith(u8, false), response: abi.HttpResponse) callconv(std.builtin.CallingConvention.c) abi.HostRequestExecutionDecodeInput {
    const result = hostedBeginDecode(bytes);
    if (result.tag == abi.HostRequestExecutionDecodeInputTag.Input) {
        fiber.currentLocals().?.request_execution.?.decode_response = response;
    } else releaseResponse(response);
    return result;
}

fn releaseResponse(response: abi.HttpResponse) void {
    const context = @import("../allocator/context.zig").current().?;
    var host = @import("../runtime.zig").makeRocHost(@ptrCast(context.host_allocator));
    response.decref(&host);
}

fn takeDecodeResponse() ?abi.HttpResponse {
    const locals = fiber.currentLocals() orelse return null;
    const execution = if (locals.request_execution) |*value| value else return null;
    const response = execution.decode_response;
    execution.decode_response = null;
    return response;
}

pub fn discardDecodeResponse() void {
    if (takeDecodeResponse()) |response| releaseResponse(response);
}

pub fn decodeExhausted() void {
    const response = takeDecodeResponse() orelse return;
    @import("../allocator/context.zig").endDecode();
    const execution = active().?;
    if (execution.on_decode_exhausted) |send| {
        send(execution.context, response);
        fiber_wait.abandonCurrent();
    }
    releaseResponse(response);
}

pub fn hostedEndDecode() callconv(std.builtin.CallingConvention.c) void {
    discardDecodeResponse();
    @import("../allocator/context.zig").endDecode();
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

pub fn hostedLimitWithResponse(duration: u64, response: abi.HttpResponse) callconv(std.builtin.CallingConvention.c) u8 {
    const context = @import("../allocator/context.zig").current() orelse @panic("allocator context is not set");
    var roc_host = @import("../runtime.zig").makeRocHost(@ptrCast(context.host_allocator));
    const current = active();
    if (current) |value| {
        if (value.limit_response) |callback| {
            // The callback consumes the response before cancellation can abandon
            // the fiber stack. No deferred Roc cleanup may follow this point.
            switch (callback(value.context, duration, response, &roc_host)) {
                Result.installed => return 0,
                Result.invalid => return 2,
                Result.closed => {
                    const target = fiber.current() orelse unreachable;
                    _ = target.stop.cmpxchgStrong(fiber.Stop.none, fiber.Stop.client_gone, std.builtin.AtomicOrder.acq_rel, std.builtin.AtomicOrder.acquire);
                    fiber_wait.cancelCurrent();
                },
            }
        }
    }
    response.decref(&roc_host);
    return 1;
}

pub fn hostedLimitWithTrailers(duration: u64, trailers: abi.RocList(abi.HttpResponseHeader)) callconv(std.builtin.CallingConvention.c) u8 {
    const context = @import("../allocator/context.zig").current() orelse @panic("allocator context is not set");
    var roc_host = @import("../runtime.zig").makeRocHost(@ptrCast(context.host_allocator));
    const result: u8 = if (active()) |current| if (current.limit_trailers) |callback| callback(current.context, duration, trailers.items()) else 1 else 1;
    abi.decrefListOfHttpResponseHeader(trailers, &roc_host);
    if (result == 3) {
        const target = fiber.current() orelse unreachable;
        _ = target.stop.cmpxchgStrong(fiber.Stop.none, fiber.Stop.client_gone, std.builtin.AtomicOrder.acq_rel, std.builtin.AtomicOrder.acquire);
        fiber_wait.cancelCurrent();
    }
    return result;
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
