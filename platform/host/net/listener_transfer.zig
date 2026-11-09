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
    admin_address: [4]u8,
    admin_port: u16,
};

/// The admin port's address and port.
pub const Admin = struct {
    address: [4]u8,
    port: u16,
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
        .admin_address = if (admin) |given| given.address else .{ 0, 0, 0, 0 },
        .admin_port = if (admin) |given| given.port else 0,
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
    if (count != @sizeOf(Report) or (message.flags & std.c.MSG.CTRUNC) != 0 or report.port == 0 or
        report.workers == 0 or !net.setCloseOnExec(descriptor))
    {
        net.closeSocket(descriptor);
        return error.ReadinessFailed;
    }
    return .{
        .listener = .{ .socket = descriptor, .port = report.port },
        .workers = report.workers,
        .drain_timeout_milliseconds = report.drain_timeout_milliseconds,
        .admin = if (report.admin_port == 0) null else .{ .address = report.admin_address, .port = report.admin_port },
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
    try send(channels[1], listener, 3, 20_000, .{ .address = .{ 127, 0, 0, 1 }, .port = 9090 });

    const received = (try receive(channels[0])).?;
    defer net.closeSocket(received.listener.socket);
    try std.testing.expectEqual(listener.port, received.listener.port);
    try std.testing.expectEqual(@as(u16, 3), received.workers);
    try std.testing.expectEqual(@as(u64, 20_000), received.drain_timeout_milliseconds);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, received.admin.?.address);
    try std.testing.expectEqual(@as(u16, 9090), received.admin.?.port);

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
