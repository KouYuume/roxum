const std = @import("std");

pub const maximum_head_bytes: usize = 32 * 1024;
pub const maximum_request_target_bytes: usize = 8 * 1024;
/// The largest body the event loop receives before the handler runs.
/// A larger one is handed over unread, and the handler's reads wait for it.
/// Not a limit on the body: `Server.Limits` sets those.
pub const maximum_prebuffered_body_bytes: usize = 64 * 1024;
pub const maximum_wire_bytes: usize = 128 * 1024;
/// Wire bytes a chunked body may take beyond 8 for each body byte, framing
/// included. One-byte chunks (`1\r\nX\r\n`) cost 6 wire bytes per body
/// byte; this allows that and stops a stream of chunk extensions or empty
/// framing.
pub const framing_allowance_bytes: usize = 8 * maximum_prebuffered_body_bytes;

/// Whether a chunked body's framing is out of proportion to its data:
/// `wire` bytes on the wire for `decoded` bytes of body.
pub fn framingIsExcessive(wire: u64, decoded: u64) bool {
    return wire > 8 *| decoded +| framing_allowance_bytes;
}

pub fn headLengthIsAllowed(length: usize) bool {
    return length <= maximum_head_bytes;
}

pub fn requestTargetLengthIsAllowed(length: usize) bool {
    return length <= maximum_request_target_bytes;
}

/// A Content-Length the event loop receives before the handler runs.
pub fn prebufferedBodyLength(content_length: u64) ?usize {
    const length = std.math.cast(usize, content_length) orelse return null;
    if (length > maximum_prebuffered_body_bytes) return null;
    return length;
}

test "head length covers below at and above its inclusive maximum" {
    try std.testing.expect(
        headLengthIsAllowed(maximum_head_bytes - 1),
    );
    try std.testing.expect(
        headLengthIsAllowed(maximum_head_bytes),
    );
    try std.testing.expect(
        !headLengthIsAllowed(maximum_head_bytes + 1),
    );
}

test "the prebuffered body length covers below at and above its inclusive maximum" {
    try std.testing.expectEqual(
        @as(?usize, maximum_prebuffered_body_bytes - 1),
        prebufferedBodyLength(maximum_prebuffered_body_bytes - 1),
    );
    try std.testing.expectEqual(
        @as(?usize, maximum_prebuffered_body_bytes),
        prebufferedBodyLength(maximum_prebuffered_body_bytes),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        prebufferedBodyLength(maximum_prebuffered_body_bytes + 1),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        prebufferedBodyLength(std.math.maxInt(u64)),
    );
}

test "framing is excessive past 8 wire bytes for each body byte and the allowance" {
    try std.testing.expect(!framingIsExcessive(8 * 100 + framing_allowance_bytes, 100));
    try std.testing.expect(framingIsExcessive(8 * 100 + framing_allowance_bytes + 1, 100));
    try std.testing.expect(!framingIsExcessive(std.math.maxInt(u64), std.math.maxInt(u64)));
}

test "request target length covers below at and above its inclusive maximum" {
    try std.testing.expect(
        requestTargetLengthIsAllowed(maximum_request_target_bytes - 1),
    );
    try std.testing.expect(
        requestTargetLengthIsAllowed(maximum_request_target_bytes),
    );
    try std.testing.expect(
        !requestTargetLengthIsAllowed(maximum_request_target_bytes + 1),
    );
}
