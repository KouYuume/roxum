//! Worker configuration shared by connection slots. A slot holds its session
//! until negotiation fails or transfers ownership to the HTTP transport.
const std = @import("std");

pub const Credentials = opaque {};
pub const Session = opaque {};
pub const Result = enum(c_int) { failed, want_read, want_write, http1, http2 };

pub extern "c" fn roxum_tls_credentials_load([*:0]const u8, [*:0]const u8) ?*Credentials;
pub extern "c" fn roxum_tls_credentials_free(*Credentials) void;

extern "c" fn roxum_tls_session_open(*const Credentials, c_int) ?*Session;
extern "c" fn roxum_tls_handshake(*Session) Result;
extern "c" fn roxum_tls_session_free(*Session) void;

pub const Config = struct {
    credentials: *const Credentials,
    maximum_pending: usize,
    timeout_milliseconds: u64,
    records: *const @import("records.zig").Ops,
    open: *const @TypeOf(roxum_tls_session_open) = roxum_tls_session_open,
    step: *const @TypeOf(roxum_tls_handshake) = roxum_tls_handshake,
    free: *const @TypeOf(roxum_tls_session_free) = roxum_tls_session_free,
    finished: ?*const fn (Result) callconv(std.builtin.CallingConvention.c) void = null,
};
