//! A negotiated session belongs to the slot. The HTTP/1 loop and its request
//! fiber take turns driving it, including retries of a pending TLS write.
const tls = @import("handshake.zig");
const net = @import("../net.zig");
const tcp = @import("../net/tcp.zig");
const std = @import("std");

extern "c" fn roxum_tls_read(*tls.Session, [*]u8, usize) c_int;
extern "c" fn roxum_tls_write(*tls.Session, [*]const u8, usize) c_int;
extern "c" fn roxum_tls_close_notify(*tls.Session) c_int;

pub const Ops = struct {
    read: *const @TypeOf(roxum_tls_read) = roxum_tls_read,
    write: *const @TypeOf(roxum_tls_write) = roxum_tls_write,
    shutdown: *const @TypeOf(roxum_tls_close_notify) = roxum_tls_close_notify,
};
pub const native = Ops{};
pub const Progress = union(enum) { bytes: usize, want_read, want_write, failed };

pub const Stream = struct {
    session: *tls.Session,
    ops: *const Ops,
    failed: bool = false,
    eof: bool = false,
    shutdown_sent: bool = false,

    fn result(self: *Stream, rc: c_int) Progress {
        if (rc >= 0) return .{ .bytes = @intCast(rc) };
        if (rc == -2) return Progress.want_read;
        if (rc == -3) return Progress.want_write;
        self.failed = true;
        return Progress.failed;
    }

    pub fn read(self: *Stream, buffer: []u8) Progress {
        if (self.failed) return Progress.failed;
        if (self.eof) return .{ .bytes = 0 };
        const rc = self.ops.read(self.session, buffer.ptr, buffer.len);
        if (rc == 0) self.eof = true;
        return self.result(rc);
    }

    pub fn write(self: *Stream, bytes: []const u8) Progress {
        if (self.failed) return Progress.failed;
        return self.result(self.ops.write(self.session, bytes.ptr, bytes.len));
    }

    pub fn shutdown(self: *Stream) Progress {
        if (self.failed) return Progress.failed;
        return self.result(self.ops.shutdown(self.session));
    }

    fn wait(self: *Stream, socket: net.Socket, writable: bool, deadline: net.Deadline, timeout: net.Error) net.Error!void {
        tcp.waitFor(socket, if (writable) std.c.POLL.OUT else std.c.POLL.IN, deadline, timeout) catch |err| {
            // An interrupted write must never be retried with another buffer.
            if (err != error.ReceiveTimeout or writable) self.failed = true;
            return err;
        };
    }

    pub fn writeUntil(self: *Stream, socket: net.Socket, bytes: []const u8, deadline: net.Deadline) net.Error!usize {
        if (try deadline.remainingPollMilliseconds() == null) return error.SendTimeout;
        while (true) {
            switch (self.write(bytes)) {
                Progress.bytes => |count| return count,
                Progress.failed => return error.SendFailed,
                Progress.want_read => try self.wait(socket, false, deadline, error.SendTimeout),
                Progress.want_write => try self.wait(socket, true, deadline, error.SendTimeout),
            }
        }
    }
};

pub fn receiveUntil(stream: ?*Stream, socket: net.Socket, buffer: []u8, deadline: net.Deadline) net.Error!usize {
    const session = stream orelse return net.receiveUntil(socket, buffer, deadline);
    if (try deadline.remainingPollMilliseconds() == null) return error.ReceiveTimeout;
    while (true) {
        switch (session.read(buffer)) {
            Progress.bytes => |count| return count,
            Progress.failed => return error.ReceiveFailed,
            Progress.want_read => try session.wait(socket, false, deadline, error.ReceiveTimeout),
            Progress.want_write => try session.wait(socket, true, deadline, error.ReceiveTimeout),
        }
    }
}

pub fn sendAllUntil(stream: ?*Stream, socket: net.Socket, bytes: []const u8, deadline: net.Deadline) net.Error!void {
    const session = stream orelse return net.sendAllUntil(socket, bytes, deadline);
    var sent: usize = 0;
    while (sent < bytes.len) sent += try session.writeUntil(socket, bytes[sent..], deadline);
}
