//! Startup-only descriptor transfer; accepted connections never use IPC.
const std = @import("std");
const builtin = @import("builtin");
const errno = @import("errno.zig");
const net = @import("tcp.zig");

const E = std.c.E;

/// `CMSG_ALIGN`: Darwin aligns control data to 4 bytes, Linux to `size_t`.
const control_alignment: usize = switch (builtin.os.tag) {
    std.Target.Os.Tag.linux => @sizeOf(usize),
    else => @sizeOf(u32),
};
const header_space = alignControl(@sizeOf(std.c.cmsghdr));
/// `CMSG_LEN(sizeof(int))`
const control_length = header_space + @sizeOf(c_int);
/// `CMSG_SPACE(sizeof(int))`
const control_space = header_space + alignControl(@sizeOf(c_int));

const ControlBuffer = struct {
    bytes: [control_space]u8 align(@alignOf(usize)) = @as([control_space]u8, @splat(0)),

    fn header(self: *ControlBuffer) *std.c.cmsghdr {
        return @ptrCast(&self.bytes);
    }

    fn descriptor(self: *ControlBuffer) *align(1) c_int {
        return @ptrCast(self.bytes[header_space..][0..@sizeOf(c_int)]);
    }
};

fn alignControl(length: usize) usize {
    return std.mem.alignForward(usize, length, control_alignment);
}

/// What a ready worker reports with its listener: the port, how many
/// workers its `init!` asked for, how long a drain may take, and where the
/// admin port listens (port 0 when it is off).
const Report = extern struct {
    port: u16,
    workers: u16,
    drain_timeout_milliseconds: u64,
    is_unix: u8,
    unix_path: net.OwnedUnixPath,
    admin: EndpointReport,
};

/// The admin port's address and port.
pub const Admin = net.Endpoint;

const EndpointReport = extern struct {
    kind: u8 = 0,
    address: [8]u16 = @splat(0),
    path: net.UnixPath = .{},
    port: u16 = 0,

    fn encode(endpoint: ?Admin) EndpointReport {
        const given = endpoint orelse return .{};
        return switch (given) {
            net.Endpoint.unix => |path| .{ .kind = 3, .path = path },
            net.Endpoint.tcp => |tcp| switch (tcp.address) {
                net.IpAddress.v4 => |v| .{ .kind = 1, .address = .{ v[0], v[1], v[2], v[3], 0, 0, 0, 0 }, .port = tcp.port },
                net.IpAddress.v6 => |v| .{ .kind = 2, .address = v, .port = tcp.port },
            },
        };
    }

    fn decode(self: EndpointReport) !?Admin {
        return switch (self.kind) {
            0 => null,
            1 => blk: {
                var octets: [4]u8 = undefined;
                for (&octets, self.address[0..4]) |*octet, group| octet.* = std.math.cast(u8, group) orelse return error.ReadinessFailed;
                break :blk Admin{ .tcp = .{ .address = .{ .v4 = octets }, .port = self.port } };
            },
            2 => Admin{ .tcp = .{ .address = .{ .v6 = self.address }, .port = self.port } },
            3 => Admin{ .unix = try net.UnixPath.init(self.path.slice()) },
            else => error.ReadinessFailed,
        };
    }
};

pub const Ready = struct {
    listener: net.Listener,
    workers: u16,
    drain_timeout_milliseconds: u64,
    admin: ?Admin,
};

pub fn send(channel: c_int, listener: net.Listener, workers: u16, drain_timeout_milliseconds: u64, admin: ?Admin) !void {
    const report = Report{
        .port = listener.port,
        .workers = workers,
        .drain_timeout_milliseconds = drain_timeout_milliseconds,
        .is_unix = @intFromBool(listener.unix_path != null),
        .unix_path = listener.unix_path orelse std.mem.zeroes(net.OwnedUnixPath),
        .admin = EndpointReport.encode(admin),
    };
    const iov = std.posix.iovec_const{ .base = std.mem.asBytes(&report).ptr, .len = @sizeOf(Report) };
    var control = ControlBuffer{};
    const header = control.header();
    header.len = @intCast(control_length);
    header.level = std.c.SOL.SOCKET;
    header.type = std.c.SCM.RIGHTS;
    control.descriptor().* = listener.socket;
    const message = std.c.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &control.bytes,
        .controllen = @intCast(control_space),
        .flags = 0,
    };
    while (true) {
        const sent = std.c.sendmsg(channel, &message, 0);
        if (sent == @sizeOf(Report)) return;
        if (sent == -1 and errno.lastError() == E.INTR) continue;
        return error.ReadinessFailed;
    }
}

pub fn receive(channel: c_int) !?Ready {
    var report = std.mem.zeroes(Report);
    var iov = std.posix.iovec{ .base = std.mem.asBytes(&report).ptr, .len = @sizeOf(Report) };
    var control = ControlBuffer{};
    var message = std.c.msghdr{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &control.bytes,
        .controllen = @intCast(control_space),
        .flags = 0,
    };
    const count = std.c.recvmsg(channel, &message, std.c.MSG.DONTWAIT);
    if (count < 0) {
        const receive_error = errno.lastError();
        if (receive_error == E.AGAIN or receive_error == E.INTR) return null;
        return error.ReadinessFailed;
    }
    const header = control.header();
    const carries_descriptor = message.controllen >= control_length and
        header.len == control_length and
        header.level == std.c.SOL.SOCKET and header.type == std.c.SCM.RIGHTS;
    if (!carries_descriptor) return error.ReadinessFailed;
    // From here the kernel has installed a descriptor in this process, so
    // every rejection must close it.
    const descriptor = control.descriptor().*;
    if (count != @sizeOf(Report) or (message.flags & std.c.MSG.CTRUNC) != 0 or report.is_unix > 1 or (report.is_unix == 0 and report.port == 0) or
        report.workers == 0 or !net.setCloseOnExec(descriptor))
    {
        net.closeSocket(descriptor);
        return error.ReadinessFailed;
    }
    errdefer net.closeSocket(descriptor);
    if (report.is_unix == 1) _ = try net.UnixPath.init(report.unix_path.path.slice());
    return .{
        .listener = .{ .socket = descriptor, .port = report.port, .unix_path = if (report.is_unix == 1) report.unix_path else null },
        .workers = report.workers,
        .drain_timeout_milliseconds = report.drain_timeout_milliseconds,
        .admin = try report.admin.decode(),
    };
}

test "a listener descriptor crosses a socket pair" {
    var channels: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.DGRAM, 0, &channels));
    defer _ = std.c.close(channels[0]);
    defer _ = std.c.close(channels[1]);

    try std.testing.expectEqual(@as(?Ready, null), try receive(channels[0]));

    const listener = try net.listenIpv4(.{ 127, 0, 0, 1 }, 0);
    defer net.closeSocket(listener.socket);
    try send(channels[1], listener, 3, 20_000, .{ .tcp = .{ .address = .{ .v4 = .{ 127, 0, 0, 1 } }, .port = 9090 } });

    const received = (try receive(channels[0])).?;
    defer net.closeSocket(received.listener.socket);
    try std.testing.expectEqual(listener.port, received.listener.port);
    try std.testing.expectEqual(@as(u16, 3), received.workers);
    try std.testing.expectEqual(@as(u64, 20_000), received.drain_timeout_milliseconds);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, received.admin.?.tcp.address.v4);
    try std.testing.expectEqual(@as(u16, 9090), received.admin.?.tcp.port);

    // Distinct groups expose reordering; byte and U16 boundaries expose truncation.
    const segments = [8]u16{ 0, 1, 255, 256, 257, 0x1234, 65534, 65535 };
    try send(channels[1], listener, 1, 20_000, .{ .tcp = .{ .address = .{ .v6 = segments }, .port = 9090 } });
    const ipv6_admin = (try receive(channels[0])).?;
    defer net.closeSocket(ipv6_admin.listener.socket);
    try std.testing.expectEqual(segments, ipv6_admin.admin.?.tcp.address.v6);
    try std.testing.expectEqual(@as(u16, 9090), ipv6_admin.admin.?.tcp.port);

    try send(channels[1], listener, 1, 20_000, null);
    const without_admin = (try receive(channels[0])).?;
    defer net.closeSocket(without_admin.listener.socket);
    try std.testing.expectEqual(@as(?Admin, null), without_admin.admin);
    try std.testing.expect(received.listener.socket != listener.socket);
}

test "a report of zero workers is refused" {
    var channels: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.DGRAM, 0, &channels));
    defer _ = std.c.close(channels[0]);
    defer _ = std.c.close(channels[1]);

    const listener = try net.listenIpv4(.{ 127, 0, 0, 1 }, 0);
    defer net.closeSocket(listener.socket);
    try send(channels[1], listener, 0, 20_000, null);
    try std.testing.expectError(error.ReadinessFailed, receive(channels[0]));
}
