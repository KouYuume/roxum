const std = @import("std");
const builtin = @import("builtin");
const deadline = @import("deadline.zig");
const errno = @import("errno.zig");

const E = std.c.E;
const POLL = std.c.POLL;

const listen_backlog: c_int = 256;

/// Outcome of waiting for a socket on a request fiber.
pub const FiberWait = enum { ready, timed_out };

/// Set by the Roc thread before it serves requests. On a request fiber it
/// suspends the fiber until the socket reports one of the `poll` events, an
/// error, or a hang-up, or until the deadline (monotonic nanoseconds)
/// passes, so the thread serves other requests meanwhile. It returns null
/// off a fiber, and then the caller polls by itself.
pub var fiber_wait: ?*const fn (socket_fd: Socket, events: i16, expires_at_nanoseconds: u64) ?FiberWait = null;
const non_blocking_flag: c_int = @bitCast(std.c.O{ .NONBLOCK = true });

extern "c" fn socket(
    domain: c_int,
    socket_type: c_int,
    protocol: c_int,
) c_int;

extern "c" fn setsockopt(
    socket_fd: c_int,
    level: c_int,
    option_name: c_int,
    option_value: *const anyopaque,
    option_length: SockLen,
) c_int;

extern "c" fn bind(
    socket_fd: c_int,
    address: *const SockAddr,
    address_length: SockLen,
) c_int;

extern "c" fn listen(
    socket_fd: c_int,
    backlog: c_int,
) c_int;

extern "c" fn getsockname(
    socket_fd: c_int,
    address: *SockAddr,
    address_length: *SockLen,
) c_int;

extern "c" fn accept(
    socket_fd: c_int,
    address: ?*SockAddr,
    address_length: ?*SockLen,
) c_int;

extern "c" fn recv(
    socket_fd: c_int,
    buffer: *anyopaque,
    length: usize,
    flags: c_int,
) isize;

extern "c" fn send(
    socket_fd: c_int,
    buffer: *const anyopaque,
    length: usize,
    flags: c_int,
) isize;

extern "c" fn writev(
    socket_fd: c_int,
    iovecs: [*]const std.posix.iovec_const,
    iovec_count: c_int,
) isize;

extern "c" fn poll(
    descriptors: [*]std.c.pollfd,
    descriptor_count: std.c.nfds_t,
    timeout_milliseconds: c_int,
) c_int;

extern "c" fn fcntl(
    file_descriptor: c_int,
    command: c_int,
    ...,
) c_int;

extern "c" fn close(socket_fd: c_int) c_int;

extern "c" fn connect(
    socket_fd: c_int,
    address: *const SockAddr,
    address_length: SockLen,
) c_int;

extern "c" fn getsockopt(
    socket_fd: c_int,
    level: c_int,
    option_name: c_int,
    option_value: *anyopaque,
    option_length: *SockLen,
) c_int;

pub const Socket = c_int;
const SockLen = u32;

const SockAddr = std.c.sockaddr;
const SockAddrIn = std.c.sockaddr.in;

pub const Deadline = deadline.Deadline;
pub const monotonicNanoseconds = deadline.monotonicNanoseconds;

pub const UnixPath = @import("unix_path.zig").Path;
pub const OwnedUnixPath = @import("unix_path.zig").Owned;
pub const Endpoint = union(enum) { tcp: struct { address: IpAddress, port: u16 }, unix: UnixPath };
pub const PeerAddress = union(enum) { v4: [4]u8, v6: [8]u16, unix };

pub const Listener = struct {
    socket: Socket,
    port: u16,
    unix_path: ?OwnedUnixPath = null,

    pub fn cleanup(self: *const Listener) void {
        if (self.unix_path) |path| path.remove();
    }
};

pub const IpAddress = union(enum) { v4: [4]u8, v6: [8]u16 };

pub const AcceptedSocket = struct {
    socket: Socket,
    remote_address: PeerAddress,
    remote_port: u16,
};

pub const Error = error{
    SocketFailed,
    InvalidUnixPath,
    SocketPathFailed,
    SetSocketOptionFailed,
    BindFailed,
    ListenFailed,
    GetSocketNameFailed,
    ReceiveFailed,
    SendFailed,
    PollFailed,
    ClockFailed,
    ReceiveTimeout,
    SendTimeout,
    SetNonBlockingFailed,
};

pub fn closeSocket(socket_fd: Socket) void {
    _ = close(socket_fd);
}

pub const ConnectError = error{ ConnectFailed, ConnectTimeout, ClockFailed };

/// Opens a non-blocking TCP connection to `address` (IPv4 or IPv6), waiting
/// for the handshake no later than `connect_deadline`.
pub fn connectUntil(
    address: *const SockAddr,
    address_length: u32,
    connect_deadline: Deadline,
) ConnectError!Socket {
    const socket_fd = socket(address.family, std.c.SOCK.STREAM, 0);
    if (socket_fd == -1) return error.ConnectFailed;
    errdefer closeSocket(socket_fd);
    if (!setCloseOnExec(socket_fd)) return error.ConnectFailed;
    if (@hasDecl(std.c.SO, "NOSIGPIPE")) {
        enableSocketOption(socket_fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE) catch return error.ConnectFailed;
    }
    setNonBlocking(socket_fd) catch return error.ConnectFailed;
    if (connect(socket_fd, address, address_length) == -1) {
        if (errno.lastError() != E.INPROGRESS) return error.ConnectFailed;
        waitFor(socket_fd, POLL.OUT, connect_deadline, error.SendTimeout) catch |err| return switch (err) {
            error.SendTimeout => error.ConnectTimeout,
            error.ClockFailed => error.ClockFailed,
            else => error.ConnectFailed,
        };
        var failure: c_int = 0;
        var length: SockLen = @sizeOf(c_int);
        if (getsockopt(socket_fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &failure, &length) == -1 or failure != 0) {
            return error.ConnectFailed;
        }
    }
    enableSocketOption(socket_fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY) catch return error.ConnectFailed;
    return socket_fd;
}

/// Waits until `socket_fd` is readable, has failed, or hung up, or until
/// `io_deadline`; on a request fiber the fiber waits instead of the thread.
pub fn waitReadable(socket_fd: Socket, io_deadline: Deadline) Error!void {
    return waitFor(socket_fd, POLL.IN, io_deadline, error.ReceiveTimeout);
}

/// Whether an idle connection the peer may have closed is still quiet:
/// nothing to read, no error, no hang-up. Does not wait.
pub fn isQuiet(socket_fd: Socket) bool {
    var descriptor = std.c.pollfd{ .fd = socket_fd, .events = POLL.IN, .revents = 0 };
    const descriptors: [*]std.c.pollfd = @ptrCast(&descriptor);
    return poll(descriptors, 1, 0) == 0;
}

pub fn listenIpv4(address_octets: [4]u8, port: u16) Error!Listener {
    const socket_fd = try openConfiguredSocket(std.c.AF.INET);
    errdefer closeSocket(socket_fd);

    var address = SockAddrIn{
        .port = hostToNetwork16(port),
        .addr = @bitCast(address_octets),
    };

    if (bind(
        socket_fd,
        @ptrCast(&address),
        @sizeOf(SockAddrIn),
    ) == -1) return error.BindFailed;

    if (listen(
        socket_fd,
        listen_backlog,
    ) == -1) return error.ListenFailed;

    var address_length: SockLen = @sizeOf(SockAddrIn);
    if (getsockname(
        socket_fd,
        @ptrCast(&address),
        &address_length,
    ) == -1) return error.GetSocketNameFailed;

    return .{
        .socket = socket_fd,
        .port = networkToHost16(address.port),
    };
}

pub fn listenAddress(address: IpAddress, port: u16) Error!Listener {
    return switch (address) {
        IpAddress.v4 => |octets| listenIpv4(octets, port),
        IpAddress.v6 => |segments| listenIpv6(segments, port),
    };
}

pub fn listenIpv6(segments: [8]u16, port: u16) Error!Listener {
    const fd = try openConfiguredSocket(std.c.AF.INET6);
    errdefer closeSocket(fd);
    // A V6 listener never admits mapped IPv4 peers, regardless of OS defaults.
    try enableSocketOption(fd, std.c.IPPROTO.IPV6, std.c.IPV6.V6ONLY);
    var address = std.c.sockaddr.in6{ .port = hostToNetwork16(port), .flowinfo = 0, .addr = undefined, .scope_id = 0 };
    for (segments, 0..) |segment, i| std.mem.writeInt(u16, address.addr[i * 2 ..][0..2], segment, std.builtin.Endian.big);
    if (bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) == -1) return error.BindFailed;
    if (listen(fd, listen_backlog) == -1) return error.ListenFailed;
    var length: SockLen = @sizeOf(@TypeOf(address));
    if (getsockname(fd, @ptrCast(&address), &length) == -1) return error.GetSocketNameFailed;
    return .{ .socket = fd, .port = networkToHost16(address.port) };
}

pub fn listenEndpoint(endpoint: Endpoint) Error!Listener {
    return switch (endpoint) {
        Endpoint.tcp => |tcp| listenAddress(tcp.address, tcp.port),
        Endpoint.unix => |path| listenUnix(path),
    };
}

fn listenUnix(path: UnixPath) Error!Listener {
    const fd = try openConfiguredSocket(std.c.AF.UNIX);
    errdefer closeSocket(fd);
    var address = std.c.sockaddr.un{ .path = @splat(0) };
    @memcpy(address.path[0..path.slice().len], path.slice());
    if (bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) == -1) return error.BindFailed;
    const owned = try OwnedUnixPath.capture(path);
    errdefer owned.remove();
    if (listen(fd, listen_backlog) == -1) return error.ListenFailed;
    return .{ .socket = fd, .port = 0, .unix_path = owned };
}

pub const PendingAccept = union(enum) {
    accepted: AcceptedSocket,
    /// No connection is waiting on the non-blocking listener.
    none,
    /// The process or system is out of file descriptors; the connection stays
    /// queued until a descriptor is released.
    exhausted,
    /// `accept` failed for a reason that is not about one connection (for
    /// example a firewall's EPERM on Linux). Retry later.
    failed,
};

/// Makes `accept` on a shared listener return instead of blocking. The flag
/// belongs to the open file description, so every process sharing the
/// listener sees it.
pub fn setListenerNonBlocking(listener: Socket) Error!void {
    return setNonBlocking(listener);
}

/// Accepts one connection from a non-blocking listener. Never fails: a
/// problem with one connection is skipped, and a problem with the listener
/// is reported as `failed` for the caller to retry later.
pub fn acceptPending(listener: Socket) PendingAccept {
    while (true) {
        var address: std.c.sockaddr.storage = undefined;
        var address_length: SockLen = @sizeOf(@TypeOf(address));
        const client = acceptNonBlocking(listener, &address, &address_length);
        if (client != -1) {
            // The connection is useless without non-blocking I/O, but the
            // listener is fine; drop this one and keep accepting.
            if (!accept_sets_flags) {
                setNonBlocking(client) catch {
                    closeSocket(client);
                    continue;
                };
            }
            const remote: PeerAddress, const remote_port: u16 = switch (address.family) {
                std.c.AF.INET => blk: {
                    const v4: *const SockAddrIn = @ptrCast(@alignCast(&address));
                    break :blk .{ PeerAddress{ .v4 = @bitCast(v4.addr) }, networkToHost16(v4.port) };
                },
                std.c.AF.INET6 => blk: {
                    const v6: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(&address));
                    var segments: [8]u16 = undefined;
                    for (&segments, 0..) |*segment, i| segment.* = std.mem.readInt(u16, v6.addr[i * 2 ..][0..2], std.builtin.Endian.big);
                    break :blk .{ PeerAddress{ .v6 = segments }, networkToHost16(v6.port) };
                },
                std.c.AF.UNIX => .{ PeerAddress.unix, 0 },
                else => {
                    closeSocket(client);
                    continue;
                },
            };
            return .{ .accepted = .{
                .socket = client,
                .remote_address = remote,
                .remote_port = remote_port,
            } };
        }
        switch (classifyAccept(errno.lastError())) {
            AcceptDisposition.retry => continue,
            AcceptDisposition.none => return PendingAccept.none,
            AcceptDisposition.exhausted => return PendingAccept.exhausted,
            AcceptDisposition.failed => return PendingAccept.failed,
        }
    }
}

/// Linux sets non-blocking and close-on-exec in the accept call itself;
/// other systems need two `fcntl` calls after it.
const accept_sets_flags = builtin.os.tag == std.Target.Os.Tag.linux;

fn acceptNonBlocking(listener: Socket, address: *std.c.sockaddr.storage, address_length: *SockLen) c_int {
    if (accept_sets_flags) {
        const flags: c_uint = std.c.SOCK.NONBLOCK | std.c.SOCK.CLOEXEC;
        return std.c.accept4(listener, @ptrCast(address), address_length, flags);
    }
    return accept(listener, @ptrCast(address), address_length);
}

const AcceptDisposition = enum { retry, none, exhausted, failed };

fn classifyAccept(accept_error: E) AcceptDisposition {
    return switch (accept_error) {
        E.INTR => AcceptDisposition.retry,
        E.AGAIN => AcceptDisposition.none,
        E.MFILE, E.NFILE, E.NOBUFS, E.NOMEM => AcceptDisposition.exhausted,
        else => if (isAbortedConnection(accept_error))
            AcceptDisposition.retry
        else
            AcceptDisposition.failed,
    };
}

/// Sends FIN while keeping the read side open, so the peer sees the end of
/// the response before the socket is closed. False when the connection is
/// already gone; the caller then closes at once.
pub fn shutdownWrite(socket_fd: Socket) bool {
    return std.c.shutdown(socket_fd, std.c.SHUT.WR) == 0;
}

/// Reads what the socket already holds. `null` means no bytes are ready; `0`
/// means the peer closed its side.
/// `FIONREAD`: Linux's value depends on the architecture; macOS's is
/// `_IOR('f', 127, int)`, which its `std.c.T` does not define.
const fionread: c_int = switch (builtin.os.tag) {
    .linux => @intCast(std.os.linux.T.FIONREAD),
    .macos => 0x4004667f,
    else => @compileError("unsupported OS"),
};

/// How many received bytes wait in the socket, or null if the kernel does not
/// say. Only bytes the peer has sent are counted.
pub fn bytesAvailable(socket_fd: Socket) ?usize {
    var count: c_int = 0;
    if (std.c.ioctl(socket_fd, fionread, &count) != 0) return null;
    if (count < 0) return null;
    return @intCast(count);
}

pub fn receiveAvailable(socket_fd: Socket, buffer: []u8) Error!?usize {
    while (true) {
        const result = recv(
            socket_fd,
            buffer.ptr,
            buffer.len,
            0,
        );
        if (result >= 0) return @intCast(result);
        switch (errno.lastError()) {
            E.INTR => continue,
            E.AGAIN => return null,
            else => return error.ReceiveFailed,
        }
    }
}

pub fn receiveUntil(
    socket_fd: Socket,
    buffer: []u8,
    receive_deadline: Deadline,
) Error!usize {
    while (true) {
        try waitFor(
            socket_fd,
            POLL.IN,
            receive_deadline,
            error.ReceiveTimeout,
        );
        const result = recv(
            socket_fd,
            buffer.ptr,
            buffer.len,
            0,
        );
        if (result >= 0) return @intCast(result);
        const receive_error = errno.lastError();
        if (receive_error == E.INTR or
            receive_error == E.AGAIN)
        {
            continue;
        }
        return error.ReceiveFailed;
    }
}

pub fn sendAllUntil(
    socket_fd: Socket,
    bytes: []const u8,
    send_deadline: Deadline,
) Error!void {
    var sent: usize = 0;
    return sendAllCounting(socket_fd, bytes, send_deadline, &sent);
}

/// `sendAllUntil`, adding to `sent` the bytes the kernel accepted, so a
/// caller can tell a failure before the first byte from one in the middle.
pub fn sendAllCounting(
    socket_fd: Socket,
    bytes: []const u8,
    send_deadline: Deadline,
    total: *usize,
) Error!void {
    var sent: usize = 0;
    defer total.* += sent;

    while (sent < bytes.len) {
        try waitFor(
            socket_fd,
            POLL.OUT,
            send_deadline,
            error.SendTimeout,
        );
        const result = send(
            socket_fd,
            bytes[sent..].ptr,
            bytes.len - sent,
            0,
        );

        if (result > 0) {
            sent += @intCast(result);
            continue;
        }
        if (result == -1) {
            const send_error = errno.lastError();
            if (send_error == E.INTR or send_error == E.AGAIN) continue;
        }
        return error.SendFailed;
    }
}

/// Writes what the socket accepts now without waiting. Returns 0 when the
/// send buffer is full.
pub fn sendIovecsAvailable(
    socket_fd: Socket,
    iovecs: []const std.posix.iovec_const,
) Error!usize {
    if (iovecs.len == 0) return 0;
    std.debug.assert(iovecs.len <= std.math.maxInt(c_int));

    while (true) {
        const result = writev(
            socket_fd,
            iovecs.ptr,
            @intCast(iovecs.len),
        );
        if (result >= 0) return @intCast(result);
        switch (errno.lastError()) {
            E.INTR => continue,
            E.AGAIN => return 0,
            else => return error.SendFailed,
        }
    }
}

/// Sends what the socket accepts now without waiting. Returns 0 when the
/// send buffer is full.
pub fn sendAvailable(socket_fd: Socket, bytes: []const u8) Error!usize {
    if (bytes.len == 0) return 0;
    while (true) {
        const result = send(
            socket_fd,
            bytes.ptr,
            bytes.len,
            0,
        );
        if (result >= 0) return @intCast(result);
        switch (errno.lastError()) {
            E.INTR => continue,
            E.AGAIN => return 0,
            else => return error.SendFailed,
        }
    }
}

pub fn sendIovecsUntil(
    socket_fd: Socket,
    iovecs: []const std.posix.iovec_const,
    send_deadline: Deadline,
) Error!usize {
    if (iovecs.len == 0) return 0;
    std.debug.assert(iovecs.len <= std.math.maxInt(c_int));

    while (true) {
        try waitFor(
            socket_fd,
            POLL.OUT,
            send_deadline,
            error.SendTimeout,
        );
        const result = writev(
            socket_fd,
            iovecs.ptr,
            @intCast(iovecs.len),
        );
        if (result >= 0) return @intCast(result);
        const write_error = errno.lastError();
        if (write_error == E.INTR or
            write_error == E.AGAIN)
        {
            continue;
        }
        return error.SendFailed;
    }
}

fn waitFor(
    socket_fd: Socket,
    events: i16,
    io_deadline: Deadline,
    timeout_error: Error,
) Error!void {
    if ((io_deadline.remainingPollMilliseconds() catch return error.ClockFailed) == null) return timeout_error;
    if (fiber_wait) |wait| {
        if (wait(socket_fd, events, io_deadline.expires_at_nanoseconds)) |outcome| return switch (outcome) {
            FiberWait.ready => {
                if ((io_deadline.remainingPollMilliseconds() catch return error.ClockFailed) == null) return timeout_error;
            },
            FiberWait.timed_out => timeout_error,
        };
    }
    while (true) {
        const timeout = io_deadline.remainingPollMilliseconds() catch
            return error.ClockFailed;
        const timeout_milliseconds = timeout orelse return timeout_error;
        var descriptor = std.c.pollfd{
            .fd = socket_fd,
            .events = events,
            .revents = 0,
        };
        const descriptors: [*]std.c.pollfd = @ptrCast(&descriptor);
        const result = poll(descriptors, 1, timeout_milliseconds);
        if (result == 0) return timeout_error;
        if (result == -1) {
            if (errno.lastError() == E.INTR) continue;
            return error.PollFailed;
        }
        if ((descriptor.revents & POLL.NVAL) != 0) return error.PollFailed;
        if ((descriptor.revents &
            (events | POLL.ERR | POLL.HUP)) != 0)
        {
            return;
        }
    }
}

/// Linux reports a new connection's pending network error from `accept`. The
/// error belongs to that connection, so the listener keeps accepting.
fn isAbortedConnection(accept_error: E) bool {
    if (accept_error == E.CONNABORTED) return true;
    return switch (builtin.os.tag) {
        std.Target.Os.Tag.linux => isLinuxPendingNetworkError(accept_error),
        else => false,
    };
}

fn isLinuxPendingNetworkError(accept_error: E) bool {
    return switch (accept_error) {
        E.NETDOWN,
        E.PROTO,
        E.NOPROTOOPT,
        E.HOSTDOWN,
        E.NONET,
        E.HOSTUNREACH,
        E.OPNOTSUPP,
        E.NETUNREACH,
        => true,
        else => false,
    };
}

fn hostToNetwork16(value: u16) u16 {
    return std.mem.nativeToBig(u16, value);
}

fn setNonBlocking(socket_fd: Socket) Error!void {
    const current_flags = fcntl(
        socket_fd,
        std.c.F.GETFL,
    );
    if (current_flags == -1) return error.SetNonBlockingFailed;
    if (fcntl(
        socket_fd,
        std.c.F.SETFL,
        current_flags | non_blocking_flag,
    ) == -1) return error.SetNonBlockingFailed;
}

fn networkToHost16(value: u16) u16 {
    return std.mem.bigToNative(u16, value);
}

/// Keeps `file_descriptor` out of any program a later `exec` starts. The
/// host never execs; this guards descriptors it holds for the process's
/// life against application code or libraries that do.
pub fn setCloseOnExec(file_descriptor: c_int) bool {
    const current_flags = fcntl(file_descriptor, std.c.F.GETFD);
    if (current_flags == -1) return false;
    return fcntl(file_descriptor, std.c.F.SETFD, current_flags | std.posix.FD_CLOEXEC) != -1;
}

fn enableSocketOption(
    socket_fd: Socket,
    level: c_int,
    option_name: c_int,
) Error!void {
    var enabled: c_int = 1;

    if (setsockopt(
        socket_fd,
        level,
        option_name,
        &enabled,
        @sizeOf(c_int),
    ) == -1) return error.SetSocketOptionFailed;
}

fn openConfiguredSocket(family: c_int) Error!Socket {
    const socket_fd = socket(
        family,
        std.c.SOCK.STREAM,
        0,
    );
    if (socket_fd == -1) return error.SocketFailed;
    errdefer closeSocket(socket_fd);
    if (!setCloseOnExec(socket_fd)) return error.SocketFailed;

    try enableSocketOption(
        socket_fd,
        std.c.SOL.SOCKET,
        std.c.SO.REUSEADDR,
    );
    // Linux has no per-socket option; the supervisor ignores SIGPIPE for the
    // whole process instead.
    if (@hasDecl(std.c.SO, "NOSIGPIPE")) {
        try enableSocketOption(
            socket_fd,
            std.c.SOL.SOCKET,
            std.c.SO.NOSIGPIPE,
        );
    }
    if (family != std.c.AF.UNIX) try enableSocketOption(
        socket_fd,
        std.c.IPPROTO.TCP,
        std.c.TCP.NODELAY,
    );

    return socket_fd;
}

test "SockAddrIn keeps the port and address where the IPv4 ABI puts them" {
    try std.testing.expectEqual(
        @as(usize, 16),
        @sizeOf(SockAddrIn),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        @offsetOf(SockAddrIn, "port"),
    );
    try std.testing.expectEqual(
        @as(usize, 4),
        @offsetOf(SockAddrIn, "addr"),
    );
}

test "port byte order conversion is reversible" {
    const ports = [_]u16{
        0,
        1,
        0x1234,
        std.math.maxInt(u16),
    };

    for (ports) |port| {
        const network = hostToNetwork16(port);

        try std.testing.expectEqual(
            port,
            networkToHost16(network),
        );
    }

    try std.testing.expectEqual(
        @as(u16, 0x3412),
        hostToNetwork16(0x1234),
    );
}

test "IPv4 octets preserve their socket address byte layout" {
    const addresses = [_][4]u8{
        .{ 0, 0, 0, 0 },
        .{ 127, 0, 0, 1 },
        .{ 255, 255, 255, 255 },
    };

    for (addresses) |address| {
        const network_value: u32 = @bitCast(address);
        try std.testing.expectEqualSlices(
            u8,
            address[0..],
            std.mem.asBytes(&network_value),
        );
    }
}

test "accept errors are classified by what they say about the listener" {
    try std.testing.expectEqual(AcceptDisposition.retry, classifyAccept(E.INTR));
    try std.testing.expectEqual(AcceptDisposition.retry, classifyAccept(E.CONNABORTED));
    try std.testing.expectEqual(AcceptDisposition.none, classifyAccept(E.AGAIN));
    for ([_]E{ E.MFILE, E.NFILE, E.NOBUFS, E.NOMEM }) |exhausted| {
        try std.testing.expectEqual(AcceptDisposition.exhausted, classifyAccept(exhausted));
    }
    try std.testing.expectEqual(AcceptDisposition.failed, classifyAccept(E.PERM));
    try std.testing.expectEqual(AcceptDisposition.failed, classifyAccept(E.BADF));
    const network_down: AcceptDisposition = if (builtin.os.tag == std.Target.Os.Tag.linux)
        AcceptDisposition.retry
    else
        AcceptDisposition.failed;
    try std.testing.expectEqual(network_down, classifyAccept(E.NETDOWN));
}

test "shutting down the write side ends the peer's reads but keeps ours" {
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
    defer closeSocket(pair[0]);
    defer closeSocket(pair[1]);

    try std.testing.expect(shutdownWrite(pair[0]));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), recv(pair[1], &byte, 1, 0));
    try std.testing.expectEqual(@as(isize, 1), send(pair[1], "x", 1, 0));
    try std.testing.expectEqual(@as(isize, 1), recv(pair[0], &byte, 1, 0));
}

test "expired waits do not enter the fiber hook even for a ready socket" {
    const Probe = struct {
        var called: bool = false;
        fn wait(_: Socket, _: i16, _: u64) ?FiberWait {
            called = true;
            return FiberWait.ready;
        }
    };
    const previous = fiber_wait;
    defer fiber_wait = previous;
    fiber_wait = Probe.wait;
    Probe.called = false;
    try std.testing.expectError(error.ReceiveTimeout, waitReadable(-1, .{ .expires_at_nanoseconds = 0 }));
    try std.testing.expect(!Probe.called);
}

test "bytes available counts what the peer sent and has not been read" {
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
    defer closeSocket(pair[0]);
    defer closeSocket(pair[1]);

    try std.testing.expectEqual(@as(?usize, 0), bytesAvailable(pair[0]));
    try std.testing.expectEqual(@as(isize, 1), send(pair[1], "x", 1, 0));
    try std.testing.expectEqual(@as(?usize, 1), bytesAvailable(pair[0]));
    try std.testing.expectEqual(@as(isize, 3), send(pair[1], "abc", 3, 0));
    try std.testing.expectEqual(@as(?usize, 4), bytesAvailable(pair[0]));
    var bytes: [2]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 2), recv(pair[0], &bytes, 2, 0));
    try std.testing.expectEqual(@as(?usize, 2), bytesAvailable(pair[0]));
    try std.testing.expectEqual(@as(?usize, null), bytesAvailable(-1));
}
