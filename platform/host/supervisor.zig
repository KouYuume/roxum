const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const net = @import("net.zig");
const transfer = @import("net/listener_transfer.zig");
const drain_signal = @import("drain_signal.zig");
const metrics = @import("metrics.zig");
const admin = @import("admin.zig");
pub var inherited_listener: ?net.Listener = null;
var readiness_channel: ?c_int = null;
/// A pipe nothing is written to. The supervisor keeps the write end until it ends;
/// a worker closes it and watches the read end (`drain_signal.watchSupervisor`).
var lifeline: [2]c_int = .{ -1, -1 };

const maximum_workers = @import("worker_count.zig").maximum;

pub const Admin = transfer.Admin;

/// Reports this worker ready to the supervisor, with the number of workers
/// its `init!` asked for, its drain timeout, and its admin port. Returns
/// false when no supervisor started it.
pub fn notifyReady(listener: net.Listener, workers: u16, drain_timeout_milliseconds: u64, admin_port: ?Admin) !bool {
    const channel = readiness_channel orelse return false;
    try transfer.send(channel, listener, workers, drain_timeout_milliseconds, admin_port);
    _ = close(channel);
    readiness_channel = null;
    return true;
}

const stdio = @import("stdio.zig");

const WorkerMain = *const fn (?u16) c_int;

extern "c" fn fork() c_int;
extern "c" fn close(file_descriptor: c_int) c_int;
extern "c" fn waitpid(process_id: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn kill(process_id: c_int, signal: c_int) c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn usleep(microseconds: c_uint) c_int;

const kill_signal: c_int = 9;
const wait_no_hang: c_int = 1;
/// SIGINT and SIGTERM received, counted by a signal handler and read by the
/// supervision loop: the first drains the workers, a second stops them.
var shutdown_signals = std.atomic.Value(u32).init(0);
/// How long workers may drain, from worker 0's ready report.
var worker_drain_timeout_milliseconds: u64 = 20_000;
/// Time past the drain timeout before the supervisor kills a worker that
/// has not exited: a worker ends its own drain at the timeout, so this only
/// catches one that cannot.
const drain_margin_milliseconds: u64 = 5_000;
const stable_worker_milliseconds: u64 = 30_000;

pub const Options = struct {
    readiness_timeout_milliseconds: u64 = 10_000,
};

pub const Error = error{
    ForkFailed,
    ReadinessChannelFailed,
    ReadinessFailed,
    InvalidPort,
    AdminPortFailed,
    ClockFailed,
    OutOfMemory,
};

const Slot = struct {
    channel: ?c_int = null,
    ready: bool = false,
    started: u64 = 0,
    retry_at: u64 = 0,
    failures: u6 = 0,
};

/// The parent retains one listener; workers own all accepted connections.
/// Worker 0 starts alone; its ready report says how many workers to run, and
/// that number holds until the server stops.
pub fn run(worker_main: WorkerMain, options: Options) Error!noreturn {
    installSupervisorSignals();
    if (std.c.pipe(&lifeline) != 0 or !net.setCloseOnExec(lifeline[0]) or !net.setCloseOnExec(lifeline[1])) return error.ReadinessChannelFailed;
    // Before any fork, so every worker shares it.
    metrics.createRegion();
    var process_id_storage = [_]c_int{0} ** maximum_workers;
    var slot_storage = [_]Slot{Slot{}} ** maximum_workers;
    const all_process_ids: []c_int = &process_id_storage;
    const slots_storage: []Slot = &slot_storage;
    var worker_count: usize = 1;
    defer for (slots_storage) |slot| {
        if (slot.channel) |channel| {
            _ = close(channel);
        }
    };
    errdefer {
        for (all_process_ids) |pid| {
            if (pid > 0) {
                _ = kill(pid, kill_signal);
                var status: c_int = 0;
                _ = waitpid(pid, &status, 0);
            }
        }
    }
    defer if (inherited_listener) |listener| net.closeSocket(listener.socket);
    var published = false;
    while (true) {
        if (shutdown_signals.load(std.builtin.AtomicOrder.monotonic) > 0) shutdown(all_process_ids);
        const now = try monotonicMilliseconds();
        admin.serve(.{ .ready = anyReady(slots_storage[0..worker_count]), .workers = worker_count, .now_milliseconds = now });
        const process_ids = all_process_ids[0..worker_count];
        const slots = slots_storage[0..worker_count];
        for (process_ids, slots, 0..) |*pid, *slot, index| {
            if (pid.* > 0) {
                var status: c_int = 0;
                const ended = waitpid(pid.*, &status, wait_no_hang);
                if (ended > 0) {
                    if (slot.channel) |channel| {
                        _ = close(channel);
                    }
                    slot.channel = null;
                    slot.ready = false;
                    pid.* = 0;
                    metrics.clearWorker(index);
                    if (published) metrics.countRestart();
                    if (now -| slot.started >= stable_worker_milliseconds) slot.failures = 0;
                    slot.retry_at = now + restartDelayMicroseconds(slot.failures) / 1000;
                    slot.failures +|= 1;
                    if (!published) return error.ReadinessFailed;
                }
            }
            if (pid.* == 0 and now >= slot.retry_at and (index == 0 or inherited_listener != null)) {
                spawnWorker(worker_main, all_process_ids, slots_storage, index) catch |err| {
                    if (!published) return err;
                    slot.retry_at = now + restartDelayMicroseconds(slot.failures) / 1000;
                    slot.failures +|= 1;
                    continue;
                };
                slot.started = now;
            }
            if (slot.channel) |channel| {
                const received = transfer.receive(channel) catch {
                    if (!published) return error.ReadinessFailed;
                    _ = kill(pid.*, kill_signal);
                    _ = close(channel);
                    slot.channel = null;
                    continue;
                };
                if (received) |ready| {
                    if (inherited_listener) |shared| {
                        net.closeSocket(ready.listener.socket);
                        if (ready.listener.port != shared.port) {
                            if (!published) return error.InvalidPort;
                            _ = kill(pid.*, kill_signal);
                            _ = close(channel);
                            slot.channel = null;
                            continue;
                        }
                        if (ready.workers != worker_count) warnWorkerCount(ready.workers, worker_count);
                    } else {
                        inherited_listener = ready.listener;
                        worker_count = @min(ready.workers, maximum_workers);
                        worker_drain_timeout_milliseconds = ready.drain_timeout_milliseconds;
                        if (ready.admin) |admin_port| admin.open(admin_port.address, admin_port.port) catch {
                            diagnostics.startupFailed("the admin port (Server.Metrics.Listen) could not listen");
                            return error.AdminPortFailed;
                        };
                    }
                    _ = close(channel);
                    slot.channel = null;
                    slot.ready = true;
                } else if (now -| slot.started >= options.readiness_timeout_milliseconds) {
                    if (!published) return error.ReadinessFailed;
                    _ = kill(pid.*, kill_signal);
                    _ = close(channel);
                    slot.channel = null;
                }
            }
        }
        if (!published) {
            var all_ready = true;
            for (slots_storage[0..worker_count]) |slot| {
                all_ready = all_ready and slot.ready;
            }
            if (all_ready) {
                stdio.writeStdoutPort(inherited_listener.?.port) catch return error.ReadinessFailed;
                published = true;
            }
        }
        _ = usleep(10_000);
    }
}

/// At least one worker is up: what `/ready` reports outside a drain.
fn anyReady(slots: []const Slot) bool {
    for (slots) |slot| {
        if (slot.ready) return true;
    }
    return false;
}

fn spawnWorker(worker_main: WorkerMain, process_ids: []c_int, slots: []Slot, index: usize) Error!void {
    var channels: [2]c_int = undefined;
    // AF_UNIX / SOCK_DGRAM: readiness and its descriptor are one atomic message.
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.DGRAM, 0, &channels) != 0) return error.ReadinessChannelFailed;
    if (!net.setCloseOnExec(channels[0]) or !net.setCloseOnExec(channels[1])) {
        closePair(channels);
        return error.ReadinessChannelFailed;
    }
    const pid = fork();
    if (pid < 0) {
        closePair(channels);
        return error.ForkFailed;
    }
    if (pid == 0) {
        installWorkerSignals();
        _ = close(lifeline[1]);
        drain_signal.watchSupervisor(lifeline[0]);
        admin.closeInWorker();
        metrics.worker_index = index;
        _ = close(channels[0]);
        for (slots) |slot| {
            if (slot.channel) |channel| {
                _ = close(channel);
            }
        }
        readiness_channel = channels[1];
        _exit(worker_main(if (inherited_listener) |listener| listener.port else null));
    }
    _ = close(channels[1]);
    process_ids[index] = pid;
    slots[index].channel = channels[0];
    slots[index].ready = false;
}

/// A restarted worker's `init!` asked for another number of processes. The
/// processes already running stay as they are.
fn warnWorkerCount(asked: u16, running: usize) void {
    var buffer: [128]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "a restarted process asked for {d} processes; keeping {d}",
        .{ asked, running },
    ) catch return;
    diagnostics.warning(message);
}

fn installSupervisorSignals() void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = requestShutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    // Writing to a connection the peer closed raises SIGPIPE on Linux, which
    // has no SO_NOSIGPIPE. On every OS the same happens to stdout and stderr
    // when they are pipes whose reader has gone. Workers inherit the ignored
    // disposition across fork, so such writes fail with EPIPE instead of
    // ending the process.
    const ignore = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);
    // The signals the supervisor sends its workers must not end the
    // supervisor if they reach the whole group.
    std.posix.sigaction(drain_signal.drain_signal, &ignore, null);
    std.posix.sigaction(drain_signal.stop_signal, &ignore, null);
}

/// A worker ignores SIGTERM and SIGINT: Ctrl-C reaches every process of the
/// terminal's group, and a process manager such as systemd may signal every
/// process of the service at once, so a worker would see one request twice.
/// The supervisor alone turns them into a drain or a stop (`drain_signal`).
fn installWorkerSignals() void {
    const ignore = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &ignore, null);
    std.posix.sigaction(std.posix.SIG.INT, &ignore, null);
    const drain = std.posix.Sigaction{
        .handler = .{ .handler = drain_signal.handleDrain },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(drain_signal.drain_signal, &drain, null);
    const stop = std.posix.Sigaction{
        .handler = .{ .handler = drain_signal.handleStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(drain_signal.stop_signal, &stop, null);
}

fn requestShutdown(_: std.posix.SIG) callconv(std.builtin.CallingConvention.c) void {
    _ = shutdown_signals.fetchAdd(1, std.builtin.AtomicOrder.monotonic);
}

/// Drains the workers: closes the listener, so connections no worker
/// accepted yet are refused, and asks each worker to drain. A second
/// signal asks them to stop at once. Exits 0 when every worker
/// finished its drain and exited 0, otherwise 1; a worker still running
/// past the drain timeout and a margin is killed.
fn shutdown(process_ids: []c_int) noreturn {
    if (inherited_listener) |listener| {
        net.closeSocket(listener.socket);
        inherited_listener = null;
    }
    signalAll(process_ids, @intFromEnum(drain_signal.drain_signal));
    var forwarded: u32 = 1;
    var code: c_int = 0;
    const started = monotonicMilliseconds() catch 0;
    const limit = worker_drain_timeout_milliseconds +| drain_margin_milliseconds;
    var remaining = countRunning(process_ids);
    while (remaining != 0) {
        var status: c_int = 0;
        const ended = waitpid(-1, &status, wait_no_hang);
        if (ended > 0) {
            if (clearProcess(process_ids, ended)) {
                remaining -= 1;
                if (!exitedZero(status)) code = 1;
            }
            continue;
        }
        const signals = shutdown_signals.load(std.builtin.AtomicOrder.monotonic);
        if (signals > forwarded) {
            forwarded = signals;
            signalAll(process_ids, @intFromEnum(drain_signal.stop_signal));
        }
        const now = monotonicMilliseconds() catch break;
        if (now -| started >= limit) break;
        // Draining: `/ready` answers 503 so load balancers stop sending.
        admin.serve(.{ .ready = false, .workers = process_ids.len, .now_milliseconds = now });
        _ = usleep(10_000);
    }
    if (remaining != 0) {
        code = 1;
        for (process_ids) |process_id| {
            if (process_id > 0) _ = kill(process_id, kill_signal);
        }
        while (remaining != 0) {
            var status: c_int = 0;
            const ended = waitpid(-1, &status, 0);
            if (ended <= 0) break;
            if (clearProcess(process_ids, ended)) remaining -= 1;
        }
    }
    _exit(code);
}

fn exitedZero(status: c_int) bool {
    const bits: u32 = @bitCast(status);
    return std.posix.W.IFEXITED(bits) and std.posix.W.EXITSTATUS(bits) == 0;
}

fn countRunning(process_ids: []const c_int) usize {
    var count: usize = 0;
    for (process_ids) |process_id| {
        if (process_id > 0) count += 1;
    }
    return count;
}

/// Forgets a worker that ended; false when `ended` was not one.
fn clearProcess(process_ids: []c_int, ended: c_int) bool {
    for (process_ids) |*process_id| {
        if (process_id.* == ended) {
            process_id.* = 0;
            return true;
        }
    }
    return false;
}

fn monotonicMilliseconds() Error!u64 {
    const nanoseconds = net.monotonicNanoseconds() catch return error.ClockFailed;
    return nanoseconds / std.time.ns_per_ms;
}

fn restartDelayMicroseconds(consecutive_failures: u6) c_uint {
    const shift: u5 = @intCast(@min(consecutive_failures, 6));
    return @min(@as(c_uint, 100_000) << shift, 5_000_000);
}

fn signalAll(process_ids: []const c_int, signal: c_int) void {
    for (process_ids) |process_id| {
        if (process_id > 0) _ = kill(process_id, signal);
    }
}

fn closePair(file_descriptors: [2]c_int) void {
    _ = close(file_descriptors[0]);
    _ = close(file_descriptors[1]);
}

test "restart backoff saturates after the fifth consecutive failure" {
    try std.testing.expectEqual(@as(c_uint, 100_000), restartDelayMicroseconds(0));
    try std.testing.expectEqual(@as(c_uint, 200_000), restartDelayMicroseconds(1));
    try std.testing.expectEqual(@as(c_uint, 3_200_000), restartDelayMicroseconds(5));
    try std.testing.expectEqual(@as(c_uint, 5_000_000), restartDelayMicroseconds(6));
}

test {
    _ = transfer;
    _ = admin;
}
