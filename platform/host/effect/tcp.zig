//! `Tcp`: outbound connections in pools the host keeps (D13). The Roc Model
//! cannot change between requests, so connections that outlive a request
//! have to be the host's. Every wait goes through `tcp.waitFor`, so on a
//! request fiber only the request waits. Roc borrows a connection
//! only inside `Tcp.with!` or `Tcp.with_origin!`, which always return it.
//!
//! Two kinds of pool: the ones `Tcp.pool!` makes in `init!` for one known
//! server each, and origin pools, which `Tcp.with_origin!` makes when an
//! origin (host, port, CA) is first used, for an HTTP client whose servers
//! are known only at run time. Origin pools share the limits below
//! and are dropped once they have no connections.
//!
//! Every thread of the process shares the pools. `state_lock` guards
//! the pool lists and each connection's `state`, `generation`, `holder`, and
//! `idle_since`, and each pool's `waiters`; it is never held while waiting.
//! The rest of a lent connection (socket, TLS session, scopes) belongs to
//! the request that holds it. An origin pool is empty only while the lock
//! is held, so dropping an unused one never takes a pool from under a
//! request about to use it.
const std = @import("std");
const sync = @import("../sync.zig");
const abi = @import("../roc_platform_abi.zig");
const allocator_context = @import("../allocator/context.zig");
const fiber = @import("../fiber.zig");
const fiber_wait = @import("../fiber_wait.zig");
const request_bridge = @import("../bridge/request.zig");
const resolver = @import("../resolver.zig");
const runtime = @import("../runtime.zig");
const secret = @import("secret.zig");
const tcp = @import("../net/tcp.zig");
const tls = @import("../tls.zig");
const request_memory = @import("../allocator/request_memory.zig");
const metrics = @import("../metrics.zig");

const maximum_pools = 32;
const maximum_connections_per_pool = 1024;
/// Origin pools: connections in use at once per origin, idle connections
/// across all origins, and how long one may stay idle.
const default_connections_per_origin = 64;
const default_idle_origin_connections = 100;
const default_origin_idle_milliseconds = 90_000;
/// `Tcp.configure_origins!` changes them, before the first origin pool.
var origin_limits = OriginLimits{};
/// The process's threads, which `Auto` origin limits scale with.
var thread_count: usize = 1;
var state_lock: sync.Mutex = .{};

/// Null is `Server.Count.Auto`: the default for each thread.
const OriginLimits = struct {
    connections_per_origin: ?usize = null,
    idle_connections: ?usize = null,
    idle_nanoseconds: u64 = default_origin_idle_milliseconds * std.time.ns_per_ms,
};
/// Handles keep 16 bits for the pool; origin pools follow the fixed ones.
const maximum_origins = 0xffff - maximum_pools;
/// The most bytes one read returns.
pub const maximum_read_bytes = 64 * 1024;

const State = enum { empty, idle, lent };

const Connection = struct {
    state: State = .empty,
    socket: tcp.Socket = -1,
    session: ?*tls.Session = null,
    /// Changes whenever the connection is lent, so a handle kept past its
    /// `with!` no longer matches. Drawn from one counter for all
    /// connections, so a dropped origin pool's slot reused by another
    /// does not revive an old handle.
    generation: u32 = 0,
    /// When an origin pool's connection last went idle.
    idle_since: u64 = 0,
    /// Opened for the current lease: the client must start its protocol.
    new: bool = false,
    /// The request fiber the connection is lent to, so a request that
    /// crashes gives it back. Null in `init!`.
    holder: ?*fiber.Fiber = null,
    /// When it was lent, for the metrics.
    lent_at: u64 = 0,
    /// Not to be returned to the pool: a read or write failed, or the
    /// client called `discard!`.
    broken: bool = false,
    next_scope: u64 = 0,
    scopes: std.ArrayList(u64) = .empty,

    fn clearScopes(self: *Connection) void {
        self.scopes.deinit(std.heap.smp_allocator);
        self.scopes = std.ArrayList(u64).empty;
    }

    fn openScope(self: *Connection) u64 {
        if (self.next_scope == std.math.maxInt(u64)) return 0;
        self.next_scope += 1;
        self.scopes.append(std.heap.smp_allocator, self.next_scope) catch return 0;
        return self.next_scope;
    }

    fn closeScope(self: *Connection, id: u64) void {
        for (self.scopes.items, 0..) |scope, index| {
            if (scope == id) {
                self.scopes.shrinkRetainingCapacity(index);
                return;
            }
        }
    }

    fn close(self: *Connection) void {
        self.clearScopes();
        if (self.session) |session| session.destroy();
        if (self.socket != -1) tcp.closeSocket(self.socket);
        self.socket = -1;
        self.session = null;
        self.state = .empty;
        self.new = false;
        self.broken = false;
        self.holder = null;
        self.lent_at = 0;
    }
};

/// A request fiber waiting for a connection, and the wait it waits in. A
/// wake may come from another thread than the fiber's.
const Waiter = struct {
    target: *fiber.Fiber,
    serial: u64,
};

const Pool = struct {
    host: []u8,
    port: u16,
    /// Made by `with_origin!` rather than `pool!`.
    origin: bool = false,
    bundle: ?*std.crypto.Certificate.Bundle,
    /// TLS waits for the client to call `start_tls`.
    tls_later: bool,
    connect_timeout_milliseconds: u64,
    acquire_timeout_milliseconds: u64,
    connections: []Connection,
    /// Request fibers waiting for a connection, first come first served.
    waiters: std.ArrayList(Waiter) = .empty,
    /// Entries before this index have already been woken. Protected by state_lock.
    next_waiter: usize = 0,
    /// The pool's origin in the metrics, found when it first lends.
    metrics_origin: ?usize = null,

    /// The pool's origin index in the metrics, `host:port`.
    fn metricsOrigin(self: *Pool) usize {
        if (self.metrics_origin) |index| return index;
        var buffer: [272]u8 = undefined;
        const name = std.fmt.bufPrint(&buffer, "{s}:{d}", .{ self.host, self.port }) catch self.host;
        const index = metrics.originIndex(name);
        self.metrics_origin = index;
        return index;
    }

    /// Notes that `connection` is lent now, after a wait since `asked_at`.
    fn noteLent(self: *Pool, connection: *Connection, asked_at: u64) void {
        if (!metrics.enabled()) return;
        const now = tcp.monotonicNanoseconds() catch return;
        connection.lent_at = now;
        metrics.observeOriginWait(self.metricsOrigin(), now -| asked_at);
    }

    /// Notes that `connection` came back or was closed while lent.
    fn noteReturned(self: *Pool, connection: *const Connection) void {
        if (!metrics.enabled() or connection.lent_at == 0) return;
        const now = tcp.monotonicNanoseconds() catch return;
        metrics.observeOriginHold(self.metricsOrigin(), now -| connection.lent_at);
    }

    /// Resumes the first waiting fiber not already woken, if any, at once:
    /// a connection is free or a slot is empty. The fiber stays in
    /// `waiters` until it runs, which keeps an origin pool from being
    /// dropped under it.
    fn wakeOne(self: *Pool) void {
        if (self.next_waiter == self.waiters.items.len) return;
        const waiter = self.waiters.items[self.next_waiter];
        self.next_waiter += 1;
        fiber_wait.wake(waiter.target, waiter.serial);
    }

    fn removeWaiter(self: *Pool, target: *fiber.Fiber) void {
        for (self.waiters.items, 0..) |item, index| {
            if (item.target == target) {
                _ = self.waiters.orderedRemove(index);
                if (index < self.next_waiter) self.next_waiter -= 1;
                return;
            }
        }
    }
};

var pools: [maximum_pools]?*Pool = @splat(null);
var origins: std.ArrayList(?*Pool) = .empty;
var next_generation: u32 = 0;

fn nextGeneration() u32 {
    next_generation +%= 1;
    return next_generation;
}

/// The pool with 0-based index `pool_index` in handles: a fixed pool, then
/// the origin pools.
fn poolAt(pool_index: usize) ?*Pool {
    if (pool_index < maximum_pools) return pools[pool_index];
    const origin_index = pool_index - maximum_pools;
    if (origin_index >= origins.items.len) return null;
    return origins.items[origin_index];
}

const Lease = struct { pool: *Pool, connection: *Connection };

fn handleOf(pool_index: usize, slot: usize, generation: u32) u64 {
    return (@as(u64, pool_index + 1) << 48) | (@as(u64, slot) << 32) | generation;
}

/// The connection behind a handle lent by `acquire`, or null when the
/// handle is stale or made up.
fn leaseOf(handle: u64) ?Lease {
    state_lock.lock();
    defer state_lock.unlock();
    return leaseOfLocked(handle);
}

fn leaseOfLocked(handle: u64) ?Lease {
    const pool_number: usize = @intCast(handle >> 48);
    if (pool_number == 0) return null;
    const pool = poolAt(pool_number - 1) orelse return null;
    const slot: usize = @intCast((handle >> 32) & 0xffff);
    if (slot >= pool.connections.len) return null;
    const connection = &pool.connections[slot];
    if (connection.state != .lent or connection.generation != @as(u32, @truncate(handle))) return null;
    return .{ .pool = pool, .connection = connection };
}

fn rocHost() abi.RocHost {
    const context = allocator_context.current() orelse @panic("allocator context is not set");
    return runtime.makeRocHost(@ptrCast(context.host_allocator));
}

pub fn hostedTcpPool(options: abi.HostTcpPoolArgs) callconv(std.builtin.CallingConvention.c) abi.HostTcpMade {
    var roc_host = rocHost();
    defer options.decref(&roc_host);
    const host = options.host.asSlice();
    if (host.len == 0 or host.len >= 256 or options.port == 0 or options.tls > 2 or
        options.maximum_connections == 0 or options.maximum_connections > maximum_connections_per_pool)
    {
        return made(.Invalid, 0);
    }
    const bundle = switch (options.tls) {
        0 => null,
        1 => tls.bundleFor(null) catch return made(.CaUnavailable, 0),
        else => tls.bundleFor(options.ca_file.asSlice()) catch return made(.CaUnavailable, 0),
    };
    state_lock.lock();
    defer state_lock.unlock();
    const index = for (pools, 0..) |item, index| {
        if (item == null) break index;
    } else return made(.TooMany, 0);

    const count: usize = @intCast(options.maximum_connections);
    const pool = std.heap.smp_allocator.create(Pool) catch return made(.Invalid, 0);
    const connections = std.heap.smp_allocator.alloc(Connection, count) catch {
        std.heap.smp_allocator.destroy(pool);
        return made(.Invalid, 0);
    };
    @memset(connections, .{});
    const stored_host = std.heap.smp_allocator.dupe(u8, host) catch {
        std.heap.smp_allocator.free(connections);
        std.heap.smp_allocator.destroy(pool);
        return made(.Invalid, 0);
    };
    pool.* = .{
        .host = stored_host,
        .port = options.port,
        .bundle = bundle,
        .tls_later = options.tls_later and bundle != null,
        .connect_timeout_milliseconds = options.connect_timeout_milliseconds,
        .acquire_timeout_milliseconds = options.acquire_timeout_milliseconds,
        .connections = connections,
    };
    pools[index] = pool;
    return made(.Made, index + 1);
}

fn made(tag: abi.HostTcpMadeTag, handle: u64) abi.HostTcpMade {
    var result: abi.HostTcpMade = undefined;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    result.tag = tag;
    if (tag == .Made) {
        const payload: *u64 = @ptrCast(@alignCast(&result.payload));
        payload.* = handle;
    }
    return result;
}

fn acquired(tag: abi.HostTcpAcquiredTag, handle: u64) abi.HostTcpAcquired {
    var result: abi.HostTcpAcquired = undefined;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    result.tag = tag;
    if (tag == .Lent) {
        const payload: *u64 = @ptrCast(@alignCast(&result.payload));
        payload.* = handle;
    }
    return result;
}

const OpenError = error{ ResolveFailed, ResolveTimedOut, ConnectFailed, ConnectTimedOut, TlsFailed };

/// Connects to the first of the host's addresses that accepts, then runs
/// the TLS handshake when the pool asks for it.
fn open(pool: *Pool, connection: *Connection, deadline: tcp.Deadline) OpenError!void {
    const addresses = resolver.resolve(pool.host, pool.port, deadline) catch |err| return switch (err) {
        error.ResolveTimeout => error.ResolveTimedOut,
        else => error.ResolveFailed,
    };
    var last: OpenError = error.ConnectFailed;
    const socket = for (addresses.slice()) |*address| {
        break tcp.connectUntil(address.sockaddr(), address.length, deadline) catch |err| {
            last = if (err == error.ConnectTimeout) error.ConnectTimedOut else error.ConnectFailed;
            if (err == error.ConnectTimeout) return last;
            continue;
        };
    } else return last;
    connection.socket = socket;
    if (pool.tls_later) return;
    if (pool.bundle) |bundle| {
        // `lend` closes the socket under the lock.
        connection.session = tls.Session.connect(socket, pool.host, bundle, deadline) catch |err| {
            return switch (err) {
                error.Timeout => error.ConnectTimedOut,
                else => error.TlsFailed,
            };
        };
    }
}

/// Stops the request at this effect when its client went, or the worker
/// drains, while it waited writing its body, once the effect
/// has cleaned up.
pub fn hostedTcpAcquire(pool_handle: u64) callconv(std.builtin.CallingConvention.c) abi.HostTcpAcquired {
    const result = hostedTcpAcquireInner(pool_handle);
    fiber_wait.stopIfStreamEnds();
    return result;
}

fn hostedTcpAcquireInner(pool_handle: u64) abi.HostTcpAcquired {
    if (pool_handle == 0 or pool_handle > maximum_pools) return acquired(.Busy, 0);
    const pool_index: usize = @intCast(pool_handle - 1);
    state_lock.lock();
    const pool = pools[pool_index] orelse {
        state_lock.unlock();
        return acquired(.Busy, 0);
    };
    const deadline = tcp.Deadline.afterMilliseconds(pool.acquire_timeout_milliseconds) catch {
        state_lock.unlock();
        return acquired(.Busy, 0);
    };
    return lend(pool, pool_index, deadline, null, true);
}

/// Lends an idle connection of `pool`, or opens one in an empty slot, or
/// waits for one until `deadline`. A new connection must connect by
/// `connect_deadline` when given, else by the pool's connect timeout.
/// Called with `state_lock` held; returns with it released.
fn lend(pool: *Pool, pool_index: usize, deadline: tcp.Deadline, connect_deadline: ?tcp.Deadline, reuse_idle: bool) abi.HostTcpAcquired {
    const asked_at = if (metrics.enabled()) tcp.monotonicNanoseconds() catch 0 else 0;
    while (true) {
        // An idle connection the server has not closed meanwhile.
        for (pool.connections, 0..) |*connection, slot| {
            if (!reuse_idle) break;
            if (connection.state != .idle) continue;
            if (!tcp.isQuiet(connection.socket)) {
                connection.close();
                continue;
            }
            connection.state = .lent;
            connection.generation = nextGeneration();
            connection.new = false;
            connection.holder = fiber.current();
            pool.noteLent(connection, asked_at);
            state_lock.unlock();
            return acquired(.Lent, handleOf(pool_index, slot, connection.generation));
        }
        // Room for a new one. The slot is taken before connecting, which may
        // suspend this request while others run. Without `reuse_idle`, an
        // idle connection gives up its slot when no slot is empty.
        const empty_slot = for (pool.connections) |connection| {
            if (connection.state == .empty) break true;
        } else false;
        if (!reuse_idle and !empty_slot) {
            for (pool.connections) |*connection| {
                if (connection.state == .idle) {
                    connection.close();
                    break;
                }
            }
        }
        for (pool.connections, 0..) |*connection, slot| {
            if (connection.state != .empty) continue;
            connection.state = .lent;
            connection.generation = nextGeneration();
            connection.holder = fiber.current();
            state_lock.unlock();
            const opened: OpenError!void = if (connect_deadline) |given| open(pool, connection, given) else blk: {
                const own = tcp.Deadline.afterMilliseconds(pool.connect_timeout_milliseconds) catch break :blk error.ConnectFailed;
                break :blk open(pool, connection, own);
            };
            opened catch |err| {
                state_lock.lock();
                connection.close();
                pool.wakeOne();
                state_lock.unlock();
                return acquired(switch (err) {
                    error.ResolveFailed => .ResolveFailed,
                    error.ResolveTimedOut => .ResolveTimedOut,
                    error.ConnectFailed => .ConnectFailed,
                    error.ConnectTimedOut => .ConnectTimedOut,
                    error.TlsFailed => .TlsFailed,
                }, 0);
            };
            connection.new = true;
            state_lock.lock();
            pool.noteLent(connection, asked_at);
            state_lock.unlock();
            return acquired(.Lent, handleOf(pool_index, slot, connection.generation));
        }
        // Every connection is in use: wait for one to come back. Off a
        // request fiber (in `init!`) nothing else could return one.
        const busy = busy: {
            const self = fiber.current() orelse break :busy true;
            const wait_hook = tcp.fiber_wait orelse break :busy true;
            const now = tcp.monotonicNanoseconds() catch break :busy true;
            if (deadline.hasPassedAt(now)) break :busy true;
            // `waitSocket` numbers the wait it starts next.
            pool.waiters.append(std.heap.smp_allocator, .{ .target = self, .serial = self.wait_serial + 1 }) catch break :busy true;
            state_lock.unlock();
            // No socket: the fiber resumes at the deadline, or earlier when
            // `release` wakes it.
            _ = wait_hook(-1, 0, deadline.expires_at_nanoseconds);
            state_lock.lock();
            pool.removeWaiter(self);
            break :busy false;
        };
        if (busy) {
            state_lock.unlock();
            return acquired(.Busy, 0);
        }
    }
}

/// Loads the CA certificates for an origin client in `init!`.
pub fn hostedTcpCheckCa(tls_code: u8, ca_file: abi.RocStr) callconv(std.builtin.CallingConvention.c) bool {
    var roc_host = rocHost();
    defer ca_file.decref(&roc_host);
    _ = bundleOf(tls_code, ca_file.asSlice()) catch return false;
    return true;
}

fn bundleOf(tls_code: u8, ca_file: []const u8) error{CaUnavailable}!?*std.crypto.Certificate.Bundle {
    return switch (tls_code) {
        0 => null,
        1 => tls.bundleFor(null) catch error.CaUnavailable,
        2 => tls.bundleFor(ca_file) catch error.CaUnavailable,
        else => error.CaUnavailable,
    };
}

/// Sets the origin pools' limits for this process. Refused once an
/// origin pool exists, or for a limit outside its range. The process's
/// thread count is not known yet; `setThreads` checks a fixed count
/// against it.
pub fn hostedTcpConfigureOrigins(options: abi.HostTcpConfigure_originsArgs) callconv(std.builtin.CallingConvention.c) bool {
    state_lock.lock();
    defer state_lock.unlock();
    for (origins.items) |item| {
        if (item != null) return false;
    }
    if (!options.connections_auto and options.connections_per_origin == 0) return false;
    if (options.idle_timeout_milliseconds == 0 or options.idle_timeout_milliseconds > 3_600_000) return false;
    const connections = if (options.connections_auto) null else std.math.cast(usize, options.connections_per_origin) orelse return false;
    const idle = if (options.idle_auto) null else std.math.cast(usize, options.idle_connections) orelse return false;
    origin_limits = .{
        .connections_per_origin = connections,
        .idle_connections = idle,
        .idle_nanoseconds = options.idle_timeout_milliseconds * std.time.ns_per_ms,
    };
    return true;
}

/// Records the process's threads once `init!` has chosen them.
/// Fails when a fixed origin limit is over its bound for that many.
pub fn setThreads(threads: usize) error{OriginLimitsTooLarge}!void {
    state_lock.lock();
    defer state_lock.unlock();
    thread_count = threads;
    if ((origin_limits.connections_per_origin orelse 0) > maximum_connections_per_pool * threads) return error.OriginLimitsTooLarge;
    if ((origin_limits.idle_connections orelse 0) > 65_536 * threads) return error.OriginLimitsTooLarge;
}

fn connectionsPerOrigin() usize {
    return origin_limits.connections_per_origin orelse default_connections_per_origin * thread_count;
}

fn idleOriginConnections() usize {
    return origin_limits.idle_connections orelse default_idle_origin_connections * thread_count;
}

/// Stops the request at this effect when its client went, or the worker
/// drains, while it waited writing its body, once the effect
/// has cleaned up.
pub fn hostedTcpAcquireOrigin(options: abi.HostTcpAcquire_originArgs) callconv(std.builtin.CallingConvention.c) abi.HostTcpAcquired {
    const result = hostedTcpAcquireOriginInner(options);
    fiber_wait.stopIfStreamEnds();
    return result;
}

fn hostedTcpAcquireOriginInner(options: abi.HostTcpAcquire_originArgs) abi.HostTcpAcquired {
    var roc_host = rocHost();
    defer options.decref(&roc_host);
    const host = options.host.asSlice();
    if (host.len == 0 or host.len >= 256 or options.port == 0) return acquired(.ConnectFailed, 0);
    const bundle = bundleOf(options.tls, options.ca_file.asSlice()) catch return acquired(.TlsFailed, 0);
    const deadline = tcp.Deadline.afterMilliseconds(options.timeout_milliseconds) catch return acquired(.Busy, 0);
    const now = tcp.monotonicNanoseconds() catch null;
    state_lock.lock();
    if (now) |value| closeExpiredIdle(value);
    const found = findOrigin(host, options.port, bundle) orelse
        (makeOrigin(host, options.port, bundle) catch {
            state_lock.unlock();
            return acquired(.Busy, 0);
        });
    const result = lend(found.pool, maximum_pools + found.index, deadline, deadline, options.reuse_idle);
    state_lock.lock();
    dropOriginIfUnused(found.index);
    state_lock.unlock();
    return result;
}

const FoundOrigin = struct { pool: *Pool, index: usize };

fn findOrigin(host: []const u8, port: u16, bundle: ?*std.crypto.Certificate.Bundle) ?FoundOrigin {
    for (origins.items, 0..) |item, index| {
        const pool = item orelse continue;
        if (pool.port == port and pool.bundle == bundle and std.mem.eql(u8, pool.host, host)) return .{ .pool = pool, .index = index };
    }
    return null;
}

fn makeOrigin(host: []const u8, port: u16, bundle: ?*std.crypto.Certificate.Bundle) error{ OutOfMemory, TooMany }!FoundOrigin {
    const index = for (origins.items, 0..) |item, index| {
        if (item == null) break index;
    } else blk: {
        if (origins.items.len >= maximum_origins) return error.TooMany;
        try origins.append(std.heap.smp_allocator, null);
        break :blk origins.items.len - 1;
    };
    const pool = try std.heap.smp_allocator.create(Pool);
    errdefer std.heap.smp_allocator.destroy(pool);
    const connections = try std.heap.smp_allocator.alloc(Connection, connectionsPerOrigin());
    errdefer std.heap.smp_allocator.free(connections);
    @memset(connections, .{});
    const stored_host = try std.heap.smp_allocator.dupe(u8, host);
    pool.* = .{
        .host = stored_host,
        .port = port,
        .origin = true,
        .bundle = bundle,
        .tls_later = false,
        .connect_timeout_milliseconds = 0,
        .acquire_timeout_milliseconds = 0,
        .connections = connections,
    };
    origins.items[index] = pool;
    return .{ .pool = pool, .index = index };
}

/// Frees an origin pool with no connections and no waiters.
fn dropOriginIfUnused(index: usize) void {
    const pool = origins.items[index] orelse return;
    if (pool.waiters.items.len != 0) return;
    for (pool.connections) |connection| {
        if (connection.state != .empty) return;
    }
    pool.waiters.deinit(std.heap.smp_allocator);
    std.heap.smp_allocator.free(pool.connections);
    std.heap.smp_allocator.free(pool.host);
    std.heap.smp_allocator.destroy(pool);
    origins.items[index] = null;
}

/// Closes origin connections idle for longer than the limit. Runs when an
/// origin connection is lent or returned, so an idle connection may stay
/// open past the limit while no origin traffic happens; the check before
/// lending replaces one the server has closed.
fn closeExpiredIdle(now: u64) void {
    for (origins.items, 0..) |item, index| {
        const pool = item orelse continue;
        for (pool.connections) |*connection| {
            if (connection.state == .idle and now -| connection.idle_since >= origin_limits.idle_nanoseconds) connection.close();
        }
        dropOriginIfUnused(index);
    }
}

/// Closes the oldest idle origin connections beyond the limit across all
/// origins.
fn closeExcessIdle() void {
    while (true) {
        var count: usize = 0;
        var oldest: ?*Connection = null;
        var oldest_index: usize = 0;
        for (origins.items, 0..) |item, index| {
            const pool = item orelse continue;
            for (pool.connections) |*connection| {
                if (connection.state != .idle) continue;
                count += 1;
                if (oldest == null or connection.idle_since < oldest.?.idle_since) {
                    oldest = connection;
                    oldest_index = index;
                }
            }
        }
        if (count <= idleOriginConnections()) return;
        oldest.?.close();
        dropOriginIfUnused(oldest_index);
    }
}

pub fn hostedTcpRelease(handle: u64) callconv(std.builtin.CallingConvention.c) void {
    state_lock.lock();
    defer state_lock.unlock();
    const lease = leaseOfLocked(handle) orelse return;
    lease.pool.noteReturned(lease.connection);
    lease.connection.clearScopes();
    if (lease.connection.broken) {
        lease.connection.close();
    } else {
        lease.connection.state = .idle;
        lease.connection.new = false;
        lease.connection.holder = null;
        lease.connection.lent_at = 0;
    }
    lease.pool.wakeOne();
    if (!lease.pool.origin) return;
    // A pool with waiters keeps its connections: one of them takes this one.
    const now = tcp.monotonicNanoseconds() catch 0;
    lease.connection.idle_since = now;
    if (now != 0) closeExpiredIdle(now);
    closeExcessIdle();
    const pool_number: usize = @intCast(handle >> 48);
    if (poolAt(pool_number - 1) != null) dropOriginIfUnused(pool_number - 1 - maximum_pools);
}

/// Closes the connections lent to a request that crashed: its Roc code will
/// not release them, and what was half sent on them is unknown.
pub fn closeHeldBy(target: *fiber.Fiber) void {
    state_lock.lock();
    defer state_lock.unlock();
    for (0..maximum_pools + origins.items.len) |pool_index| {
        const pool = poolAt(pool_index) orelse continue;
        var closed = false;
        for (pool.connections) |*connection| {
            if (connection.state != .lent or connection.holder != target) continue;
            pool.noteReturned(connection);
            connection.close();
            pool.wakeOne();
            closed = true;
        }
        if (closed and pool.origin) dropOriginIfUnused(pool_index - maximum_pools);
    }
}

pub fn hostedTcpIsNew(handle: u64) callconv(std.builtin.CallingConvention.c) bool {
    const lease = leaseOf(handle) orelse return false;
    return lease.connection.new;
}

pub fn hostedTcpOpenScope(handle: u64) callconv(std.builtin.CallingConvention.c) u64 {
    const lease = leaseOf(handle) orelse return 0;
    return lease.connection.openScope();
}

pub fn hostedTcpCloseScope(handle: u64, id: u64) callconv(std.builtin.CallingConvention.c) void {
    const lease = leaseOf(handle) orelse return;
    lease.connection.closeScope(id);
}

pub fn hostedTcpScopeActive(handle: u64, id: u64) callconv(std.builtin.CallingConvention.c) bool {
    const lease = leaseOf(handle) orelse return false;
    return std.mem.indexOfScalar(u64, lease.connection.scopes.items, id) != null;
}

pub fn hostedTcpDiscard(handle: u64) callconv(std.builtin.CallingConvention.c) void {
    const lease = leaseOf(handle) orelse return;
    lease.connection.broken = true;
}

fn sendBytes(connection: *Connection, bytes: []const u8, timeout_milliseconds: u64) abi.HostTcpSent {
    const deadline = tcp.Deadline.afterMilliseconds(timeout_milliseconds) catch {
        connection.broken = true;
        return .failed;
    };
    const status: abi.HostTcpSent = if (connection.session) |session| blk: {
        const before = session.bytesSent();
        session.setDeadline(deadline);
        session.writeAll(bytes) catch |err| {
            if (session.bytesSent() == before) break :blk .unsent;
            break :blk switch (err) {
                error.Timeout => .timed_out,
                error.Closed => .closed,
                else => .failed,
            };
        };
        break :blk .sent;
    } else blk: {
        var sent: usize = 0;
        tcp.sendAllCounting(connection.socket, bytes, deadline, &sent) catch |err| {
            if (sent == 0) break :blk .unsent;
            break :blk switch (err) {
                error.SendTimeout => .timed_out,
                else => .failed,
            };
        };
        break :blk .sent;
    };
    // A partial write leaves the protocol in an unknown state.
    if (status != .sent) connection.broken = true;
    return status;
}

fn sliceOf(list: abi.RocListWith(u8, false)) []const u8 {
    return if (list.elements_ptr) |pointer| pointer[0..list.len()] else &.{};
}

/// Stops the request at this effect when its client went, or the worker
/// drains, while it waited writing its body, once the effect
/// has cleaned up.
pub fn hostedTcpWrite(handle: u64, bytes: abi.RocListWith(u8, false), timeout_milliseconds: u64) callconv(std.builtin.CallingConvention.c) abi.HostTcpSent {
    const result = hostedTcpWriteInner(handle, bytes, timeout_milliseconds);
    fiber_wait.stopIfStreamEnds();
    return result;
}

fn hostedTcpWriteInner(handle: u64, bytes: abi.RocListWith(u8, false), timeout_milliseconds: u64) abi.HostTcpSent {
    var roc_host = rocHost();
    defer bytes.decref(&roc_host);
    const lease = leaseOf(handle) orelse return .released;
    return sendBytes(lease.connection, sliceOf(bytes), timeout_milliseconds);
}

/// Stops the request at this effect when its client went, or the worker
/// drains, while it waited writing its body, once the effect
/// has cleaned up.
pub fn hostedTcpWriteDerived(handle: u64, secret_handle: u64, program: abi.RocListWith(u8, false), timeout_milliseconds: u64) callconv(std.builtin.CallingConvention.c) abi.HostTcpSent {
    const result = hostedTcpWriteDerivedInner(handle, secret_handle, program, timeout_milliseconds);
    fiber_wait.stopIfStreamEnds();
    return result;
}

/// Writes what a secret expression computes, without the bytes passing
/// through Roc (D14). Unlike `Secret.derive!`, the bytes may contain the
/// secret, since they go only to the server.
fn hostedTcpWriteDerivedInner(handle: u64, secret_handle: u64, program: abi.RocListWith(u8, false), timeout_milliseconds: u64) abi.HostTcpSent {
    var roc_host = rocHost();
    defer program.decref(&roc_host);
    const lease = leaseOf(handle) orelse return .released;
    const bytes = secret.evaluateForWrite(secret_handle, sliceOf(program)) orelse return .refused;
    defer {
        std.crypto.secureZero(u8, bytes);
        std.heap.smp_allocator.free(bytes);
    }
    return sendBytes(lease.connection, bytes, timeout_milliseconds);
}

/// Stops the request at this effect when its client went, or the worker
/// drains, while it waited writing its body, once the effect
/// has cleaned up.
pub fn hostedTcpRead(handle: u64, maximum_bytes: u64, timeout_milliseconds: u64) callconv(std.builtin.CallingConvention.c) abi.HostTcpReceived {
    const result = hostedTcpReadInner(handle, maximum_bytes, timeout_milliseconds);
    fiber_wait.stopIfStreamEnds();
    return result;
}

fn hostedTcpReadInner(handle: u64, maximum_bytes: u64, timeout_milliseconds: u64) abi.HostTcpReceived {
    const lease = leaseOf(handle) orelse return received(.Released);
    const connection = lease.connection;
    // Over the worker's memory limit: read nothing more. The protocol
    // on this connection stops mid-way, so it is not reused.
    if (request_memory.overLimit()) {
        connection.broken = true;
        warnOverloaded();
        return received(.Overloaded);
    }
    const deadline = tcp.Deadline.afterMilliseconds(timeout_milliseconds) catch {
        connection.broken = true;
        return received(.Failed);
    };
    var buffer: [maximum_read_bytes]u8 = undefined;
    const limit = @max(1, @min(buffer.len, std.math.cast(usize, maximum_bytes) orelse buffer.len));
    const count: usize = if (connection.session) |session| blk: {
        session.setDeadline(deadline);
        break :blk session.read(buffer[0..limit]) catch |err| {
            connection.broken = true;
            return received(switch (err) {
                error.Timeout => .TimedOut,
                error.Closed => .Closed,
                else => .Failed,
            });
        };
    } else tcp.receiveUntil(connection.socket, buffer[0..limit], deadline) catch |err| {
        connection.broken = true;
        return received(if (err == error.ReceiveTimeout) .TimedOut else .Failed);
    };
    if (count == 0) {
        connection.broken = true;
        return received(.Closed);
    }
    var roc_host = rocHost();
    const list = request_bridge.rocByteListFromSliceChecked(
        buffer[0..count],
        .{ .roc_host = &roc_host, .try_alloc = runtime.tryAllocWithHost },
    ) catch {
        connection.broken = true;
        return received(.Failed);
    };
    var result: abi.HostTcpReceived = undefined;
    result.tag = .Bytes;
    const payload: *abi.RocListWith(u8, false) = @ptrCast(@alignCast(&result.payload));
    payload.* = list;
    return result;
}

/// Stops the request at this effect when its client went, or the worker
/// drains, while it waited writing its body, once the effect
/// has cleaned up.
pub fn hostedTcpStartTls(handle: u64, timeout_milliseconds: u64) callconv(std.builtin.CallingConvention.c) abi.HostTcpStarted {
    const result = hostedTcpStartTlsInner(handle, timeout_milliseconds);
    fiber_wait.stopIfStreamEnds();
    return result;
}

/// Runs the TLS handshake a `tls_later` pool left for the client to start.
fn hostedTcpStartTlsInner(handle: u64, timeout_milliseconds: u64) abi.HostTcpStarted {
    const lease = leaseOf(handle) orelse return .released;
    const connection = lease.connection;
    const bundle = lease.pool.bundle orelse return .failed;
    if (!lease.pool.tls_later or connection.session != null) return .failed;
    const deadline = tcp.Deadline.afterMilliseconds(timeout_milliseconds) catch return .failed;
    connection.session = tls.Session.connect(connection.socket, lease.pool.host, bundle, deadline) catch |err| {
        connection.broken = true;
        return switch (err) {
            error.Timeout => .timed_out,
            error.Closed => .closed,
            error.TlsFailed => .tls_failed,
            else => .failed,
        };
    };
    return .started;
}

/// Says once per second at most that reads are refused, with the numbers.
fn warnOverloaded() void {
    const now = tcp.monotonicNanoseconds() catch return;
    const last = last_overload_warning.load(std.builtin.AtomicOrder.monotonic);
    if (now -| last < std.time.ns_per_s and last != 0) return;
    if (last_overload_warning.cmpxchgStrong(last, now, std.builtin.AtomicOrder.monotonic, std.builtin.AtomicOrder.monotonic) != null) return;
    var buffer: [160]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "requests hold {d} bytes, over Server.Limits.request_memory ({d}); refusing reads", .{
        request_memory.current(),
        request_memory.limit(),
    }) catch return;
    @import("../diagnostics.zig").warning(message);
}

var last_overload_warning = std.atomic.Value(u64).init(0);

fn received(tag: abi.HostTcpReceivedTag) abi.HostTcpReceived {
    var result: abi.HostTcpReceived = undefined;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    result.tag = tag;
    return result;
}

test "handles name the pool, the slot, and the lease" {
    const handle = handleOf(2, 7, 0xdeadbeef);
    try std.testing.expectEqual(@as(u64, 3), handle >> 48);
    try std.testing.expectEqual(@as(u64, 7), (handle >> 32) & 0xffff);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), @as(u32, @truncate(handle)));
    try std.testing.expectEqual(@as(?Lease, null), leaseOf(handle));
    try std.testing.expectEqual(@as(?Lease, null), leaseOf(0));
}

test "scopes end independently and cannot revive in a sibling or a later lease" {
    var connections = [_]Connection{.{ .state = State.lent, .generation = 1 }};
    var pool = Pool{
        .host = &.{},
        .port = 1,
        .bundle = null,
        .tls_later = false,
        .connect_timeout_milliseconds = 1,
        .acquire_timeout_milliseconds = 1,
        .connections = &connections,
    };
    pools[0] = &pool;
    defer pools[0] = null;
    defer connections[0].close();
    const handle = handleOf(0, 0, 1);
    const outer = hostedTcpOpenScope(handle);
    const inner = hostedTcpOpenScope(handle);
    try std.testing.expect(outer != 0 and inner != 0);
    try std.testing.expect(hostedTcpScopeActive(handle, outer));
    try std.testing.expect(hostedTcpScopeActive(handle, inner));
    hostedTcpCloseScope(handle, inner);
    try std.testing.expect(!hostedTcpScopeActive(handle, inner));
    try std.testing.expect(hostedTcpScopeActive(handle, outer));
    const sibling = hostedTcpOpenScope(handle);
    try std.testing.expect(sibling != inner);
    try std.testing.expect(!hostedTcpScopeActive(handle, inner));
    hostedTcpCloseScope(handle, outer);
    try std.testing.expect(!hostedTcpScopeActive(handle, sibling));
    const remaining = hostedTcpOpenScope(handle);
    hostedTcpRelease(handle);
    try std.testing.expect(!hostedTcpScopeActive(handle, remaining));
    connections[0].state = State.lent;
    connections[0].generation = 2;
    const later_handle = handleOf(0, 0, 2);
    const later_scope = hostedTcpOpenScope(later_handle);
    try std.testing.expect(hostedTcpScopeActive(later_handle, later_scope));
    try std.testing.expect(!hostedTcpScopeActive(handle, later_scope));
    try std.testing.expect(!hostedTcpScopeActive(later_handle, remaining));
}

test "scope identifiers stop at their upper bound instead of wrapping" {
    var connection = Connection{ .next_scope = std.math.maxInt(u64) - 2 };
    defer connection.close();
    // The last two representable IDs are valid; a further request must
    // fail, since reusing an old ID could revive an escaped scope.
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, connection.openScope());
    try std.testing.expectEqual(std.math.maxInt(u64), connection.openScope());
    try std.testing.expectEqual(@as(u64, 0), connection.openScope());
}

fn testIdleOrigin(host: []const u8, idle_since: []const u64) !FoundOrigin {
    const found = try makeOrigin(host, 443, null);
    for (idle_since, 0..) |since, slot| {
        found.pool.connections[slot] = .{ .state = State.idle, .idle_since = since };
    }
    return found;
}

fn clearOrigins() void {
    for (origins.items, 0..) |item, index| {
        const pool = item orelse continue;
        for (pool.connections) |*connection| connection.close();
        dropOriginIfUnused(index);
    }
    origins.clearRetainingCapacity();
}

test "origin pools are found by host, port, and CA, and dropped when empty" {
    defer clearOrigins();
    const first = try testIdleOrigin("a.example", &.{1});
    try std.testing.expectEqual(first.pool, findOrigin("a.example", 443, null).?.pool);
    try std.testing.expectEqual(@as(?FoundOrigin, null), findOrigin("a.example", 80, null));
    try std.testing.expectEqual(@as(?FoundOrigin, null), findOrigin("b.example", 443, null));
    try std.testing.expectEqual(first.pool, poolAt(maximum_pools + first.index).?);

    // A pool with an idle connection stays; once empty it goes, and its
    // index is reused.
    dropOriginIfUnused(first.index);
    try std.testing.expect(findOrigin("a.example", 443, null) != null);
    first.pool.connections[0].close();
    dropOriginIfUnused(first.index);
    try std.testing.expectEqual(@as(?FoundOrigin, null), findOrigin("a.example", 443, null));
    const second = try makeOrigin("b.example", 443, null);
    try std.testing.expectEqual(first.index, second.index);
    dropOriginIfUnused(second.index);
}

test "idle origin connections close after the idle limit" {
    defer clearOrigins();
    const now = 1_000 * std.time.ns_per_s;
    const found = try testIdleOrigin("a.example", &.{ now - origin_limits.idle_nanoseconds, now - origin_limits.idle_nanoseconds + 1 });
    closeExpiredIdle(now);
    try std.testing.expectEqual(State.empty, found.pool.connections[0].state);
    try std.testing.expectEqual(State.idle, found.pool.connections[1].state);
    closeExpiredIdle(now + 1);
    try std.testing.expectEqual(@as(?FoundOrigin, null), findOrigin("a.example", 443, null));
}

test "idle origin connections beyond the limit close oldest first, across origins" {
    defer clearOrigins();
    var older: [default_connections_per_origin]u64 = undefined;
    for (&older, 0..) |*since, index| since.* = 100 + index;
    var newer: [default_idle_origin_connections - default_connections_per_origin + 2]u64 = undefined;
    for (&newer, 0..) |*since, index| since.* = 1_000 + index;
    const a = try testIdleOrigin("a.example", &older);
    const b = try testIdleOrigin("b.example", &newer);
    closeExcessIdle();
    try std.testing.expectEqual(State.empty, a.pool.connections[0].state);
    try std.testing.expectEqual(State.empty, a.pool.connections[1].state);
    try std.testing.expectEqual(State.idle, a.pool.connections[2].state);
    for (b.pool.connections[0..newer.len]) |connection| try std.testing.expectEqual(State.idle, connection.state);
}

test "a woken waiter stays listed until it runs, and each wake picks the next" {
    var connections = [_]Connection{.{}};
    var pool = Pool{
        .host = &.{},
        .port = 1,
        .bundle = null,
        .tls_later = false,
        .connect_timeout_milliseconds = 1,
        .acquire_timeout_milliseconds = 1,
        .connections = &connections,
    };
    defer pool.waiters.deinit(std.heap.smp_allocator);
    var first: fiber.Fiber = undefined;
    var second: fiber.Fiber = undefined;
    first.wait_serial = 3;
    second.wait_serial = 7;
    first.wait.expires_at_nanoseconds = 5;
    second.wait.expires_at_nanoseconds = 5;
    try pool.waiters.append(std.heap.smp_allocator, .{ .target = &first, .serial = 3 });
    try pool.waiters.append(std.heap.smp_allocator, .{ .target = &second, .serial = 7 });
    pool.wakeOne();
    try std.testing.expectEqual(@as(u64, 0), first.wait.expires_at_nanoseconds);
    try std.testing.expectEqual(@as(u64, 5), second.wait.expires_at_nanoseconds);
    try std.testing.expectEqual(@as(usize, 2), pool.waiters.items.len);
    pool.wakeOne();
    try std.testing.expectEqual(@as(u64, 0), second.wait.expires_at_nanoseconds);
    pool.wakeOne();
}

test "removing before at or after the next waiter preserves wake order" {
    // The next waiter is index 1: remove its immediate predecessor, itself,
    // or its immediate successor. Removal may be a wake completion or timeout.
    for ([_]usize{ 0, 1, 2 }) |removed| {
        var pool = Pool{
            .host = &.{},
            .port = 1,
            .bundle = null,
            .tls_later = false,
            .connect_timeout_milliseconds = 1,
            .acquire_timeout_milliseconds = 1,
            .connections = &.{},
        };
        defer pool.waiters.deinit(std.heap.smp_allocator);
        var targets: [3]fiber.Fiber = undefined;
        for (&targets) |*target| {
            target.wait_serial = 1;
            target.wait.expires_at_nanoseconds = 5;
            try pool.waiters.append(std.heap.smp_allocator, .{ .target = target, .serial = 1 });
        }
        pool.wakeOne();
        pool.removeWaiter(&targets[removed]);
        for (&targets, 0..) |*target, index| {
            if (index == removed or index == 0) continue;
            try std.testing.expectEqual(@as(u64, 5), target.wait.expires_at_nanoseconds);
            pool.wakeOne();
            try std.testing.expectEqual(@as(u64, 0), target.wait.expires_at_nanoseconds);
        }
        pool.wakeOne(); // All remaining entries are already woken.
        for (&targets) |*target| pool.removeWaiter(target);
        try std.testing.expectEqual(@as(usize, 0), pool.waiters.items.len);
        targets[0].wait.expires_at_nanoseconds = 5;
        try pool.waiters.append(std.heap.smp_allocator, .{ .target = &targets[0], .serial = 1 });
        pool.wakeOne();
        try std.testing.expectEqual(@as(u64, 0), targets[0].wait.expires_at_nanoseconds);
    }
}
