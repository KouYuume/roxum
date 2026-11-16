//! Runs each request on its own stack so a hosted effect can suspend the
//! handler and let the Roc thread serve other requests (execution-model.md
//! §6).
//!
//! A fiber may be resumed on another thread than the one it suspended on
//!, so code on a fiber never keeps state in a threadlocal: the
//! compiler may compute a threadlocal's address once in a function and use
//! it after the fiber has moved, writing another thread's slot. The state a
//! request carries is in its fiber (`Locals`), and the running fiber is found
//! from the stack pointer: stacks are slots in chunks reserved one at a time,
//! so the address of any frame tells whose stack it is on.
//!
//! The switch is a plain C function that saves the callee-saved registers on
//! the stack it leaves. `std.Io.fiber.contextSwitch` (Zig 0.16 and 0.17)
//! relies on its asm clobber list instead, and LLVM kept a value in x30
//! across that asm, so the scheduler jumped to a stale address after a fiber
//! suspended.
const std = @import("std");
const builtin = @import("builtin");
const allocator_context = @import("allocator/context.zig");
const body_effect = @import("effect/body.zig");
const concurrency_effect = @import("effect/concurrency.zig");
const response_writer = @import("effect/response_writer.zig");
const request_debug = @import("request_debug.zig");
const sync = @import("sync.zig");

/// Each fiber's slot: an inaccessible guard, then the stack. A Roc call level
/// takes about 8.8 KiB of stack in the interpreter, 190 bytes in dev, and
/// 16 bytes in speed, so 64 MiB lets the interpreter
/// recurse about 7,500 levels: code developed on the interpreter rarely
/// overflows where speed would not. Only the pages a handler touches take
/// physical memory.
pub const slot_bytes: usize = 64 * 1024 * 1024;
/// A frame larger than the guard could step over it into the slot below.
/// Host frames reach 17 KiB, past a 16 KiB page; the guard is only address
/// space, so it is made far larger than any frame.
const guard_bytes: usize = 1024 * 1024;
pub const stack_bytes: usize = slot_bytes - guard_bytes;
/// Slots reserved at once: 8 GiB of address space, which takes memory only
/// where a stack is touched.
const chunk_slots: usize = 128;
const chunk_bytes: usize = chunk_slots * slot_bytes;
/// Up to 8,192 fibers in a process.
const maximum_chunks: usize = 64;

const symbol_prefix = if (builtin.os.tag.isDarwin()) "_" else "";

comptime {
    switch (builtin.cpu.arch) {
        // x0: where to store the old stack pointer, x1: the new one.
        .aarch64 => asm (
            \\.text
            \\.p2align 2
            \\.globl
        ++ " " ++ symbol_prefix ++ "roxum_fiber_switch\n" ++ symbol_prefix ++ "roxum_fiber_switch:\n" ++
            \\  sub sp, sp, #160
            \\  stp x19, x20, [sp, #0]
            \\  stp x21, x22, [sp, #16]
            \\  stp x23, x24, [sp, #32]
            \\  stp x25, x26, [sp, #48]
            \\  stp x27, x28, [sp, #64]
            \\  stp x29, x30, [sp, #80]
            \\  stp d8, d9, [sp, #96]
            \\  stp d10, d11, [sp, #112]
            \\  stp d12, d13, [sp, #128]
            \\  stp d14, d15, [sp, #144]
            \\  mov x2, sp
            \\  str x2, [x0]
            \\  mov sp, x1
            \\  ldp x19, x20, [sp, #0]
            \\  ldp x21, x22, [sp, #16]
            \\  ldp x23, x24, [sp, #32]
            \\  ldp x25, x26, [sp, #48]
            \\  ldp x27, x28, [sp, #64]
            \\  ldp x29, x30, [sp, #80]
            \\  ldp d8, d9, [sp, #96]
            \\  ldp d10, d11, [sp, #112]
            \\  ldp d12, d13, [sp, #128]
            \\  ldp d14, d15, [sp, #144]
            \\  add sp, sp, #160
            \\  ret
            \\
            \\.p2align 2
            \\.globl
        ++ " " ++ symbol_prefix ++ "roxum_fiber_entry\n" ++ symbol_prefix ++ "roxum_fiber_entry:\n" ++
            \\  mov x0, x19
            \\  bl
        ++ " " ++ symbol_prefix ++ "roxum_fiber_run\n" ++
            \\  brk #0
            \\
        ),
        // rdi: where to store the old stack pointer, rsi: the new one.
        .x86_64 => asm (
            \\.text
            \\.p2align 4
            \\.globl
        ++ " " ++ symbol_prefix ++ "roxum_fiber_switch\n" ++ symbol_prefix ++ "roxum_fiber_switch:\n" ++
            \\  pushq %rbp
            \\  pushq %rbx
            \\  pushq %r12
            \\  pushq %r13
            \\  pushq %r14
            \\  pushq %r15
            \\  movq %rsp, (%rdi)
            \\  movq %rsi, %rsp
            \\  popq %r15
            \\  popq %r14
            \\  popq %r13
            \\  popq %r12
            \\  popq %rbx
            \\  popq %rbp
            \\  ret
            \\
            \\.p2align 4
            \\.globl
        ++ " " ++ symbol_prefix ++ "roxum_fiber_entry\n" ++ symbol_prefix ++ "roxum_fiber_entry:\n" ++
            \\  movq %rbx, %rdi
            \\  andq $-16, %rsp
            \\  call
        ++ " " ++ symbol_prefix ++ "roxum_fiber_run\n" ++
            \\  ud2
            \\
        ),
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    }
}

extern fn roxum_fiber_switch(old: *usize, new: usize) callconv(.c) void;
extern fn roxum_fiber_entry() callconv(.c) void;

comptime {
    @export(&run, .{ .name = "roxum_fiber_run", .visibility = std.builtin.SymbolVisibility.hidden });
}

/// The frame `roxum_fiber_switch` pops: callee-saved registers, then the
/// return address (aarch64 keeps it in x30, x86_64 on the stack).
const initial_frame_bytes: usize = switch (builtin.cpu.arch) {
    .aarch64 => 160,
    .x86_64 => 7 * @sizeOf(usize),
    else => unreachable,
};

/// The state a request carries with it while it runs on a fiber, which the
/// allocator context, the body effect, and `dbg` and crash labels read in
/// place of their threadlocals.
pub const Locals = struct {
    /// The connection owned by this request; mark its watch when a wait replaces it.
    client_socket: c_int = -1,
    client_watch_replaced: ?*bool = null,
    allocator: ?allocator_context.Context = null,
    body: ?body_effect.Active = null,
    request_execution: ?@import("effect/request_execution.zig").Active = null,
    response: ?response_writer.Active = null,
    /// Set while the request writes its response body: every wait
    /// of the fiber also watches the client.
    stream_guard: ?*StreamGuard = null,
    /// The file the request sends, or -1. Closed when the request
    /// ends, however it ends.
    file: c_int = -1,
    /// The keys the request holds. Given back when the
    /// request ends, however it ends.
    concurrency: concurrency_effect.Held = .{},
    debug: request_debug.State = .{},
};

/// Why a request writing its response body stops at its wait.
pub const Stop = enum(u8) {
    none,
    /// The client went: the connection only closes.
    client_gone,
    /// The worker drains and the body may end then: the body ends
    /// cleanly first.
    drained,
};

/// What the waits of a request writing its response body also do:
/// end the request when the client goes, or when the worker drains and the
/// body may end then, and write the keep-alive bytes when the body
/// has been quiet for the interval.
pub const StreamGuard = struct {
    context: *anyopaque,
    /// The client's socket: a wait on it (to write the body) puts back the
    /// connection's registration after (`restore`).
    client_socket: c_int,
    /// Names the waiting fiber to the connection, which wakes it when the
    /// client goes, or when the worker drains and `ends_on_drain`. `none`
    /// once named; otherwise why the request stops now.
    arm: *const fn (context: *anyopaque, target: *Fiber, serial: u64, ends_on_drain: bool) Stop,
    disarm: *const fn (context: *anyopaque) void,
    restore: *const fn (context: *anyopaque) void,
    /// Writes the keep-alive bytes; false when the body is over.
    beat: *const fn (context: *anyopaque) bool,
    /// Ends the body cleanly, as the request stops for a drain.
    end: *const fn (context: *anyopaque) void,
    /// A drain ends the body.
    ends_on_drain: bool = false,
    /// 0 when nothing is written in quiet times.
    keep_alive_nanoseconds: u64 = 0,
    /// When the body was last written to, for the keep-alive interval.
    last_write_at: u64 = 0,
    /// Set while the body is being written, so the keep-alive bytes never
    /// go into the middle of a part.
    writing: bool = false,
};

pub const Fiber = struct {
    /// The saved stack pointer while the fiber is suspended.
    stack_pointer: usize = 0,
    /// The stack pointer of the scheduler that resumed it, to switch back
    /// to: the fiber may be resumed by another thread each time.
    scheduler_stack_pointer: usize = 0,
    /// The fiber's slot: a guard page, then the stack.
    memory: []align(std.heap.page_size_min) u8,
    start: *const fn (*Fiber) void = undefined,
    userdata: ?*anyopaque = null,
    finished: bool = false,
    /// Set when the fiber's Roc code crashed: it suspended for good,
    /// and the scheduler cleans up after it.
    crashed: bool = false,
    /// Set when the request stopped at a wait while writing its body, as
    /// `stop` says why: the fiber suspended for good, as after
    /// a crash, but nothing is wrong.
    cancelled: bool = false,
    /// Set by the thread that saw the client go or the drain start, before
    /// it wakes the fiber. The first reason stays.
    stop: std.atomic.Value(Stop) = std.atomic.Value(Stop).init(Stop.none),
    /// What a suspended fiber waits for; the scheduler fills in the outcome
    /// before resuming it.
    wait: Wait = .{},
    /// Numbers the fiber's waits. Kept across requests, so a wake meant for
    /// an earlier wait never ends a later one.
    wait_serial: u64 = 0,
    /// Under the thread sanitizer: the fiber as it knows it, and the
    /// scheduler's that resumed it last (`tsan`).
    tsan_fiber: ?*anyopaque = null,
    tsan_scheduler: ?*anyopaque = null,
    /// The wait a wake asked to end (`fiber_wait.wake`), which may come
    /// before the wait is registered.
    woken_serial: u64 = 0,
    locals: Locals = .{},

    /// Takes a free slot, reserving a chunk of them when none is left. The
    /// slot's guard page faults on an overflow instead of overwriting other
    /// memory.
    pub fn create() error{OutOfMemory}!*Fiber {
        const self = try std.heap.smp_allocator.create(Fiber);
        errdefer std.heap.smp_allocator.destroy(self);
        const memory = try slots.take(self);
        self.* = .{ .memory = memory };
        if (builtin.sanitize_thread) self.tsan_fiber = tsan.__tsan_create_fiber(0);
        return self;
    }

    pub fn destroy(self: *Fiber) void {
        if (builtin.sanitize_thread) tsan.__tsan_destroy_fiber(self.tsan_fiber);
        slots.give(self.memory);
        std.heap.smp_allocator.destroy(self);
    }

    /// Prepares the fiber to run `start` from the top of its stack the next
    /// time it is resumed.
    pub fn prepare(self: *Fiber, start: *const fn (*Fiber) void, userdata: ?*anyopaque) void {
        self.start = start;
        self.userdata = userdata;
        self.finished = false;
        self.crashed = false;
        self.cancelled = false;
        self.stop.store(Stop.none, std.builtin.AtomicOrder.monotonic);
        self.wait = .{};
        self.locals.allocator = null;
        self.locals.body = null;
        self.locals.request_execution = null;
        self.locals.response = null;
        self.locals.stream_guard = null;
        std.debug.assert(self.locals.file == -1);
        std.debug.assert(self.locals.concurrency.isEmpty());
        self.locals.debug.reset();
        const top = std.mem.alignBackward(usize, @intFromPtr(self.memory.ptr) + self.memory.len, 16);
        const frame_address = top - std.mem.alignForward(usize, initial_frame_bytes, 16);
        const words: [*]usize = @ptrFromInt(frame_address);
        @memset(words[0 .. initial_frame_bytes / @sizeOf(usize)], 0);
        switch (builtin.cpu.arch) {
            .aarch64 => {
                words[0] = @intFromPtr(self); // x19
                words[11] = @intFromPtr(&roxum_fiber_entry); // x30
            },
            .x86_64 => {
                // Pop order: r15, r14, r13, r12, rbx, rbp, return address.
                words[4] = @intFromPtr(self); // rbx
                words[6] = @intFromPtr(&roxum_fiber_entry);
            },
            else => unreachable,
        }
        self.stack_pointer = frame_address;
    }
};

/// A socket a suspended fiber waits on, until it is ready or the deadline
/// passes.
pub const Wait = struct {
    socket: c_int = -1,
    /// `poll` events: input or output.
    events: i16 = 0,
    expires_at_nanoseconds: u64 = 0,
    outcome: Outcome = .ready,
    /// The wait's slot in the process's waits while it is registered.
    slot: u32 = 0,

    pub const Outcome = enum { ready, timed_out };
};

/// The reserved chunks of stack slots and the fiber in each slot. Chunks
/// are only ever added, and `chunk_count` is published after a chunk is
/// filled in, so `current` reads them without the lock.
const Slots = struct {
    mutex: sync.Mutex = .{},
    bases: [maximum_chunks]usize = @splat(0),
    chunk_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    fibers: [maximum_chunks][chunk_slots]std.atomic.Value(?*Fiber) = @splat(@splat(std.atomic.Value(?*Fiber).init(null))),
    /// Slots not in use, as (chunk, slot) pairs.
    free: std.ArrayList([2]u16) = .empty,

    fn take(self: *Slots, owner: *Fiber) error{OutOfMemory}![]align(std.heap.page_size_min) u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.free.items.len == 0) try self.reserve();
        const place = self.free.pop().?;
        self.fibers[place[0]][place[1]].store(owner, std.builtin.AtomicOrder.release);
        const start = self.bases[place[0]] + @as(usize, place[1]) * slot_bytes;
        return @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(start))[0..slot_bytes];
    }

    fn give(self: *Slots, memory: []align(std.heap.page_size_min) u8) void {
        const place = self.find(@intFromPtr(memory.ptr)).?;
        // The pages go back to the system; the address range stays reserved.
        _ = std.c.madvise(memory.ptr + guard_bytes, stack_bytes, std.c.MADV.DONTNEED);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.fibers[place[0]][place[1]].store(null, std.builtin.AtomicOrder.release);
        self.free.append(std.heap.smp_allocator, place) catch {};
    }

    /// Reserves a chunk of slots, each with its guard page. Called with the
    /// lock held.
    fn reserve(self: *Slots) error{OutOfMemory}!void {
        const chunk = self.chunk_count.load(std.builtin.AtomicOrder.monotonic);
        if (chunk == maximum_chunks) return error.OutOfMemory;
        // A reservation: pages take memory only when touched.
        var flags: std.c.MAP = .{ .TYPE = @FieldType(std.c.MAP, "TYPE").PRIVATE, .ANONYMOUS = true };
        if (builtin.os.tag == std.Target.Os.Tag.linux) flags.NORESERVE = true;
        const mapped = std.c.mmap(null, chunk_bytes, .{ .READ = true, .WRITE = true }, flags, -1, 0);
        if (mapped == std.c.MAP_FAILED) return error.OutOfMemory;
        const base = @intFromPtr(mapped);
        for (0..chunk_slots) |slot| {
            const guard: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(base + slot * slot_bytes);
            if (std.c.mprotect(guard, guard_bytes, .{}) != 0) {
                _ = std.c.munmap(@alignCast(mapped), chunk_bytes);
                return error.OutOfMemory;
            }
        }
        try self.free.ensureUnusedCapacity(std.heap.smp_allocator, chunk_slots);
        var slot = chunk_slots;
        while (slot > 0) {
            slot -= 1;
            self.free.appendAssumeCapacity(.{ @intCast(chunk), @intCast(slot) });
        }
        self.bases[chunk] = base;
        self.chunk_count.store(chunk + 1, std.builtin.AtomicOrder.release);
    }

    /// The (chunk, slot) holding `address`, or null when it is not on a
    /// fiber stack.
    fn find(self: *const Slots, address: usize) ?[2]u16 {
        const count = self.chunk_count.load(std.builtin.AtomicOrder.acquire);
        for (self.bases[0..count], 0..) |base, chunk| {
            if (address >= base and address - base < chunk_bytes) {
                return .{ @intCast(chunk), @intCast((address - base) / slot_bytes) };
            }
        }
        return null;
    }
};

var slots: Slots = .{};

/// The stack pointer. Read directly: `@frameAddress()` is unreliable where
/// release builds omit frame pointers.
inline fn stackPointer() usize {
    return switch (builtin.cpu.arch) {
        std.Target.Cpu.Arch.aarch64 => asm volatile ("mov %[result], sp"
            : [result] "=r" (-> usize),
        ),
        std.Target.Cpu.Arch.x86_64 => asm volatile ("movq %%rsp, %[result]"
            : [result] "=r" (-> usize),
        ),
        else => @compileError("unimplemented architecture"),
    };
}

/// The fiber whose stack this code runs on, or null off a fiber. Found from
/// the stack pointer, so it stays right when the fiber moves to another
/// thread.
pub fn current() ?*Fiber {
    const place = slots.find(stackPointer()) orelse return null;
    return slots.fibers[place[0]][place[1]].load(std.builtin.AtomicOrder.acquire);
}

/// A fault at `address` in a slot's guard: its fiber overflowed its stack.
/// Only reads, so a signal handler may call it.
pub const Overflow = struct {
    /// The slot's fiber; null if the slot was free.
    fiber: ?*Fiber,
};

pub fn overflowAt(address: usize) ?Overflow {
    const place = slots.find(address) orelse return null;
    const slot_start = slots.bases[place[0]] + @as(usize, place[1]) * slot_bytes;
    if (address - slot_start >= guard_bytes) return null;
    return .{ .fiber = slots.fibers[place[0]][place[1]].load(std.builtin.AtomicOrder.acquire) };
}

/// The running fiber's `Locals`, or null off a fiber.
pub fn currentLocals() ?*Locals {
    const self = current() orelse return null;
    return &self.locals;
}

/// Runs the fiber until it suspends or finishes, on this thread.
pub fn resumeFiber(target: *Fiber) void {
    std.debug.assert(!target.finished);
    if (builtin.sanitize_thread) {
        target.tsan_scheduler = tsan.__tsan_get_current_fiber();
        tsan.__tsan_switch_to_fiber(target.tsan_fiber, 0);
    }
    roxum_fiber_switch(&target.scheduler_stack_pointer, target.stack_pointer);
}

/// The thread sanitizer's fibers. It keeps a stack and a history
/// per thread unless told of a switch; a fiber resumed on another thread
/// would then run on the wrong one. Each switch is announced, with the
/// default flag: it orders what the fiber did before it.
const tsan = struct {
    extern fn __tsan_get_current_fiber() ?*anyopaque;
    extern fn __tsan_create_fiber(flags: c_uint) ?*anyopaque;
    extern fn __tsan_destroy_fiber(target: ?*anyopaque) void;
    extern fn __tsan_switch_to_fiber(target: ?*anyopaque, flags: c_uint) void;
};

/// Called on the fiber's own stack: returns to the scheduler that resumed
/// it until one resumes it again.
pub fn suspendCurrent() void {
    const self = current() orelse unreachable;
    if (builtin.sanitize_thread) tsan.__tsan_switch_to_fiber(self.tsan_scheduler, 0);
    roxum_fiber_switch(&self.stack_pointer, self.scheduler_stack_pointer);
}

fn run(self: *Fiber) callconv(.c) noreturn {
    self.start(self);
    self.finished = true;
    if (builtin.sanitize_thread) tsan.__tsan_switch_to_fiber(self.tsan_scheduler, 0);
    roxum_fiber_switch(&self.stack_pointer, self.scheduler_stack_pointer);
    unreachable;
}

test "a fiber suspends, resumes, and finishes" {
    const Probe = struct {
        var steps: usize = 0;
        fn start(_: *Fiber) void {
            steps += 1;
            suspendCurrent();
            steps += 1;
        }
    };
    const target = try Fiber.create();
    defer target.destroy();
    target.prepare(Probe.start, null);
    resumeFiber(target);
    try std.testing.expectEqual(@as(usize, 1), Probe.steps);
    try std.testing.expect(!target.finished);
    resumeFiber(target);
    try std.testing.expectEqual(@as(usize, 2), Probe.steps);
    try std.testing.expect(target.finished);
}

test "a prepared fiber starts over" {
    const Probe = struct {
        var runs: usize = 0;
        fn start(_: *Fiber) void {
            runs += 1;
        }
    };
    const target = try Fiber.create();
    defer target.destroy();
    for (0..3) |_| {
        target.prepare(Probe.start, null);
        resumeFiber(target);
        try std.testing.expect(target.finished);
    }
    try std.testing.expectEqual(@as(usize, 3), Probe.runs);
}

test "a fiber can use deep stack frames" {
    const Probe = struct {
        fn recurse(depth: usize) usize {
            var frame: [1024]u8 = undefined;
            frame[0] = @truncate(depth);
            std.mem.doNotOptimizeAway(&frame);
            if (depth == 0) return 0;
            return recurse(depth - 1) + 1;
        }
        var result: usize = 0;
        fn start(_: *Fiber) void {
            // About 2 MiB of frames: more than a small fiber stack would hold.
            result = recurse(2048);
        }
    };
    const target = try Fiber.create();
    defer target.destroy();
    target.prepare(Probe.start, null);
    resumeFiber(target);
    try std.testing.expect(target.finished);
    try std.testing.expectEqual(@as(usize, 2048), Probe.result);
}

test "two fibers interleave on one thread" {
    const Probe = struct {
        var order: [4]u8 = undefined;
        var count: usize = 0;
        fn start(self: *Fiber) void {
            const name: *const u8 = @ptrCast(self.userdata.?);
            order[count] = name.*;
            count += 1;
            suspendCurrent();
            order[count] = name.*;
            count += 1;
        }
    };
    const a_name: u8 = 'a';
    const b_name: u8 = 'b';
    const a = try Fiber.create();
    defer a.destroy();
    const b = try Fiber.create();
    defer b.destroy();
    a.prepare(Probe.start, @ptrCast(@constCast(&a_name)));
    b.prepare(Probe.start, @ptrCast(@constCast(&b_name)));
    resumeFiber(a);
    resumeFiber(b);
    resumeFiber(a);
    resumeFiber(b);
    try std.testing.expectEqualSlices(u8, "abab", &Probe.order);
}

test "a fiber is found from its own stack, and nothing off a fiber" {
    const Probe = struct {
        var found: ?*Fiber = null;
        fn start(_: *Fiber) void {
            found = current();
        }
    };
    try std.testing.expectEqual(@as(?*Fiber, null), current());
    const target = try Fiber.create();
    defer target.destroy();
    target.prepare(Probe.start, null);
    resumeFiber(target);
    try std.testing.expectEqual(@as(?*Fiber, target), Probe.found);
    try std.testing.expectEqual(@as(?*Fiber, null), current());
}

test "a fiber resumed on another thread keeps its locals and returns to that thread" {
    const Probe = struct {
        var before: ?*Fiber = null;
        var after: ?*Fiber = null;
        var marker: usize = 0;
        fn start(self: *Fiber) void {
            self.locals.debug.capture.count = 3;
            before = current();
            suspendCurrent();
            after = current();
            marker = currentLocals().?.debug.capture.count;
        }
        fn resumeElsewhere(target: *Fiber) void {
            resumeFiber(target);
        }
    };
    const target = try Fiber.create();
    defer target.destroy();
    target.prepare(Probe.start, null);
    resumeFiber(target);
    const thread = try std.Thread.spawn(.{}, Probe.resumeElsewhere, .{target});
    thread.join();
    try std.testing.expect(target.finished);
    try std.testing.expectEqual(@as(?*Fiber, target), Probe.before);
    try std.testing.expectEqual(@as(?*Fiber, target), Probe.after);
    try std.testing.expectEqual(@as(usize, 3), Probe.marker);
}

test "a fault in a fiber's guard is an overflow, and nowhere else" {
    const target = try Fiber.create();
    defer target.destroy();
    const start = @intFromPtr(target.memory.ptr);
    try std.testing.expectEqual(target, overflowAt(start).?.fiber.?);
    try std.testing.expectEqual(target, overflowAt(start + guard_bytes - 1).?.fiber.?);
    try std.testing.expectEqual(@as(?Overflow, null), overflowAt(start + guard_bytes));
    try std.testing.expectEqual(@as(?Overflow, null), overflowAt(start + slot_bytes - 1));
    var local: u8 = 0;
    try std.testing.expectEqual(@as(?Overflow, null), overflowAt(@intFromPtr(&local)));
}

test "a slot given back is taken again" {
    const first = try Fiber.create();
    const memory = first.memory.ptr;
    first.destroy();
    const second = try Fiber.create();
    defer second.destroy();
    try std.testing.expectEqual(memory, second.memory.ptr);
}
