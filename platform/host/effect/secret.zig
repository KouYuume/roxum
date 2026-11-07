//! `Secret`: secrets the host keeps and Roc never sees (D5, D14).
//!
//! A secret comes from a file or an environment variable the runtime
//! injected. Roc gets a handle. To use the secret, Roc sends an expression,
//! encoded in postfix order (`Secret.encode`), and the host evaluates it:
//! `derive` returns results that went through a one-way operation, and
//! `evaluateForWrite` lets a connection write results that may contain the
//! secret itself. The checks keep secrets out of logs and messages by
//! mistake; app code is trusted.
//!
//! Every thread of the process shares the table. A slot, once
//! filled, never changes until the process ends.
const std = @import("std");
const sync = @import("../sync.zig");
const abi = @import("../roc_platform_abi.zig");
const allocator_context = @import("../allocator/context.zig");
const request_bridge = @import("../bridge/request.zig");
const runtime = @import("../runtime.zig");
const file = @import("file.zig");

pub const maximum_secrets = 64;
pub const maximum_secret_bytes = 4096;
const maximum_stack = 32;
const maximum_value_bytes = 64 * 1024;
const maximum_iterations = 1_000_000;

pub const Op = enum(u8) {
    secret = 0x01,
    bytes = 0x02,
    sha256 = 0x10,
    sha1 = 0x11,
    md5 = 0x12,
    hmac_sha256 = 0x20,
    pbkdf2_sha256 = 0x21,
    xor = 0x30,
    concat = 0x31,
    be32_length_plus = 0x32,
    output = 0xF0,
};

/// The first byte of `derive`'s reply; `Secret.derive!` reads it.
pub const Status = enum(u8) {
    ok = 0,
    /// A result contains the secret without a one-way operation.
    exposes_secret = 1,
    invalid = 2,
    unknown_secret = 3,
};

pub const LoadError = error{ NotFound, NotSet, PermissionDenied, TooLarge, Failed, TableFull };

/// The worker's secrets. A handle is the slot index plus one.
pub const Table = struct {
    slots: [maximum_secrets]?[]u8 = @splat(null),
    lock: sync.Mutex = .{},

    pub fn fromFile(self: *Table, path: []const u8) LoadError!u64 {
        const contents = file.readBounded(std.heap.smp_allocator, path, maximum_secret_bytes + 1) catch |err| return switch (err) {
            error.NotFound => error.NotFound,
            error.PermissionDenied => error.PermissionDenied,
            error.TooLarge => error.TooLarge,
            error.Failed => error.Failed,
        };
        defer release(contents);
        var secret = contents;
        // `echo secret > file` adds one newline.
        if (std.mem.endsWith(u8, secret, "\n")) secret = secret[0 .. secret.len - 1];
        if (std.mem.endsWith(u8, secret, "\r")) secret = secret[0 .. secret.len - 1];
        return self.store(secret);
    }

    pub fn fromEnv(self: *Table, name: []const u8) LoadError!u64 {
        var name_buffer: [256:0]u8 = undefined;
        if (name.len == 0 or name.len >= name_buffer.len or std.mem.indexOfScalar(u8, name, 0) != null) return error.NotSet;
        @memcpy(name_buffer[0..name.len], name);
        name_buffer[name.len] = 0;
        const value = std.c.getenv(&name_buffer) orelse return error.NotSet;
        return self.store(std.mem.span(value));
    }

    fn store(self: *Table, secret: []const u8) LoadError!u64 {
        if (secret.len > maximum_secret_bytes) return error.TooLarge;
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.slots, 0..) |*slot, index| {
            if (slot.* != null) continue;
            slot.* = std.heap.smp_allocator.dupe(u8, secret) catch return error.Failed;
            return index + 1;
        }
        return error.TableFull;
    }

    pub fn get(self: *Table, handle: u64) ?[]const u8 {
        if (handle == 0 or handle > maximum_secrets) return null;
        self.lock.lock();
        defer self.lock.unlock();
        return self.slots[handle - 1];
    }

    pub fn deinit(self: *Table) void {
        for (&self.slots) |*slot| {
            if (slot.*) |secret| release(secret);
            slot.* = null;
        }
    }
};

var table: Table = .{};

fn rocHost() abi.RocHost {
    const context = allocator_context.current() orelse @panic("allocator context is not set");
    return runtime.makeRocHost(@ptrCast(context.host_allocator));
}

fn loadResult(loaded: LoadError!u64) abi.HostSecretLoad {
    var result: abi.HostSecretLoad = undefined;
    result.payload = std.mem.zeroes(@TypeOf(result.payload));
    const handle = loaded catch |err| {
        result.tag = switch (err) {
            error.NotFound => abi.HostSecretLoadTag.NotFound,
            error.NotSet => abi.HostSecretLoadTag.NotSet,
            error.PermissionDenied => abi.HostSecretLoadTag.PermissionDenied,
            error.TooLarge => abi.HostSecretLoadTag.TooLarge,
            error.Failed => abi.HostSecretLoadTag.Failed,
            error.TableFull => abi.HostSecretLoadTag.TableFull,
        };
        return result;
    };
    result.tag = abi.HostSecretLoadTag.Loaded;
    const payload: *u64 = @ptrCast(@alignCast(&result.payload));
    payload.* = handle;
    return result;
}

pub fn hostedSecretFromFile(path: abi.RocStr) callconv(std.builtin.CallingConvention.c) abi.HostSecretLoad {
    var roc_host = rocHost();
    defer path.decref(&roc_host);
    return loadResult(table.fromFile(path.asSlice()));
}

pub fn hostedSecretFromEnv(name: abi.RocStr) callconv(std.builtin.CallingConvention.c) abi.HostSecretLoad {
    var roc_host = rocHost();
    defer name.decref(&roc_host);
    return loadResult(table.fromEnv(name.asSlice()));
}

/// Evaluates the expression with the secret. The reply is a `Status` byte,
/// then, when it is `ok`, each result as a 4-byte big-endian length and its
/// bytes.
pub fn hostedSecretDerive(handle: u64, program: abi.RocListWith(u8, false)) callconv(std.builtin.CallingConvention.c) abi.RocListWith(u8, false) {
    var roc_host = rocHost();
    defer program.decref(&roc_host);
    const code: []const u8 = if (program.elements_ptr) |pointer| pointer[0..program.len()] else &.{};
    var reply: std.ArrayList(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, reply.items);
        reply.deinit(std.heap.smp_allocator);
    }
    encodeDerive(&table, handle, code, &reply) catch {
        reply.clearRetainingCapacity();
        reply.append(std.heap.smp_allocator, @intFromEnum(Status.invalid)) catch @panic("out of memory");
    };
    return request_bridge.rocByteListFromSliceChecked(
        reply.items,
        .{ .roc_host = &roc_host, .try_alloc = runtime.tryAllocWithHost },
    ) catch @panic("out of memory");
}

fn encodeDerive(secrets: *Table, handle: u64, code: []const u8, reply: *std.ArrayList(u8)) error{OutOfMemory}!void {
    var outputs: Outputs = .{};
    defer outputs.deinit();
    const status = evaluate(secrets, handle, code, &outputs, false);
    try reply.append(std.heap.smp_allocator, @intFromEnum(status));
    if (status != Status.ok) return;
    for (outputs.items.items) |value| {
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(value.len), std.builtin.Endian.big);
        try reply.appendSlice(std.heap.smp_allocator, &length);
        try reply.appendSlice(std.heap.smp_allocator, value);
    }
}

/// The joined results of the expression, which may contain the secret, for
/// a connection to write without the bytes reaching Roc. Null when the
/// expression cannot be evaluated. The caller zeroes and frees the bytes.
pub fn evaluateForWrite(handle: u64, code: []const u8) ?[]u8 {
    var outputs: Outputs = .{};
    defer outputs.deinit();
    if (evaluate(&table, handle, code, &outputs, true) != Status.ok) return null;
    var joined: std.ArrayList(u8) = .empty;
    for (outputs.items.items) |value| joined.appendSlice(std.heap.smp_allocator, value) catch {
        std.crypto.secureZero(u8, joined.items);
        joined.deinit(std.heap.smp_allocator);
        return null;
    };
    return joined.toOwnedSlice(std.heap.smp_allocator) catch null;
}

const Value = struct {
    bytes: []u8,
    /// Contains the secret without a one-way operation in between.
    exposes_secret: bool,
};

const Outputs = struct {
    items: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Outputs) void {
        for (self.items.items) |value| release(value);
        self.items.deinit(std.heap.smp_allocator);
    }
};

fn evaluate(secrets: *Table, handle: u64, code: []const u8, outputs: *Outputs, allow_secret: bool) Status {
    const secret = secrets.get(handle) orelse return Status.unknown_secret;
    var stack: [maximum_stack]Value = undefined;
    var depth: usize = 0;
    defer for (stack[0..depth]) |value| release(value.bytes);
    var index: usize = 0;
    while (index < code.len) {
        const op = std.enums.fromInt(Op, code[index]) orelse return Status.invalid;
        index += 1;
        switch (op) {
            Op.secret => {
                if (depth == maximum_stack) return Status.invalid;
                stack[depth] = .{ .bytes = dupe(secret) orelse return Status.invalid, .exposes_secret = true };
                depth += 1;
            },
            Op.bytes => {
                const length = readU32(code, &index) orelse return Status.invalid;
                if (depth == maximum_stack or length > maximum_value_bytes or index + length > code.len) return Status.invalid;
                stack[depth] = .{ .bytes = dupe(code[index..][0..length]) orelse return Status.invalid, .exposes_secret = false };
                depth += 1;
                index += length;
            },
            Op.sha256, Op.sha1, Op.md5 => {
                if (depth < 1) return Status.invalid;
                const input = stack[depth - 1];
                const digest = switch (op) {
                    Op.sha256 => hashOf(std.crypto.hash.sha2.Sha256, input.bytes),
                    Op.sha1 => hashOf(std.crypto.hash.Sha1, input.bytes),
                    else => hashOf(std.crypto.hash.Md5, input.bytes),
                } orelse return Status.invalid;
                release(input.bytes);
                stack[depth - 1] = .{ .bytes = digest, .exposes_secret = false };
            },
            Op.hmac_sha256 => {
                if (depth < 2) return Status.invalid;
                const message = stack[depth - 1];
                const key = stack[depth - 2];
                const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
                const mac = std.heap.smp_allocator.alloc(u8, Hmac.mac_length) catch return Status.invalid;
                Hmac.create(mac[0..Hmac.mac_length], message.bytes, key.bytes);
                release(message.bytes);
                release(key.bytes);
                depth -= 1;
                stack[depth - 1] = .{ .bytes = mac, .exposes_secret = false };
            },
            Op.pbkdf2_sha256 => {
                const iterations = readU32(code, &index) orelse return Status.invalid;
                if (depth < 2 or iterations == 0 or iterations > maximum_iterations) return Status.invalid;
                const salt = stack[depth - 1];
                const password = stack[depth - 2];
                const key = std.heap.smp_allocator.alloc(u8, 32) catch return Status.invalid;
                std.crypto.pwhash.pbkdf2(key, password.bytes, salt.bytes, iterations, std.crypto.auth.hmac.sha2.HmacSha256) catch {
                    release(key);
                    return Status.invalid;
                };
                release(salt.bytes);
                release(password.bytes);
                depth -= 1;
                stack[depth - 1] = .{ .bytes = key, .exposes_secret = false };
            },
            Op.xor, Op.concat => {
                if (depth < 2) return Status.invalid;
                const right = stack[depth - 1];
                const left = stack[depth - 2];
                const combined = if (op == Op.xor) blk: {
                    if (left.bytes.len != right.bytes.len) return Status.invalid;
                    const out = std.heap.smp_allocator.alloc(u8, left.bytes.len) catch return Status.invalid;
                    for (out, left.bytes, right.bytes) |*o, a, b| o.* = a ^ b;
                    break :blk out;
                } else blk: {
                    if (left.bytes.len + right.bytes.len > maximum_value_bytes) return Status.invalid;
                    break :blk std.mem.concat(std.heap.smp_allocator, u8, &.{ left.bytes, right.bytes }) catch return Status.invalid;
                };
                const exposes = left.exposes_secret or right.exposes_secret;
                release(right.bytes);
                release(left.bytes);
                depth -= 1;
                stack[depth - 1] = .{ .bytes = combined, .exposes_secret = exposes };
            },
            Op.be32_length_plus => {
                const extra = readU32(code, &index) orelse return Status.invalid;
                if (depth < 1) return Status.invalid;
                const input = stack[depth - 1];
                const total = std.math.cast(u32, input.bytes.len + extra) orelse return Status.invalid;
                const out = std.heap.smp_allocator.alloc(u8, 4) catch return Status.invalid;
                std.mem.writeInt(u32, out[0..4], total, std.builtin.Endian.big);
                release(input.bytes);
                stack[depth - 1] = .{ .bytes = out, .exposes_secret = false };
            },
            Op.output => {
                if (depth < 1) return Status.invalid;
                const value = stack[depth - 1];
                if (value.exposes_secret and !allow_secret) return Status.exposes_secret;
                depth -= 1;
                outputs.items.append(std.heap.smp_allocator, value.bytes) catch {
                    release(value.bytes);
                    return Status.invalid;
                };
            },
        }
    }
    if (depth != 0) return Status.invalid;
    return Status.ok;
}

fn readU32(code: []const u8, index: *usize) ?u32 {
    if (index.* + 4 > code.len) return null;
    const value = std.mem.readInt(u32, code[index.*..][0..4], std.builtin.Endian.big);
    index.* += 4;
    return value;
}

fn dupe(bytes: []const u8) ?[]u8 {
    return std.heap.smp_allocator.dupe(u8, bytes) catch null;
}

fn hashOf(comptime Hash: type, input: []const u8) ?[]u8 {
    const out = std.heap.smp_allocator.alloc(u8, Hash.digest_length) catch return null;
    Hash.hash(input, out[0..Hash.digest_length], .{});
    return out;
}

/// Zeroes the bytes before freeing them, so no copy of a secret outlives its use.
fn release(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    std.heap.smp_allocator.free(bytes);
}

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

fn testTable(secret: []const u8) !Table {
    var secrets = Table{};
    _ = try secrets.store(secret);
    return secrets;
}

fn evaluateOne(secrets: *Table, code: []const u8, allow_secret: bool) !struct { status: Status, value: ?[]u8 } {
    var outputs: Outputs = .{};
    defer outputs.deinit();
    const status = evaluate(secrets, 1, code, &outputs, allow_secret);
    if (status != Status.ok) return .{ .status = status, .value = null };
    return .{ .status = status, .value = try std.testing.allocator.dupe(u8, outputs.items.items[0]) };
}

test "PBKDF2, HMAC, and SHA-256 of the secret match the published vectors" {
    var secrets = try testTable("password");
    defer secrets.deinit();
    // PBKDF2-HMAC-SHA-256("password", "salt", 4096), a widely published vector.
    const pbkdf2 = [_]u8{ 0x01, 0x02, 0, 0, 0, 4, 's', 'a', 'l', 't', 0x21, 0, 0, 0x10, 0, 0xF0 };
    const derived = try evaluateOne(&secrets, &pbkdf2, false);
    defer std.testing.allocator.free(derived.value.?);
    try std.testing.expectEqualSlices(u8, &hex("c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"), derived.value.?);
    // SHA-256("password").
    const sha = [_]u8{ 0x01, 0x10, 0xF0 };
    const digest = try evaluateOne(&secrets, &sha, false);
    defer std.testing.allocator.free(digest.value.?);
    try std.testing.expectEqualSlices(u8, &hex("5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8"), digest.value.?);
}

test "a result that contains the secret is refused for derive and allowed for a write" {
    var secrets = try testTable("password");
    defer secrets.deinit();
    const bare = [_]u8{ 0x01, 0xF0 };
    try std.testing.expectEqual(Status.exposes_secret, (try evaluateOne(&secrets, &bare, false)).status);
    // "x" ++ secret, and secret XOR itself, still carry the secret.
    const concat = [_]u8{ 0x02, 0, 0, 0, 1, 'x', 0x01, 0x31, 0xF0 };
    try std.testing.expectEqual(Status.exposes_secret, (try evaluateOne(&secrets, &concat, false)).status);
    const xor = [_]u8{ 0x01, 0x01, 0x30, 0xF0 };
    try std.testing.expectEqual(Status.exposes_secret, (try evaluateOne(&secrets, &xor, false)).status);
    const written = try evaluateOne(&secrets, &concat, true);
    defer std.testing.allocator.free(written.value.?);
    try std.testing.expectEqualStrings("xpassword", written.value.?);
    // The length prefix does not carry the secret.
    const length = [_]u8{ 0x01, 0x32, 0, 0, 0, 5, 0xF0 };
    const prefix = try evaluateOne(&secrets, &length, false);
    defer std.testing.allocator.free(prefix.value.?);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 13 }, prefix.value.?);
}

test "malformed expressions and unknown handles are refused" {
    var secrets = try testTable("password");
    defer secrets.deinit();
    var outputs: Outputs = .{};
    defer outputs.deinit();
    try std.testing.expectEqual(Status.unknown_secret, evaluate(&secrets, 2, &.{ 0x01, 0x10, 0xF0 }, &outputs, false));
    try std.testing.expectEqual(Status.unknown_secret, evaluate(&secrets, 0, &.{ 0x01, 0x10, 0xF0 }, &outputs, false));
    // Unknown op, missing operand, value left on the stack, truncated bytes,
    // XOR of different lengths, PBKDF2 with 0 iterations.
    const cases = [_][]const u8{
        &.{0x7F},
        &.{ 0x10, 0xF0 },
        &.{ 0x01, 0x10 },
        &.{ 0x02, 0, 0, 0, 9, 'a' },
        &.{ 0x01, 0x02, 0, 0, 0, 1, 'a', 0x30, 0xF0 },
        &.{ 0x01, 0x02, 0, 0, 0, 0, 0x21, 0, 0, 0, 0, 0xF0 },
    };
    for (cases) |code| try std.testing.expectEqual(Status.invalid, evaluate(&secrets, 1, code, &outputs, false));
}

test "the table holds 64 secrets of up to 4 KiB" {
    var secrets = Table{};
    defer secrets.deinit();
    const at_limit = [_]u8{'a'} ** maximum_secret_bytes;
    try std.testing.expectEqual(@as(u64, 1), try secrets.store(&at_limit));
    try std.testing.expectError(error.TooLarge, secrets.store(&([_]u8{'a'} ** (maximum_secret_bytes + 1))));
    for (2..maximum_secrets + 1) |expected| try std.testing.expectEqual(@as(u64, expected), try secrets.store("s"));
    try std.testing.expectError(error.TableFull, secrets.store("s"));
}

test "a file secret loses one trailing newline and an environment secret is read as is" {
    var secrets = Table{};
    defer secrets.deinit();
    var path: [512]u8 = undefined;
    const name = try file.testPath(&path, "secret-test");
    const descriptor = std.c.open(name.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(descriptor >= 0);
    _ = std.c.write(descriptor, "hunter2\n\n", 9);
    _ = std.c.close(descriptor);
    defer _ = std.c.unlink(name.ptr);
    const from_file = try secrets.fromFile(name);
    try std.testing.expectEqualStrings("hunter2\n", secrets.get(from_file).?);
    var missing: [512]u8 = undefined;
    try std.testing.expectError(error.NotFound, secrets.fromFile(try file.testPath(&missing, "secret-test-missing")));
    try std.testing.expectError(error.NotSet, secrets.fromEnv("ROXUM_SECRET_TEST_UNSET_VARIABLE"));
    try std.testing.expectError(error.NotSet, secrets.fromEnv(""));
    const from_env = try secrets.fromEnv("PATH");
    try std.testing.expectEqualStrings(std.mem.span(std.c.getenv("PATH").?), secrets.get(from_env).?);
}
