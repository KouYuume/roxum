const std = @import("std");
const abi = @import("../roc_platform_abi.zig");
const http1 = @import("../http1/parser.zig");

pub const Parser = http1.Parser;
pub const RequestLine = http1.RequestLine;
pub const Header = http1.Header;
pub const HttpMethod = abi.HttpMethod;
pub const HttpRequest = abi.HttpRequest;
pub const HttpRequestBodyTag = abi.HttpRequestBodyTag;
pub const RocHost = abi.RocHost;

/// What the host needs to build Roc values from a request. Roc's
/// `roc_alloc` must not return null, so the host's own allocations go
/// through `try_alloc`, which may; the caller then sends an error response.
/// Values built here are released through `roc_host`, so `try_alloc` must
/// use the same allocator as `roc_host.roc_alloc`.
pub const RequestHost = struct {
    roc_host: *RocHost,
    try_alloc: *const fn (
        roc_host: *RocHost,
        length: usize,
        alignment: usize,
    ) ?*anyopaque,
};

pub const RemoteAddress = union(enum) {
    unix,
    v4: struct {
        octets: [4]u8,
        port: u16,
    },
    v6: struct {
        segments: [8]u16,
        port: u16,
    },
};

pub const RequestError = error{
    InvalidSpan,
    InvalidTarget,
    UnsupportedMethod,
    AllocationTooLarge,
    OutOfMemory,
};

pub const HeadValidationError = error{
    InvalidSpan,
    InvalidTarget,
    UnsupportedMethod,
};

pub fn validateParsedHead(
    bytes: []const u8,
    request_line: RequestLine,
) HeadValidationError!void {
    _ = try parseHead(bytes, request_line);
}

const ParsedHead = struct {
    method: abi.HttpMethod,
    raw_target: []const u8,
    target: TargetParts,
};

fn parseHead(
    bytes: []const u8,
    request_line: RequestLine,
) HeadValidationError!ParsedHead {
    const method_bytes = try checkedSlice(
        bytes,
        request_line.method,
    );
    const method = classifyMethod(method_bytes) orelse
        return error.UnsupportedMethod;

    const raw_target_bytes = try checkedSlice(
        bytes,
        request_line.target,
    );
    const target = try splitTarget(
        raw_target_bytes,
        request_line.target_form,
    );
    try validatePath(target.path);

    return .{
        .method = method,
        .raw_target = raw_target_bytes,
        .target = target,
    };
}

fn validatePath(path: []const u8) error{InvalidTarget}!void {
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, start, '/')) |end| {
        if (end == start and start != 0) return error.InvalidTarget;
        try validateSegment(path[start..end]);
        start = end + 1;
    }
    try validateSegment(path[start..]);
}

fn validateSegment(segment: []const u8) error{InvalidTarget}!void {
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidTarget;
}

pub fn requestFromParsed(
    bytes: []const u8,
    request_line: RequestLine,
    headers: []const Header,
    body_bytes: []const u8,
    remote_address: RemoteAddress,
    request_id: []const u8,
    host: RequestHost,
) RequestError!abi.HttpRequest {
    return requestFromParsedBody(
        bytes,
        request_line,
        headers,
        .{ .bytes = body_bytes },
        remote_address,
        request_id,
        host,
    );
}

pub fn requestFromParsedStream(
    bytes: []const u8,
    request_line: RequestLine,
    headers: []const Header,
    stream_token: u64,
    remote_address: RemoteAddress,
    request_id: []const u8,
    host: RequestHost,
) RequestError!abi.HttpRequest {
    return requestFromParsedBody(
        bytes,
        request_line,
        headers,
        .{ .stream = stream_token },
        remote_address,
        request_id,
        host,
    );
}

const BodySource = union(enum) {
    bytes: []const u8,
    stream: u64,
};

/// Borrowed, validated transport metadata. Values are copied into Roc ownership.
pub const MetadataHeader = @import("../http_field.zig").Header;
pub const Metadata = struct {
    method: abi.HttpMethod,
    target: []const u8,
    version: abi.HttpVersion,
    headers: []const MetadataHeader,
};

const ParsedHeaders = struct {
    bytes: []const u8,
    headers: []const Header,
    fn len(self: @This()) usize {
        return self.headers.len;
    }
    fn at(self: @This(), index: usize) RequestError!MetadataHeader {
        const header = self.headers[index];
        return .{ .name = try checkedSlice(self.bytes, header.name), .value = try checkedSlice(self.bytes, header.value) };
    }
};
const MetadataHeaders = struct {
    headers: []const MetadataHeader,
    fn len(self: @This()) usize {
        return self.headers.len;
    }
    fn at(self: @This(), index: usize) RequestError!MetadataHeader {
        return self.headers[index];
    }
};

/// The transport validates method/header and target wire syntax, including
/// controls, fragments, and percent escapes, before supplying an origin-form or
/// asterisk target.
/// This builder enforces the same path policy and allocation rollback as HTTP/1.
pub fn requestFromMetadata(metadata: Metadata, body: []const u8, remote: RemoteAddress, id: []const u8, host: RequestHost) RequestError!abi.HttpRequest {
    if (metadata.target.len == 0 or (metadata.target[0] != '/' and !std.mem.eql(u8, metadata.target, "*"))) return error.InvalidTarget;
    const target = splitPathAndQuery(metadata.target);
    try validatePath(target.path);
    return buildRequest(.{ .method = metadata.method, .raw_target = metadata.target, .target = target }, metadata.version, MetadataHeaders{ .headers = metadata.headers }, .{ .bytes = body }, remote, id, host);
}

fn requestFromParsedBody(
    bytes: []const u8,
    request_line: RequestLine,
    headers: []const Header,
    body_source: BodySource,
    remote_address: RemoteAddress,
    request_id: []const u8,
    host: RequestHost,
) RequestError!abi.HttpRequest {
    return buildRequest(try parseHead(bytes, request_line), switch (request_line.version) {
        http1.HttpVersion.http_1_0 => abi.HttpVersion.http10,
        http1.HttpVersion.http_1_1 => abi.HttpVersion.http11,
    }, ParsedHeaders{ .bytes = bytes, .headers = headers }, body_source, remote_address, request_id, host);
}

fn buildRequest(parsed_head: ParsedHead, version: abi.HttpVersion, headers: anytype, body_source: BodySource, remote_address: RemoteAddress, request_id: []const u8, host: RequestHost) RequestError!abi.HttpRequest {
    var shared = try SharedBytes.init(
        try sharedLength(parsed_head, headers, request_id),
        host,
    );
    // Runs after the errdefers below: each value built holds its own
    // reference, so this frees the bytes only if none was built.
    defer shared.release(host);

    const raw_target = shared.list(parsed_head.raw_target);
    errdefer raw_target.decref(host.roc_host);

    const path = shared.str(parsed_head.target.path, SharedBytes.Case.keep);
    errdefer path.decref(host.roc_host);

    const query = shared.list(parsed_head.target.query);
    errdefer query.decref(host.roc_host);

    const request_headers = try requestHeaders(
        headers,
        &shared,
        host,
    );
    errdefer abi.decrefListOfHttpRequestHeader(
        request_headers,
        host.roc_host,
    );

    const roc_request_id = shared.str(request_id, SharedBytes.Case.keep);
    errdefer roc_request_id.decref(host.roc_host);
    std.debug.assert(shared.used == shared.length);

    const body = switch (body_source) {
        BodySource.bytes => |body_bytes| try requestBodyFromSlice(
            body_bytes,
            host,
        ),
        BodySource.stream => |token| requestBodyFromStream(token),
    };
    errdefer body.decref(host.roc_host);

    return .{
        .raw_target = raw_target,
        .path = path,
        .query = query,
        .headers = request_headers,
        .body = body,
        .remote_addr = remoteAddressToRoc(remote_address),
        .request_id = roc_request_id,
        .method = parsed_head.method,
        .version = version,
    };
}

fn requestBodyFromStream(token: u64) abi.HttpRequestBody {
    var result: abi.HttpRequestBody = undefined;
    result.tag = abi.HttpRequestBodyTag.Stream;
    const payload: *u64 = @ptrCast(@alignCast(&result.payload));
    payload.* = token;
    return result;
}

fn checkedSlice(
    bytes: []const u8,
    span: http1.Span,
) error{InvalidSpan}![]const u8 {
    const start: usize = span.start;
    const length: usize = span.len;
    if (start > bytes.len) return error.InvalidSpan;
    if (length > bytes.len - start) return error.InvalidSpan;
    return bytes[start .. start + length];
}

const TargetParts = struct {
    path: []const u8,
    query: []const u8,
};

fn splitTarget(
    target: []const u8,
    target_form: http1.TargetForm,
) error{InvalidTarget}!TargetParts {
    return switch (target_form) {
        http1.TargetForm.origin,
        http1.TargetForm.asterisk,
        => splitPathAndQuery(target),
        http1.TargetForm.absolute => splitAbsoluteTarget(target),
        http1.TargetForm.authority => error.InvalidTarget,
    };
}

fn splitPathAndQuery(target: []const u8) TargetParts {
    const query_separator = std.mem.indexOfScalar(
        u8,
        target,
        '?',
    ) orelse return .{
        .path = target,
        .query = &.{},
    };

    return .{
        .path = target[0..query_separator],
        .query = target[query_separator + 1 ..],
    };
}

fn splitAbsoluteTarget(
    target: []const u8,
) error{InvalidTarget}!TargetParts {
    const scheme_end = std.mem.indexOf(
        u8,
        target,
        "://",
    ) orelse return error.InvalidTarget;
    const authority_start = scheme_end + 3;
    if (authority_start >= target.len) return error.InvalidTarget;

    const suffix_start = std.mem.indexOfAnyPos(
        u8,
        target,
        authority_start,
        "/?",
    ) orelse return .{
        .path = "/",
        .query = &.{},
    };

    if (target[suffix_start] == '?') {
        return .{
            .path = "/",
            .query = target[suffix_start + 1 ..],
        };
    }
    return splitPathAndQuery(target[suffix_start..]);
}

pub fn classifyMethod(method: []const u8) ?abi.HttpMethod {
    if (std.mem.eql(u8, method, "OPTIONS")) return abi.HttpMethod.options;
    if (std.mem.eql(u8, method, "GET")) return abi.HttpMethod.get;
    if (std.mem.eql(u8, method, "HEAD")) return abi.HttpMethod.head;
    if (std.mem.eql(u8, method, "POST")) return abi.HttpMethod.post;
    if (std.mem.eql(u8, method, "PUT")) return abi.HttpMethod.put;
    if (std.mem.eql(u8, method, "DELETE")) return abi.HttpMethod.delete;
    if (std.mem.eql(u8, method, "PATCH")) return abi.HttpMethod.patch;
    if (std.mem.eql(u8, method, "QUERY")) return abi.HttpMethod.query;
    return null;
}

fn requestHeaders(
    headers: anytype,
    shared: *SharedBytes,
    host: RequestHost,
) RequestError!abi.RocList(abi.HttpRequestHeader) {
    var result = try allocateRocList(
        abi.HttpRequestHeader,
        true,
        headers.len(),
        host,
    );
    var initialized: usize = 0;
    errdefer {
        if (result.elements_ptr) |items| {
            for (items[0..initialized]) |item| item.decref(host.roc_host);
        }
        result.decref(host.roc_host);
    }

    const output = result.elements_ptr orelse return result;
    for (0..headers.len()) |index| {
        const header = try headers.at(index);
        const name_bytes = header.name;
        const value_bytes = header.value;
        output[initialized] = .{
            .name = shared.str(name_bytes, SharedBytes.Case.lower),
            .value = shared.list(value_bytes),
        };
        initialized += 1;
    }
    return result;
}

/// The bytes `SharedBytes` must hold for one request: every byte value except
/// strings short enough to be stored inline.
fn sharedLength(
    parsed_head: ParsedHead,
    headers: anytype,
    request_id: []const u8,
) RequestError!usize {
    var total: usize = 0;
    const add = struct {
        fn list(sum: *usize, length: usize) RequestError!void {
            sum.* = std.math.add(usize, sum.*, length) catch return error.AllocationTooLarge;
        }
        fn str(sum: *usize, length: usize) RequestError!void {
            if (!SharedBytes.isInline(length)) try list(sum, length);
        }
    };
    try add.list(&total, parsed_head.raw_target.len);
    try add.str(&total, parsed_head.target.path.len);
    try add.list(&total, parsed_head.target.query.len);
    for (0..headers.len()) |index| {
        const header = try headers.at(index);
        try add.str(&total, header.name.len);
        try add.list(&total, header.value.len);
    }
    try add.str(&total, request_id.len);
    return total;
}

/// One allocation holding the bytes of a request's target, header names and
/// values, and request ID. Each value built from it is a seamless slice that
/// holds one reference, so the bytes live until the last value is released;
/// a request's values cannot outlive its request. The builder holds one more
/// reference until `release`, so a failure part way through frees exactly
/// what was built. One allocation replaces one per value.
const SharedBytes = struct {
    data: ?[*]u8,
    length: usize,
    used: usize = 0,

    const Case = enum { keep, lower };
    const Bytes = abi.RocListWith(u8, false);

    fn isInline(length: usize) bool {
        return length < @sizeOf(abi.RocStr);
    }

    fn init(length: usize, host: RequestHost) RequestError!SharedBytes {
        const backing = try allocateRocList(u8, false, length, host);
        return .{ .data = backing.elements_ptr, .length = length };
    }

    fn release(self: *const SharedBytes, host: RequestHost) void {
        const data = self.data orelse return;
        const backing = Bytes{ .elements_ptr = data, .length = self.length, .capacity_or_alloc_ptr = self.length << 1 };
        backing.decref(host.roc_host);
    }

    /// Copies `source` in, adding a reference for the slice that will hold it.
    fn take(self: *SharedBytes, source: []const u8, case: Case) [*]u8 {
        const data = self.data.?;
        std.debug.assert(source.len <= self.length - self.used);
        const start = data + self.used;
        switch (case) {
            Case.keep => @memcpy(start[0..source.len], source),
            Case.lower => for (source, 0..) |byte, index| {
                start[index] = std.ascii.toLower(byte);
            },
        }
        self.used += source.len;
        const refcount: *isize = @ptrFromInt(@intFromPtr(data) - @sizeOf(isize));
        refcount.* += 1;
        return start;
    }

    fn sliceTag(self: *const SharedBytes) usize {
        return @intFromPtr(self.data.?) | 1;
    }

    fn list(self: *SharedBytes, source: []const u8) Bytes {
        if (source.len == 0) return Bytes.empty();
        const start = self.take(source, Case.keep);
        return .{ .elements_ptr = start, .length = source.len, .capacity_or_alloc_ptr = self.sliceTag() };
    }

    fn str(self: *SharedBytes, source: []const u8, case: Case) abi.RocStr {
        if (isInline(source.len)) {
            var result = abi.RocStr.empty();
            const raw: [*]u8 = @ptrCast(&result);
            switch (case) {
                Case.keep => @memcpy(raw[0..source.len], source),
                Case.lower => for (source, 0..) |byte, index| {
                    raw[index] = std.ascii.toLower(byte);
                },
            }
            raw[@sizeOf(abi.RocStr) - 1] = @as(u8, @intCast(source.len)) | 0x80;
            return result;
        }
        const start = self.take(source, case);
        return .{ .bytes = start, .capacity_or_alloc_ptr = self.sliceTag(), .length = source.len };
    }
};

fn requestBodyFromSlice(
    bytes: []const u8,
    host: RequestHost,
) RequestError!abi.HttpRequestBody {
    var result: abi.HttpRequestBody = undefined;
    if (bytes.len == 0) {
        result.tag = abi.HttpRequestBodyTag.Empty;
        result.payload = std.mem.zeroes(@TypeOf(result.payload));
        return result;
    }

    const body = try rocByteListFromSliceChecked(
        bytes,
        host,
    );
    result.tag = abi.HttpRequestBodyTag.Bytes;
    const payload: *abi.RocListWith(u8, false) = @ptrCast(
        @alignCast(&result.payload),
    );
    payload.* = body;
    return result;
}

fn remoteAddressToRoc(
    remote_address: RemoteAddress,
) abi.HttpRemoteAddr {
    var result = std.mem.zeroes(abi.HttpRemoteAddr);
    if (remote_address == RemoteAddress.unix) {
        result.tag = abi.HttpRemoteAddrTag.Unix;
        return result;
    }
    result.tag = abi.HttpRemoteAddrTag.Tcp;
    const payload: *abi.HttpRemoteAddrTcp = @ptrCast(@alignCast(&result.payload));
    payload.* = switch (remote_address) {
        RemoteAddress.v4 => |address| .{ .ip = ipv4ToRoc(address.octets), .port = address.port },
        RemoteAddress.v6 => |address| .{ .ip = ipv6ToRoc(address.segments), .port = address.port },
        RemoteAddress.unix => unreachable,
    };
    return result;
}

fn ipv4ToRoc(octets: [4]u8) abi.HttpIpAddr {
    var result: abi.HttpIpAddr = undefined;
    result.tag = abi.HttpIpAddrTag.V4;
    const payload: *abi.HttpIpAddrV4 = @ptrCast(
        @alignCast(&result.payload),
    );
    payload.* = .{
        ._0 = octets[0],
        ._1 = octets[1],
        ._2 = octets[2],
        ._3 = octets[3],
    };
    return result;
}

fn ipv6ToRoc(segments: [8]u16) abi.HttpIpAddr {
    var result: abi.HttpIpAddr = undefined;
    result.tag = abi.HttpIpAddrTag.V6;
    const payload: *abi.HttpIpAddrV6 = @ptrCast(
        @alignCast(&result.payload),
    );
    payload.* = .{
        ._0 = segments[0],
        ._1 = segments[1],
        ._2 = segments[2],
        ._3 = segments[3],
        ._4 = segments[4],
        ._5 = segments[5],
        ._6 = segments[6],
        ._7 = segments[7],
    };
    return result;
}

pub fn rocByteListFromSliceChecked(
    items: []const u8,
    host: RequestHost,
) RequestError!abi.RocListWith(u8, false) {
    const result = try allocateRocList(
        u8,
        false,
        items.len,
        host,
    );
    if (items.len == 0) return result;
    @memcpy(result.elements_ptr.?[0..items.len], items);
    return result;
}

fn allocateRocList(
    comptime T: type,
    comptime elements_refcounted: bool,
    length: usize,
    host: RequestHost,
) RequestError!abi.RocListWith(T, elements_refcounted) {
    const List = abi.RocListWith(T, elements_refcounted);
    if (length == 0) return List.empty();

    const encoded_capacity = try encodeCapacity(length);
    const pointer_width = @sizeOf(usize);
    const required_space = if (elements_refcounted)
        2 * pointer_width
    else
        pointer_width;
    const header_bytes = @max(required_space, @alignOf(T));
    const allocation_alignment = @max(pointer_width, @alignOf(T));
    const data_bytes = std.math.mul(
        usize,
        length,
        @sizeOf(T),
    ) catch return error.AllocationTooLarge;
    const total = std.math.add(
        usize,
        data_bytes,
        header_bytes,
    ) catch return error.AllocationTooLarge;

    const base: [*]u8 = @ptrCast(
        host.try_alloc(
            host.roc_host,
            total,
            allocation_alignment,
        ) orelse return error.OutOfMemory,
    );
    const data = base + header_bytes;
    const refcount: *isize = @ptrFromInt(
        @intFromPtr(data) - @sizeOf(isize),
    );
    refcount.* = 1;
    if (elements_refcounted) {
        const count: *usize = @ptrFromInt(
            @intFromPtr(data) - 2 * @sizeOf(usize),
        );
        count.* = length;
    }

    return .{
        .elements_ptr = @ptrCast(@alignCast(data)),
        .length = length,
        .capacity_or_alloc_ptr = encoded_capacity,
    };
}

fn encodeCapacity(length: usize) RequestError!usize {
    const maximum = std.math.maxInt(usize) >> 1;
    if (length > maximum) return error.AllocationTooLarge;
    return length << 1;
}
