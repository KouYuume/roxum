const std = @import("std");
const authority = @import("authority.zig");
const syntax = @import("syntax.zig");
const types = @import("types.zig");

const ParseError = types.ParseError;
const TargetForm = types.TargetForm;

pub const MethodKind = enum {
    connect,
    options,
    other,
};

pub const Result = union(enum) {
    form: TargetForm,
    err: ParseError,
};

const State = enum {
    start,
    asterisk,
    origin_path,
    origin_query,
    scheme,
    absolute_hier_start,
    absolute_slash,
    absolute_authority,
    absolute_path,
    absolute_query,
    failed,
};

pub const Tracker = struct {
    length: u32 = 0,
    percent_digits_remaining: u2 = 0,

    state: State = State.start,
    track_authority: bool = false,
    scheme_length: usize = 0,
    scheme_maybe_http: bool = true,
    scheme_maybe_https: bool = true,
    is_http_family_scheme: bool = false,
    authority: authority.Tracker = .{},
    authority_userinfo_possible: bool = true,
    authority_has_userinfo: bool = false,

    pub fn start(self: *Tracker, method_kind: MethodKind) void {
        self.track_authority = method_kind == MethodKind.connect;
    }

    pub fn consume(self: *Tracker, byte: u8) bool {
        const accepted = if (self.track_authority) blk: {
            if (!syntax.isRequestTarget(byte)) break :blk false;
            break :blk self.consumeConnectAuthority(byte);
        } else self.consumeNonConnect(byte);
        if (!accepted) {
            self.state = State.failed;
            return false;
        }
        if (!self.consumePercentEncoding(byte)) {
            self.state = State.failed;
            return false;
        }

        self.length += 1;
        return true;
    }

    /// Consumes a leading run of origin-form path or query bytes in one step,
    /// with the same result as `consume` on each. It stops before `%`, `?`
    /// and any byte that changes or ends the target, and takes nothing in
    /// other states. Returns how many bytes it took.
    pub fn consumePlainRun(self: *Tracker, bytes: []const u8) usize {
        if (self.track_authority or self.percent_digits_remaining != 0) return 0;
        const length = switch (self.state) {
            State.origin_path => syntax.plainPathRun(bytes),
            State.origin_query => syntax.plainQueryRun(bytes),
            else => return 0,
        };
        self.length += @intCast(length);
        return length;
    }

    pub fn finish(
        self: Tracker,
        method_kind: MethodKind,
    ) Result {
        if (self.length == 0 or self.percent_digits_remaining != 0) {
            return Result{ .err = ParseError.invalid_request_target };
        }

        if (method_kind == MethodKind.connect) {
            if (!self.authority.finish(false, true)) return Result{ .err = ParseError.invalid_target_form };
            return Result{ .form = TargetForm.authority };
        }

        return switch (self.state) {
            State.asterisk => if (method_kind == MethodKind.options)
                Result{ .form = TargetForm.asterisk }
            else
                Result{ .err = ParseError.invalid_target_form },
            State.origin_path,
            State.origin_query,
            => Result{ .form = TargetForm.origin },
            State.absolute_hier_start,
            State.absolute_slash,
            => if (self.is_http_family_scheme)
                Result{ .err = ParseError.invalid_request_target }
            else
                Result{ .form = TargetForm.absolute },
            State.absolute_path,
            State.absolute_query,
            => Result{ .form = TargetForm.absolute },
            State.absolute_authority => if (self.authority.finish(
                !self.is_http_family_scheme,
                false,
            ))
                Result{ .form = TargetForm.absolute }
            else
                Result{ .err = ParseError.invalid_request_target },
            State.start,
            State.scheme,
            State.failed,
            => Result{ .err = ParseError.invalid_target_form },
        };
    }

    fn consumePercentEncoding(self: *Tracker, byte: u8) bool {
        if (self.percent_digits_remaining != 0) {
            if (!syntax.isHexDigit(byte)) return false;
            self.percent_digits_remaining -= 1;
        } else if (byte == '%') {
            self.percent_digits_remaining = 2;
        }
        return true;
    }

    fn consumeConnectAuthority(self: *Tracker, byte: u8) bool {
        _ = self.authority.consume(byte);
        return true;
    }

    fn consumeNonConnect(self: *Tracker, byte: u8) bool {
        return switch (self.state) {
            State.start => self.consumeTargetStart(byte),
            State.asterisk => false,
            State.origin_path => if (byte == '?') blk: {
                self.state = State.origin_query;
                break :blk true;
            } else syntax.isPathByte(byte),
            State.origin_query => syntax.isQueryByte(byte),
            State.scheme => self.consumeScheme(byte),
            State.absolute_hier_start => self.consumeAbsoluteHierStart(byte),
            State.absolute_slash => self.consumeAbsoluteSlash(byte),
            State.absolute_authority => self.consumeAbsoluteAuthority(byte),
            State.absolute_path => if (byte == '?') blk: {
                self.state = State.absolute_query;
                break :blk true;
            } else syntax.isPathByte(byte),
            State.absolute_query => syntax.isQueryByte(byte),
            State.failed => false,
        };
    }

    fn consumeTargetStart(self: *Tracker, byte: u8) bool {
        if (byte == '/') {
            self.state = State.origin_path;
            return true;
        }
        if (byte == '*') {
            self.state = State.asterisk;
            return true;
        }
        if (!syntax.isSchemeFirst(byte)) return false;
        self.state = State.scheme;
        self.trackSchemeByte(byte);
        return true;
    }

    fn consumeScheme(self: *Tracker, byte: u8) bool {
        if (byte == ':') {
            self.is_http_family_scheme =
                (self.scheme_maybe_http and self.scheme_length == "http".len) or
                (self.scheme_maybe_https and self.scheme_length == "https".len);
            self.state = State.absolute_hier_start;
            return true;
        }
        if (!syntax.isSchemeRest(byte)) return false;
        self.trackSchemeByte(byte);
        return true;
    }

    fn trackSchemeByte(self: *Tracker, byte: u8) void {
        const lower = std.ascii.toLower(byte);
        self.scheme_maybe_http = self.scheme_maybe_http and
            self.scheme_length < "http".len and
            lower == "http"[self.scheme_length];
        self.scheme_maybe_https = self.scheme_maybe_https and
            self.scheme_length < "https".len and
            lower == "https"[self.scheme_length];
        self.scheme_length += 1;
    }

    fn consumeAbsoluteHierStart(self: *Tracker, byte: u8) bool {
        if (byte == '/') {
            self.state = State.absolute_slash;
            return true;
        }
        if (self.is_http_family_scheme) return false;
        if (byte == '?') {
            self.state = State.absolute_query;
            return true;
        }
        if (!syntax.isPchar(byte)) return false;
        self.state = State.absolute_path;
        return true;
    }

    fn consumeAbsoluteSlash(self: *Tracker, byte: u8) bool {
        if (byte == '/') {
            self.state = State.absolute_authority;
            self.authority = authority.Tracker{};
            return true;
        }
        if (self.is_http_family_scheme) return false;
        if (byte == '?') {
            self.state = State.absolute_query;
            return true;
        }
        if (!syntax.isPchar(byte)) return false;
        self.state = State.absolute_path;
        return true;
    }

    fn consumeAbsoluteAuthority(self: *Tracker, byte: u8) bool {
        if (byte == '/' or byte == '?') {
            if (!self.authority.finish(
                !self.is_http_family_scheme,
                false,
            )) return false;
            self.state = if (byte == '/')
                State.absolute_path
            else
                State.absolute_query;
            return true;
        }

        if (byte == '@') {
            if (self.is_http_family_scheme or
                self.authority_has_userinfo or
                !self.authority_userinfo_possible)
            {
                return false;
            }
            self.authority_has_userinfo = true;
            self.authority = authority.Tracker{};
            return true;
        }

        if (!self.authority_has_userinfo) {
            self.authority_userinfo_possible =
                self.authority_userinfo_possible and
                syntax.isUserInfoByte(byte);
        }

        const host_possible = self.authority.consume(byte);
        return host_possible or
            (!self.authority_has_userinfo and
                self.authority_userinfo_possible);
    }
};

test "a plain run leaves the target tracker as per-byte consumption does" {
    const inputs = [_][]const u8{ "/", "/a/b/c", "/a?b=c&d", "/a%20b?c%2Fd", "/a?b?c", "*", "http://x/y", "/a b", "/%zz" };
    for (inputs) |input| {
        var per_byte = Tracker{};
        per_byte.start(MethodKind.other);
        var per_byte_ok = true;
        for (input) |byte| per_byte_ok = per_byte_ok and per_byte.consume(byte);

        var with_runs = Tracker{};
        with_runs.start(MethodKind.other);
        var with_runs_ok = true;
        var index: usize = 0;
        while (index < input.len and with_runs_ok) {
            index += with_runs.consumePlainRun(input[index..]);
            if (index == input.len) break;
            with_runs_ok = with_runs.consume(input[index]);
            index += 1;
        }

        try std.testing.expectEqual(per_byte_ok, with_runs_ok);
        try std.testing.expectEqual(per_byte.state, with_runs.state);
        try std.testing.expectEqual(per_byte.length, with_runs.length);
        try std.testing.expectEqual(per_byte.percent_digits_remaining, with_runs.percent_digits_remaining);
    }
}
