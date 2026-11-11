const std = @import("std");
const request = @import("request.zig");
const authority = @import("../http1/authority.zig");
const target = @import("../http1/request_target.zig");
const TargetForm = @import("../http1/types.zig").TargetForm;
const syntax = @import("../http1/syntax.zig");

pub const Input = @import("../http2/input.zig").Input;
const Header = request.MetadataHeader;
pub const Error = request.RequestError || error{InvalidHeaders};

/// Convert a complete initial field section after engine validation and header
/// admission. Never pass trailers or an incomplete callback prefix. The caller
/// bounds fields/body and supplies temporary storage charged to its own budget.
/// Returned values own their bytes; no input or scratch slices escape. Only the
/// result belongs to the Roc request lifetime. No dispatch or body reader is installed.
pub fn requestFromHttp2(
    allocator: std.mem.Allocator,
    fields: []const Header,
    body: []const u8,
    remote: request.RemoteAddress,
    id: []const u8,
    host: request.RequestHost,
) Error!request.HttpRequest {
    var method_text: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var scheme: ?[]const u8 = null;
    var authority_text: ?[]const u8 = null;
    var host_text: ?[]const u8 = null;
    var ordinary_start = fields.len;
    var cookie_count: usize = 0;
    var cookie_length: usize = 0;
    for (fields, 0..) |field, index| {
        if (field.name.len == 0) return error.InvalidHeaders;
        if (field.name[0] == ':') {
            if (ordinary_start != fields.len) return error.InvalidHeaders;
            const destination = if (std.mem.eql(u8, field.name, ":method"))
                &method_text
            else if (std.mem.eql(u8, field.name, ":path"))
                &path
            else if (std.mem.eql(u8, field.name, ":scheme"))
                &scheme
            else if (std.mem.eql(u8, field.name, ":authority"))
                &authority_text
            else
                return error.InvalidHeaders;
            if (destination.* != null) return error.InvalidHeaders;
            destination.* = field.value;
        } else {
            if (ordinary_start == fields.len) ordinary_start = index;
            if (std.mem.eql(u8, field.name, "host")) {
                if (host_text != null) return error.InvalidHeaders;
                host_text = field.value;
            }
            if (std.mem.eql(u8, field.name, "cookie")) {
                if (cookie_count != 0) cookie_length = std.math.add(usize, cookie_length, 2) catch return error.AllocationTooLarge;
                cookie_length = std.math.add(usize, cookie_length, field.value.len) catch return error.AllocationTooLarge;
                cookie_count += 1;
            }
        }
    }
    const method = request.classifyMethod(method_text orelse return error.InvalidHeaders) orelse return error.UnsupportedMethod;
    const request_path = path orelse return error.InvalidHeaders;
    const request_scheme = scheme orelse return error.InvalidHeaders;
    if (request_scheme.len == 0 or !syntax.isSchemeFirst(request_scheme[0])) return error.InvalidHeaders;
    for (request_scheme[1..]) |byte| if (!syntax.isSchemeRest(byte)) return error.InvalidHeaders;
    if (request_path.len == 0 or request_path.len > std.math.maxInt(u32)) return error.InvalidTarget;
    const method_kind = if (method == request.HttpMethod.options) target.MethodKind.options else target.MethodKind.other;
    var tracker: target.Tracker = .{};
    tracker.start(method_kind);
    for (request_path) |byte| if (!tracker.consume(byte)) return error.InvalidTarget;
    switch (tracker.finish(method_kind)) {
        target.Result.err => return error.InvalidTarget,
        target.Result.form => |form| if (form != TargetForm.origin and form != TargetForm.asterisk) return error.InvalidTarget,
    }
    const effective_host = authority_text orelse host_text orelse return error.InvalidHeaders;
    var host_tracker: authority.Tracker = .{};
    for (effective_host) |byte| if (!host_tracker.consume(byte)) return error.InvalidHeaders;
    if (!host_tracker.finish(false, false)) return error.InvalidHeaders;
    // Use a conservative textual comparison: do not guess URI equivalence for
    // percent escapes, default ports, or differently written IP literals.
    if (authority_text != null and host_text != null and !std.ascii.eqlIgnoreCase(effective_host, host_text.?)) return error.InvalidHeaders;

    const ordinary = fields[ordinary_start..];
    const capacity = std.math.add(usize, ordinary.len, 1) catch return error.AllocationTooLarge;
    const normalized = try allocator.alloc(Header, capacity);
    defer allocator.free(normalized);
    const cookie = try allocator.alloc(u8, if (cookie_count > 1) cookie_length else 0);
    defer allocator.free(cookie);
    var length: usize = 1;
    normalized[0] = .{ .name = "host", .value = effective_host };
    var cookie_written = false;
    var cookie_offset: usize = 0;
    for (ordinary) |field| {
        if (std.mem.eql(u8, field.name, "host")) continue;
        if (cookie_count > 1 and std.mem.eql(u8, field.name, "cookie")) {
            if (!cookie_written) {
                cookie_written = true;
                normalized[length] = .{ .name = "cookie", .value = cookie };
                length += 1;
            } else {
                @memcpy(cookie[cookie_offset..][0..2], "; ");
                cookie_offset += 2;
            }
            @memcpy(cookie[cookie_offset..][0..field.value.len], field.value);
            cookie_offset += field.value.len;
            continue;
        }
        normalized[length] = field;
        length += 1;
    }
    const Version = @TypeOf(@as(request.Metadata, undefined).version);
    return request.requestFromMetadata(.{ .method = method, .target = request_path, .version = Version.http20, .headers = normalized[0..length] }, body, remote, id, host);
}

/// Consume completed, admitted input outside engine callbacks. The caller must
/// supply an active request allocation domain through host. Initial fields and
/// finite body bytes are copied into that domain before connection input is freed.
/// A completed input is released even when conversion fails; earlier or already
/// released input returns InvalidState without being modified. No borrowed input
/// survives this call. The returned request still needs normal Roc cleanup.
pub fn requestFromHttp2Input(
    input: *Input,
    remote: request.RemoteAddress,
    id: []const u8,
    host: request.RequestHost,
) (Error || error{InvalidState})!request.HttpRequest {
    const body = input.body() orelse return error.InvalidState;
    const fields = input.headers() orelse return error.InvalidState;
    defer input.deinit();
    return requestFromHttp2(input.budget.allocator(), fields, body, remote, id, host);
}
