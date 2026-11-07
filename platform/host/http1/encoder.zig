const std = @import("std");
const syntax = @import("syntax.zig");
const types = @import("types.zig");

const header_separator = ": ";
const line_ending = "\r\n";
const status_line_length = "HTTP/1.1 599 \r\n".len;
pub const maximum_header_count: usize = 128;
pub const maximum_head_bytes: usize = 32 * 1024;
pub const maximum_coalesced_body_bytes: usize = 64;

pub const ResponseBuffer = struct {
    bytes: [maximum_head_bytes]u8 = undefined,
};

pub const IovecBuffer = [2]std.posix.iovec_const;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpVersion = types.HttpVersion;

pub const EncodeError = error{
    InvalidStatus,
    TooManyHeaders,
    InvalidHeaderName,
    InvalidHeaderValue,
    HeaderSectionTooLarge,
    MessageTooLarge,
    AliasingInput,
};

pub const AdvanceError = error{
    WriteBeyondEnd,
};

pub const Encoder = struct {
    head: []const u8,
    body: []const u8,
    remaining_length: usize,

    pub fn init(
        status: u16,
        headers: []const Header,
        body: []const u8,
        response_buffer: *ResponseBuffer,
    ) EncodeError!Encoder {
        return initAdapted(
            Header,
            status,
            headers,
            body,
            response_buffer,
            identityHeader,
        );
    }

    pub fn initAdapted(
        comptime SourceHeader: type,
        status: u16,
        headers: []const SourceHeader,
        body: []const u8,
        response_buffer: *ResponseBuffer,
        comptime headerView: fn (*const SourceHeader) Header,
    ) EncodeError!Encoder {
        return initAdaptedWithExtra(
            SourceHeader,
            HttpVersion.http_1_1,
            status,
            headers,
            &.{},
            body,
            response_buffer,
            headerView,
        );
    }

    pub fn initAdaptedWithExtra(
        comptime SourceHeader: type,
        version: HttpVersion,
        status: u16,
        headers: []const SourceHeader,
        extra_headers: []const Header,
        body: []const u8,
        response_buffer: *ResponseBuffer,
        comptime headerView: fn (*const SourceHeader) Header,
    ) EncodeError!Encoder {
        if (status < 100 or status > 599) return EncodeError.InvalidStatus;
        const header_count = std.math.add(
            usize,
            headers.len,
            extra_headers.len,
        ) catch return EncodeError.TooManyHeaders;
        if (header_count > maximum_header_count) return EncodeError.TooManyHeaders;

        const output = response_buffer.bytes[0..];
        if (overlaps(output, body)) return EncodeError.AliasingInput;
        for (headers) |*source_header| {
            const header = headerView(source_header);
            if (overlaps(output, header.name) or
                overlaps(output, header.value))
            {
                return EncodeError.AliasingInput;
            }
        }
        for (extra_headers) |header| {
            if (overlaps(output, header.name) or
                overlaps(output, header.value))
            {
                return EncodeError.AliasingInput;
            }
        }

        writeStatusLine(output, version, status);
        var head_offset = status_line_length;

        for (headers) |*source_header| {
            const header = headerView(source_header);
            try writeHeader(output, &head_offset, header);
        }
        for (extra_headers) |header| {
            try writeHeader(output, &head_offset, header);
        }

        copyInto(output, &head_offset, line_ending);
        const message_length = std.math.add(
            usize,
            head_offset,
            body.len,
        ) catch return EncodeError.MessageTooLarge;
        if (message_length > std.math.maxInt(isize)) return EncodeError.MessageTooLarge;

        const copy_body = body.len <= maximum_coalesced_body_bytes and
            body.len <= output.len - head_offset;
        if (copy_body) {
            copyInto(output, &head_offset, body);
        }

        return Encoder{
            .head = output[0..head_offset],
            .body = if (copy_body) "" else body,
            .remaining_length = message_length,
        };
    }

    pub fn remainingIovecs(
        self: *const Encoder,
        output: *IovecBuffer,
    ) []const std.posix.iovec_const {
        var count: usize = 0;
        if (self.head.len > 0) {
            output[count] = iovecFor(self.head);
            count += 1;
        }
        if (self.body.len > 0) {
            output[count] = iovecFor(self.body);
            count += 1;
        }
        return output[0..count];
    }

    pub fn advance(
        self: *Encoder,
        written: usize,
    ) AdvanceError!void {
        if (written > self.remaining_length) return AdvanceError.WriteBeyondEnd;

        const head_written = @min(written, self.head.len);
        self.head = self.head[head_written..];

        const body_written = written - head_written;
        if (body_written > 0) {
            self.body = self.body[body_written..];
        }
        self.remaining_length -= written;
    }

    pub fn remainingBytes(self: *const Encoder) usize {
        return self.remaining_length;
    }

    pub fn isComplete(self: *const Encoder) bool {
        return self.remaining_length == 0;
    }
};

fn identityHeader(header: *const Header) Header {
    return header.*;
}

fn checkedFieldLength(header: Header) ?usize {
    var length = std.math.add(
        usize,
        header.name.len,
        header_separator.len,
    ) catch return null;
    length = std.math.add(
        usize,
        length,
        header.value.len,
    ) catch return null;
    return std.math.add(usize, length, line_ending.len) catch null;
}

fn overlaps(output: []u8, input: []const u8) bool {
    if (input.len == 0) return false;
    const output_start = @intFromPtr(output.ptr);
    const input_start = @intFromPtr(input.ptr);
    if (output_start <= input_start) return input_start - output_start < output.len;
    return output_start - input_start < input.len;
}

fn writeStatusLine(
    output: []u8,
    version: HttpVersion,
    status: u16,
) void {
    const prefix = switch (version) {
        HttpVersion.http_1_0 => "HTTP/1.0 ",
        HttpVersion.http_1_1 => "HTTP/1.1 ",
    };
    @memcpy(output[0..prefix.len], prefix);
    output[prefix.len] = '0' + @as(u8, @intCast(status / 100));
    output[prefix.len + 1] = '0' + @as(u8, @intCast(status / 10 % 10));
    output[prefix.len + 2] = '0' + @as(u8, @intCast(status % 10));
    output[prefix.len + 3] = ' ';
    output[prefix.len + 4] = '\r';
    output[prefix.len + 5] = '\n';
}

fn writeHeader(
    output: []u8,
    head_offset: *usize,
    header: Header,
) EncodeError!void {
    if (header.name.len == 0) return EncodeError.InvalidHeaderName;

    const field_length = checkedFieldLength(header) orelse
        return EncodeError.MessageTooLarge;
    if (field_length > output.len - head_offset.* - line_ending.len) return EncodeError.HeaderSectionTooLarge;

    if (!syntax.validateAndCopyToken(
        output[head_offset.*..][0..header.name.len],
        header.name,
    )) return EncodeError.InvalidHeaderName;
    head_offset.* += header.name.len;

    copyInto(output, head_offset, header_separator);
    if (!syntax.validateAndCopyFieldValue(
        output[head_offset.*..][0..header.value.len],
        header.value,
    )) return EncodeError.InvalidHeaderValue;
    head_offset.* += header.value.len;
    copyInto(output, head_offset, line_ending);
}

fn copyInto(output: []u8, offset: *usize, bytes: []const u8) void {
    @memcpy(output[offset.*..][0..bytes.len], bytes);
    offset.* += bytes.len;
}

fn iovecFor(bytes: []const u8) std.posix.iovec_const {
    std.debug.assert(bytes.len > 0);
    return .{ .base = bytes.ptr, .len = bytes.len };
}
