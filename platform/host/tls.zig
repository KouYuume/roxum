//! TLS on an outbound host socket (D7, D13). `std.crypto.tls.Client` runs
//! over a Reader / Writer of our own that waits with deadlines, so the
//! connection keeps the host's timeouts and, on a request fiber, suspends
//! the fiber instead of the thread. `std.Io` is used only to load CA
//! certificates and as the bundle lock the TLS client asks for. A loaded
//! bundle never changes (only Windows makes the client write to it), so
//! threads share it; `loading` guards only the loading.
const std = @import("std");
const tcp = @import("net/tcp.zig");
const random = @import("effect/random.zig");
const sync = @import("sync.zig");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const tls = std.crypto.tls;
const Bundle = std.crypto.Certificate.Bundle;

pub const Error = error{ TlsFailed, Timeout, Closed, Failed, OutOfMemory };
pub const CaError = error{ CaUnavailable, OutOfMemory };

var system_bundle: Bundle = .empty;
var system_bundle_loaded = false;
const maximum_ca_files = 8;
const FileBundle = struct { path: []u8, bundle: Bundle };
var file_bundles: [maximum_ca_files]?FileBundle = @splat(null);
var bundle_lock: std.Io.RwLock = .init;
var loading: sync.Mutex = .{};

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn realtimeNow() std.Io.Timestamp {
    var now: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(std.c.CLOCK.REALTIME, &now) == 0);
    return .{ .nanoseconds = @as(i96, now.sec) * std.time.ns_per_s + now.nsec };
}

/// The CA certificates to trust: the system's, or those in the PEM file at
/// the absolute path `ca_file`. Loaded once per process; call it when a pool
/// is made, so a missing CA stops `init!` (D8).
pub fn bundleFor(ca_file: ?[]const u8) CaError!*Bundle {
    loading.lock();
    defer loading.unlock();
    const path = ca_file orelse {
        if (!system_bundle_loaded) {
            errdefer {
                system_bundle.deinit(std.heap.smp_allocator);
                system_bundle = .empty;
            }
            system_bundle.rescan(std.heap.smp_allocator, io(), realtimeNow()) catch return error.CaUnavailable;
            if (system_bundle.map.count() == 0) return error.CaUnavailable;
            system_bundle_loaded = true;
        }
        return &system_bundle;
    };
    for (&file_bundles) |*slot| {
        if (slot.*) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) return &entry.bundle;
        }
    }
    if (!std.fs.path.isAbsolute(path)) return error.CaUnavailable;
    for (&file_bundles) |*slot| {
        if (slot.* != null) continue;
        slot.* = try loadFileBundle(std.heap.smp_allocator, path, realtimeNow());
        return &slot.*.?.bundle;
    }
    return error.CaUnavailable;
}

// Own both allocations until the cache receives the completed entry.
fn loadFileBundle(allocator: std.mem.Allocator, path: []const u8, now: std.Io.Timestamp) CaError!FileBundle {
    var bundle: Bundle = .empty;
    errdefer bundle.deinit(allocator);
    bundle.addCertsFromFilePathAbsolute(allocator, io(), now, path) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.CaUnavailable;
    };
    if (bundle.map.count() == 0) return error.CaUnavailable;
    return .{ .path = try allocator.dupe(u8, path), .bundle = bundle };
}

/// Why the socket under the TLS client stopped, which the client itself
/// reports only as a read or write failure.
const SocketFailure = enum { none, timeout, closed, failed };

/// Bytes from the socket, waiting no later than `deadline`.
const SocketReader = struct {
    interface: Reader,
    socket: tcp.Socket,
    deadline: tcp.Deadline,
    failure: SocketFailure = SocketFailure.none,

    fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *SocketReader = @fieldParentPtr("interface", r);
        const destination = limit.slice(try w.writableSliceGreedy(1));
        const count = tcp.receiveUntil(self.socket, destination, self.deadline) catch |err| {
            self.failure = if (err == error.ReceiveTimeout) SocketFailure.timeout else SocketFailure.failed;
            return error.ReadFailed;
        };
        if (count == 0) {
            self.failure = SocketFailure.closed;
            return error.EndOfStream;
        }
        w.advance(count);
        return count;
    }
};

const SocketWriter = struct {
    interface: Writer,
    socket: tcp.Socket,
    deadline: tcp.Deadline,
    failure: SocketFailure = SocketFailure.none,
    /// Bytes the kernel accepted since the session was made.
    sent: usize = 0,

    fn send(self: *SocketWriter, bytes: []const u8) Writer.Error!void {
        tcp.sendAllCounting(self.socket, bytes, self.deadline, &self.sent) catch |err| {
            self.failure = if (err == error.SendTimeout) SocketFailure.timeout else SocketFailure.failed;
            return error.WriteFailed;
        };
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *SocketWriter = @fieldParentPtr("interface", w);
        try self.send(w.buffer[0..w.end]);
        w.end = 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.send(bytes);
            written += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try self.send(last);
            written += last.len;
        }
        return written;
    }
};

/// One TLS connection: the socket's reader and writer, the TLS client over
/// them, and the four buffers they use.
pub const Session = struct {
    socket_reader: SocketReader,
    socket_writer: SocketWriter,
    client: tls.Client,
    memory: []u8,

    const buffer_len = tls.Client.min_buffer_len;
    /// Socket read, socket write, TLS read (with room for app reads), TLS
    /// write: about 83 KiB per connection.
    const memory_len = 4 * buffer_len + 16 * 1024;

    /// Runs the handshake for `server_name`, verifying the server's
    /// certificate chain against `bundle` (from `bundleFor`).
    pub fn connect(socket: tcp.Socket, server_name: []const u8, bundle: *Bundle, deadline: tcp.Deadline) Error!*Session {
        const self = try std.heap.smp_allocator.create(Session);
        errdefer std.heap.smp_allocator.destroy(self);
        self.memory = try std.heap.smp_allocator.alloc(u8, memory_len);
        errdefer std.heap.smp_allocator.free(self.memory);
        const socket_read = self.memory[0..buffer_len];
        const socket_write = self.memory[buffer_len..][0..buffer_len];
        const tls_read = self.memory[2 * buffer_len ..][0 .. buffer_len + 16 * 1024];
        const tls_write = self.memory[3 * buffer_len + 16 * 1024 ..][0..buffer_len];
        self.socket_reader = .{
            .interface = .{ .vtable = &.{ .stream = SocketReader.stream }, .buffer = socket_read, .seek = 0, .end = 0 },
            .socket = socket,
            .deadline = deadline,
        };
        self.socket_writer = .{
            .interface = .{ .vtable = &.{ .drain = SocketWriter.drain }, .buffer = socket_write },
            .socket = socket,
            .deadline = deadline,
        };
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        var index: usize = 0;
        while (index < entropy.len) : (index += 8) {
            const word = random.randomU64();
            const take = @min(8, entropy.len - index);
            @memcpy(entropy[index..][0..take], std.mem.asBytes(&word)[0..take]);
        }
        self.client = tls.Client.init(&self.socket_reader.interface, &self.socket_writer.interface, .{
            .host = .{ .explicit = server_name },
            .ca = .{ .bundle = .{ .gpa = std.heap.smp_allocator, .io = io(), .lock = &bundle_lock, .bundle = bundle } },
            .read_buffer = tls_read,
            .write_buffer = tls_write,
            .entropy = &entropy,
            .realtime_now = realtimeNow(),
        }) catch return self.socketError(error.TlsFailed);
        return self;
    }

    pub fn setDeadline(self: *Session, deadline: tcp.Deadline) void {
        self.socket_reader.deadline = deadline;
        self.socket_writer.deadline = deadline;
    }

    /// Bytes of TLS records the kernel accepted so far.
    pub fn bytesSent(self: *const Session) usize {
        return self.socket_writer.sent;
    }

    pub fn writeAll(self: *Session, bytes: []const u8) Error!void {
        self.client.writer.writeAll(bytes) catch return self.socketError(error.Failed);
        self.client.writer.flush() catch return self.socketError(error.Failed);
        self.socket_writer.interface.flush() catch return self.socketError(error.Failed);
    }

    /// Decrypted bytes, up to `buffer.len`; `Closed` once the peer has ended
    /// the stream.
    pub fn read(self: *Session, buffer: []u8) Error!usize {
        const available = self.client.reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return error.Closed,
            else => return self.socketError(error.Failed),
        };
        const count = @min(available.len, buffer.len);
        @memcpy(buffer[0..count], available[0..count]);
        self.client.reader.toss(count);
        return count;
    }

    /// The socket's own reason, when it has one, over the TLS client's.
    fn socketError(self: *const Session, otherwise: Error) Error {
        const failure = if (self.socket_reader.failure != SocketFailure.none) self.socket_reader.failure else self.socket_writer.failure;
        return switch (failure) {
            SocketFailure.none => otherwise,
            SocketFailure.timeout => error.Timeout,
            SocketFailure.closed => error.Closed,
            SocketFailure.failed => error.Failed,
        };
    }

    pub fn destroy(self: *Session) void {
        std.heap.smp_allocator.free(self.memory);
        std.heap.smp_allocator.destroy(self);
    }
};

fn loadTestBundle(allocator: std.mem.Allocator, path: []const u8) !void {
    // 2030-01-01: inside the fixture validity period, independent of the clock.
    var entry = try loadFileBundle(allocator, path, .{ .nanoseconds = 1_893_456_000 * @as(i96, std.time.ns_per_s) });
    defer entry.bundle.deinit(allocator);
    defer allocator.free(entry.path);
    try std.testing.expect(entry.bundle.map.count() > 0);
    try std.testing.expectEqualStrings(path, entry.path);
}

test "CA loading frees every allocation on failure, including the cache path copy" {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath("tests/fixtures/tls/ca.pem", &path_buffer) orelse return error.RealpathFailed;
    const path = std.mem.span(resolved);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadTestBundle, .{path});
}

test "CA loading rejects empty and malformed bundles without leaking" {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try @import("effect/file.zig").testPath(&path_buffer, "ca-invalid");
    defer _ = std.c.unlink(path.ptr);
    // No certificate, non-certificate text, and an unfinished PEM record.
    for ([_][]const u8{ "", "not a certificate", "-----BEGIN CERTIFICATE-----\nAAAA" }) |contents| {
        const fd = std.c.open(path.ptr, .{ .ACCMODE = std.posix.ACCMODE.WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.CreateFailed;
        const written = std.c.write(fd, contents.ptr, contents.len);
        _ = std.c.close(fd);
        try std.testing.expectEqual(@as(isize, @intCast(contents.len)), written);
        try std.testing.expectError(error.CaUnavailable, loadFileBundle(std.testing.allocator, path, realtimeNow()));
    }
}
