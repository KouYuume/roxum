//! Stops a worker with a line naming the request when the request's Roc
//! code overflows its fiber stack. Without it, Linux ends the worker
//! without a word. Like Rust and Go, roxum does not try to keep the worker:
//! the stack may run out while host or libc code holds a lock, which an
//! abandoned fiber would never release.
//!
//! The fault happens where the stack has no room left, so the handler runs
//! on a stack of its own (`installThread`) and only formats into a buffer
//! and writes, which is safe in a signal handler.
const std = @import("std");
const builtin = @import("builtin");
const fiber = @import("fiber.zig");
const request_debug = @import("request_debug.zig");

// `_exit` skips atexit handlers and stdio flushing, as `diagnostics.fatal`.
extern "c" fn _exit(status: c_int) noreturn;

/// Room for the handler: the line it formats and the calls it makes.
const signal_stack_bytes: usize = 64 * 1024;

comptime {
    std.debug.assert(fiber.slot_bytes == 64 * 1024 * 1024);
}
const message = "stack overflow: the request's Roc code went deeper than its 64 MiB stack; the worker stops";

/// Takes SIGSEGV and SIGBUS for the process (macOS reports a guard page as
/// either). Each thread that runs fibers also calls `installThread`.
pub fn installProcess() void {
    const action = std.posix.Sigaction{
        .handler = .{ .sigaction = handleFault },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK,
    };
    std.posix.sigaction(std.posix.SIG.SEGV, &action, null);
    std.posix.sigaction(std.posix.SIG.BUS, &action, null);
}

/// Gives this thread the stack the handler runs on. The thread keeps it
/// for as long as it lives.
pub fn installThread() error{OutOfMemory}!void {
    const memory = std.heap.page_allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(std.heap.page_size_min), signal_stack_bytes) catch
        return error.OutOfMemory;
    var stack: std.posix.stack_t = undefined;
    stack.sp = memory.ptr;
    stack.size = @intCast(memory.len);
    stack.flags = 0;
    std.posix.sigaltstack(&stack, null) catch {
        std.heap.page_allocator.free(memory);
        return error.OutOfMemory;
    };
}

fn handleFault(signal: std.posix.SIG, info: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(std.builtin.CallingConvention.c) void {
    if (fiber.overflowAt(faultAddress(info))) |overflow| {
        var buffer: [1024]u8 = undefined;
        const label = if (overflow.fiber) |target| labelOf(target) else null;
        if (request_debug.formatLine(&buffer, "roxum host fatal: ", std.c.getpid(), label, message)) |line| {
            _ = std.c.write(std.posix.STDERR_FILENO, line.ptr, line.len);
        }
        _exit(1);
    }
    // Any other fault keeps the system's default: the instruction faults
    // again on return, and the process ends as it would without roxum.
    const default = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(signal, &default, null);
}

fn labelOf(target: *fiber.Fiber) ?*const request_debug.Label {
    return target.locals.debug.currentLabel();
}

fn faultAddress(info: *const std.posix.siginfo_t) usize {
    return switch (builtin.os.tag) {
        std.Target.Os.Tag.linux => @intFromPtr(info.fields.sigfault.addr),
        std.Target.Os.Tag.macos => @intFromPtr(info.addr),
        else => @compileError("unsupported operating system"),
    };
}
