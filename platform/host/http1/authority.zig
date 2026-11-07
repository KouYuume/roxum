const std = @import("std");
const syntax = @import("syntax.zig");

const State = enum {
    host_start,
    reg_name,
    reg_name_percent_first,
    reg_name_percent_second,
    ip_literal,
    after_ip_literal,
    port,
    failed,
};

const LiteralKind = enum {
    unknown,
    ipv6,
    ipv_future_version,
    ipv_future_value,
};

const maximum_port: u32 = 65535;

pub const Tracker = struct {
    state: State = State.host_start,
    host_length: usize = 0,
    port_length: usize = 0,
    port_value: u32 = 0,

    literal_kind: LiteralKind = LiteralKind.unknown,
    ipv6_bytes: [45]u8 = undefined,
    ipv6_length: usize = 0,
    ipv_future_version_length: usize = 0,
    ipv_future_value_length: usize = 0,

    pub fn consume(self: *Tracker, byte: u8) bool {
        self.state = switch (self.state) {
            State.host_start => if (byte == '[')
                State.ip_literal
            else if (byte == ':')
                State.port
            else
                self.consumeRegName(byte),
            State.reg_name => if (byte == ':')
                State.port
            else
                self.consumeRegName(byte),
            State.reg_name_percent_first => if (syntax.isHexDigit(byte))
                State.reg_name_percent_second
            else
                State.failed,
            State.reg_name_percent_second => if (syntax.isHexDigit(byte)) blk: {
                self.host_length += 3;
                break :blk State.reg_name;
            } else State.failed,
            State.ip_literal => if (byte == ']')
                if (self.finishLiteral())
                    State.after_ip_literal
                else
                    State.failed
            else if (self.consumeLiteral(byte))
                State.ip_literal
            else
                State.failed,
            State.after_ip_literal => if (byte == ':')
                State.port
            else
                State.failed,
            State.port => if (byte >= '0' and byte <= '9') blk: {
                // Leading zeros are allowed by `port = *DIGIT`; the value
                // must still name a TCP port.
                self.port_value = self.port_value * 10 + (byte - '0');
                if (self.port_value > maximum_port) break :blk State.failed;
                self.port_length += 1;
                break :blk State.port;
            } else State.failed,
            State.failed => State.failed,
        };

        return self.state != State.failed;
    }

    /// Consumes the leading run of unescaped reg-name bytes in one step, with
    /// the same result as `consume` on each of them. Returns how many bytes
    /// it took; it takes none outside the host part of a reg-name.
    pub fn consumeRegNameRun(self: *Tracker, bytes: []const u8) usize {
        if (self.state != State.host_start and self.state != State.reg_name) return 0;
        const length = syntax.regNameRun(bytes);
        if (length == 0) return 0;
        self.host_length += length;
        self.state = State.reg_name;
        return length;
    }

    pub fn finish(
        self: *const Tracker,
        allow_empty_host: bool,
        require_port: bool,
    ) bool {
        const host_complete = self.state == State.reg_name or
            self.state == State.after_ip_literal or
            self.state == State.port or
            (allow_empty_host and self.state == State.host_start);
        if (!host_complete) return false;
        if (!allow_empty_host and self.host_length == 0) return false;
        if (require_port and
            (self.state != State.port or self.port_length == 0))
        {
            return false;
        }
        return true;
    }

    fn consumeRegName(self: *Tracker, byte: u8) State {
        if (byte == '%') return State.reg_name_percent_first;
        if (!syntax.isRegNameUnescaped(byte)) return State.failed;
        self.host_length += 1;
        return State.reg_name;
    }

    fn consumeLiteral(self: *Tracker, byte: u8) bool {
        switch (self.literal_kind) {
            LiteralKind.unknown => {
                if (byte == 'v' or byte == 'V') {
                    self.literal_kind = LiteralKind.ipv_future_version;
                    return true;
                }
                self.literal_kind = LiteralKind.ipv6;
                return self.appendIpv6Byte(byte);
            },
            LiteralKind.ipv6 => return self.appendIpv6Byte(byte),
            LiteralKind.ipv_future_version => {
                if (syntax.isHexDigit(byte)) {
                    self.ipv_future_version_length += 1;
                    return true;
                }
                if (byte != '.' or self.ipv_future_version_length == 0) return false;
                self.literal_kind = LiteralKind.ipv_future_value;
                return true;
            },
            LiteralKind.ipv_future_value => {
                if (!syntax.isIpvFutureValue(byte)) return false;
                self.ipv_future_value_length += 1;
                return true;
            },
        }
    }

    fn appendIpv6Byte(self: *Tracker, byte: u8) bool {
        if (self.ipv6_length == self.ipv6_bytes.len) return false;
        self.ipv6_bytes[self.ipv6_length] = byte;
        self.ipv6_length += 1;
        return true;
    }

    fn finishLiteral(self: *Tracker) bool {
        const valid = switch (self.literal_kind) {
            LiteralKind.unknown => false,
            LiteralKind.ipv6 => isValidIpv6(
                self.ipv6_bytes[0..self.ipv6_length],
            ),
            LiteralKind.ipv_future_version => false,
            LiteralKind.ipv_future_value => self.ipv_future_value_length != 0,
        };
        if (valid) self.host_length = 1;
        return valid;
    }
};

fn isValidIpv6(bytes: []const u8) bool {
    if (bytes.len == 0) return false;

    if (std.mem.indexOf(u8, bytes, "::")) |compression| {
        if (std.mem.indexOf(u8, bytes[compression + 2 ..], "::") != null) return false;

        const left = parseIpv6Side(bytes[0..compression], false) orelse
            return false;
        const right = parseIpv6Side(bytes[compression + 2 ..], true) orelse
            return false;
        return left + right < 8;
    }

    return (parseIpv6Side(bytes, true) orelse return false) == 8;
}

fn parseIpv6Side(bytes: []const u8, allow_ipv4: bool) ?usize {
    if (bytes.len == 0) return 0;

    var units: usize = 0;
    var segments = std.mem.splitScalar(u8, bytes, ':');
    while (segments.next()) |segment| {
        if (segment.len == 0) return null;

        if (std.mem.indexOfScalar(u8, segment, '.') != null) {
            if (!allow_ipv4 or segments.peek() != null or
                !isValidIpv4(segment))
            {
                return null;
            }
            units += 2;
            continue;
        }

        if (segment.len > 4) return null;
        for (segment) |byte| {
            if (!syntax.isHexDigit(byte)) return null;
        }
        units += 1;
    }
    return units;
}

fn isValidIpv4(bytes: []const u8) bool {
    var octet_count: usize = 0;
    var octets = std.mem.splitScalar(u8, bytes, '.');
    while (octets.next()) |octet| {
        if (octet.len == 0 or octet.len > 3) return false;
        if (octet.len > 1 and octet[0] == '0') return false;

        var value: u16 = 0;
        for (octet) |byte| {
            if (byte < '0' or byte > '9') return false;
            value = value * 10 + (byte - '0');
        }
        if (value > 255) return false;
        octet_count += 1;
    }
    return octet_count == 4;
}

test "authority validates registered names and percent encoding" {
    const Case = struct {
        value: []const u8,
        expected: bool,
    };
    const cases = [_]Case{
        .{ .value = "example.com:443", .expected = true },
        .{ .value = "a%2Eb:1", .expected = true },
        .{ .value = "a%2:1", .expected = false },
        .{ .value = "a%xx:1", .expected = false },
    };

    for (cases) |case| {
        var tracker = Tracker{};
        var accepted = true;
        for (case.value) |byte| {
            if (!tracker.consume(byte)) accepted = false;
        }
        accepted = accepted and tracker.finish(false, true);
        try std.testing.expectEqual(case.expected, accepted);
    }
}

test "authority ports stop at the largest TCP port" {
    const Case = struct {
        value: []const u8,
        expected: bool,
    };
    const cases = [_]Case{
        .{ .value = "example.com:65534", .expected = true },
        .{ .value = "example.com:65535", .expected = true },
        .{ .value = "example.com:65536", .expected = false },
        .{ .value = "example.com:99999999", .expected = false },
        // Leading zeros do not change the value.
        .{ .value = "example.com:0000065535", .expected = true },
        .{ .value = "[::1]:65536", .expected = false },
    };

    for (cases) |case| {
        var tracker = Tracker{};
        var accepted = true;
        for (case.value) |byte| {
            if (!tracker.consume(byte)) accepted = false;
        }
        accepted = accepted and tracker.finish(false, true);
        try std.testing.expectEqual(case.expected, accepted);
    }
}

test "authority validates IPv6 and IPvFuture literals" {
    const Case = struct {
        value: []const u8,
        expected: bool,
    };
    const cases = [_]Case{
        .{ .value = "[::1]:443", .expected = true },
        .{ .value = "[2001:db8::1]:443", .expected = true },
        .{ .value = "[::192.0.2.1]:443", .expected = true },
        .{ .value = "[1:2:3:4:5:6:192.0.2.1]:443", .expected = true },
        .{ .value = "[v1.host:part]:443", .expected = true },
        .{ .value = "[gg]:443", .expected = false },
        .{ .value = "[1:2:3:4:5:6:7]:443", .expected = false },
        .{ .value = "[1:2:3:4:5:6:7:8:9]:443", .expected = false },
        .{ .value = "[::192.168.001.1]:443", .expected = false },
        .{ .value = "[::256.0.0.1]:443", .expected = false },
        .{ .value = "[v.example]:443", .expected = false },
        .{ .value = "[v1.]:443", .expected = false },
    };

    for (cases) |case| {
        var tracker = Tracker{};
        var accepted = true;
        for (case.value) |byte| {
            if (!tracker.consume(byte)) accepted = false;
        }
        accepted = accepted and tracker.finish(false, true);
        try std.testing.expectEqual(case.expected, accepted);
    }
}

test "a reg-name run leaves the tracker as per-byte consumption does" {
    const inputs = [_][]const u8{ "", "example.com", "127.0.0.1:8080", "a%41b:1", "[::1]:80", ":80", "a b", "host-" };
    for (inputs) |input| {
        var per_byte = Tracker{};
        var per_byte_ok = true;
        for (input) |byte| per_byte_ok = per_byte_ok and per_byte.consume(byte);

        var with_run = Tracker{};
        var index = with_run.consumeRegNameRun(input);
        var with_run_ok = true;
        while (index < input.len) : (index += 1) with_run_ok = with_run_ok and with_run.consume(input[index]);

        try std.testing.expectEqual(per_byte_ok, with_run_ok);
        try std.testing.expectEqual(per_byte.state, with_run.state);
        try std.testing.expectEqual(per_byte.host_length, with_run.host_length);
        try std.testing.expectEqual(per_byte.finish(false, false), with_run.finish(false, false));
    }
}
