//! A request's ID: decided by the host when the request head arrives,
//! passed to Roc as `Http.Request.request_id`, and written in the host's logs,
//! so even a request the host answers without running the app has one.
const std = @import("std");
const http1_types = @import("http1/types.zig");
const random = @import("effect/random.zig");

/// Where the ID comes from, as `Server.RequestIdSource` says.
pub const Source = enum {
    /// A new random 128-bit ID for every request.
    generate,
    /// The request's single valid `x-request-id`, or a new one without it.
    trust_incoming,
};

/// An incoming ID is 1 to 128 visible ASCII bytes, as `RequestId` in
/// roxum-trace checked before the host decided IDs.
pub const maximum_bytes: usize = 128;
const generated_bytes: usize = 32;

pub const Id = struct {
    bytes: [maximum_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Id) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn decide(source: Source, headers: []const http1_types.Header, head_bytes: []const u8) Id {
    switch (source) {
        Source.generate => {},
        Source.trust_incoming => if (incoming(headers, head_bytes)) |value| return copied(value),
    }
    // Both words from one system call: a request ID is made for every
    // request.
    var bytes: [16]u8 = undefined;
    random.fill(&bytes);
    return generated(
        std.mem.readInt(u64, bytes[0..8], std.builtin.Endian.little),
        std.mem.readInt(u64, bytes[8..16], std.builtin.Endian.little),
    );
}

/// The value of the single `x-request-id` field when it is a valid ID.
/// Repeated fields cannot name one request, so they count as none.
fn incoming(headers: []const http1_types.Header, head_bytes: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name.slice(head_bytes), "x-request-id")) continue;
        if (found != null) return null;
        found = header.value.slice(head_bytes);
    }
    const value = found orelse return null;
    if (value.len == 0 or value.len > maximum_bytes) return null;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return null;
    return value;
}

fn copied(value: []const u8) Id {
    var id = Id{ .len = @intCast(value.len) };
    @memcpy(id.bytes[0..value.len], value);
    return id;
}

/// Two random words as 32 lowercase hex digits, the form of a W3C Trace
/// Context trace ID.
fn generated(high: u64, low: u64) Id {
    var id = Id{ .len = generated_bytes };
    var words: [16]u8 = undefined;
    std.mem.writeInt(u64, words[0..8], high, std.builtin.Endian.big);
    std.mem.writeInt(u64, words[8..16], low, std.builtin.Endian.big);
    id.bytes[0..generated_bytes].* = std.fmt.bytesToHex(words, std.fmt.Case.lower);
    return id;
}

const testing = std.testing;

/// A head holding `x-request-id` fields with the given values, and the
/// parsed spans that point into it.
const TestHead = struct {
    bytes: [1024]u8 = undefined,
    headers: [4]http1_types.Header = undefined,
    count: usize = 0,
    length: usize = 0,

    fn add(self: *TestHead, name: []const u8, value: []const u8) void {
        const name_start = self.length;
        @memcpy(self.bytes[name_start..][0..name.len], name);
        const value_start = name_start + name.len;
        @memcpy(self.bytes[value_start..][0..value.len], value);
        self.length = value_start + value.len;
        self.headers[self.count] = .{
            .name = .{ .start = @intCast(name_start), .len = @intCast(name.len) },
            .value = .{ .start = @intCast(value_start), .len = @intCast(value.len) },
        };
        self.count += 1;
    }

    fn decideWith(self: *const TestHead, source: Source) Id {
        return decide(source, self.headers[0..self.count], self.bytes[0..self.length]);
    }
};

fn expectGenerated(id: Id) !void {
    try testing.expectEqual(generated_bytes, id.slice().len);
    for (id.slice()) |byte| try testing.expect(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'));
}

fn expectTrusted(value: []const u8) !void {
    var head = TestHead{};
    head.add("x-request-id", value);
    try testing.expectEqualStrings(value, head.decideWith(Source.trust_incoming).slice());
}

fn expectIgnored(value: []const u8) !void {
    var head = TestHead{};
    head.add("x-request-id", value);
    try expectGenerated(head.decideWith(Source.trust_incoming));
}

test "a generated ID is the two words in lowercase hex, zero-padded" {
    try testing.expectEqualStrings("00000000000000000000000000000000", generated(0, 0).slice());
    try testing.expectEqualStrings("0000000000000001fffffffffffffffe", generated(1, std.math.maxInt(u64) - 1).slice());
    try testing.expectEqualStrings("ffffffffffffffffffffffffffffffff", generated(std.math.maxInt(u64), std.math.maxInt(u64)).slice());
}

test "generate ignores a valid incoming ID and makes a new one each time" {
    var head = TestHead{};
    head.add("x-request-id", "from-the-client");
    const first = head.decideWith(Source.generate);
    const second = head.decideWith(Source.generate);
    try expectGenerated(first);
    try expectGenerated(second);
    try testing.expect(!std.mem.eql(u8, first.slice(), second.slice()));
}

test "an incoming ID of 1 to 128 bytes is kept; 0 and 129 are replaced" {
    try expectIgnored("");
    try expectTrusted("a");
    try expectTrusted("a" ** 128);
    try expectIgnored("a" ** 129);
}

test "an incoming ID of visible ASCII is kept; space, DEL, and non-ASCII are replaced" {
    try expectIgnored(" ");
    try expectTrusted("!");
    try expectTrusted("~");
    try expectIgnored("\x7f");
    try expectIgnored("\xc3\xa9");
}

test "only a single x-request-id field is kept, whatever the case of its name" {
    var none = TestHead{};
    none.add("x-other", "a");
    try expectGenerated(none.decideWith(Source.trust_incoming));

    var one = TestHead{};
    one.add("X-Request-ID", "a");
    try testing.expectEqualStrings("a", one.decideWith(Source.trust_incoming).slice());

    var two = TestHead{};
    two.add("x-request-id", "a");
    two.add("x-request-id", "a");
    try expectGenerated(two.decideWith(Source.trust_incoming));
}

test "hex encoding preserves word order and nibble boundaries" {
    try testing.expectEqualStrings("0123456789abcdeffedcba9876543210", generated(0x0123456789abcdef, 0xfedcba9876543210).slice());
    // Nearest integer values around the one-to-two-hex-digit boundary.
    for ([_]u64{ 15, 16, 17 }) |word| {
        var expected: [32]u8 = undefined;
        _ = try std.fmt.bufPrint(&expected, "{x:0>16}{x:0>16}", .{ word, word });
        try testing.expectEqualStrings(&expected, generated(word, word).slice());
    }
}
