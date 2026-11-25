//! Worker configuration shared by connection slots. A slot holds its session
//! under the connection lock until negotiation ends or the loop closes it.
const std = @import("std");

pub const Credentials = opaque {};
pub const Session = opaque {};
pub const Result = enum(c_int) { failed, want_read, want_write, http1, http2 };

extern "c" fn roxum_tls_session_open(*const Credentials, c_int) ?*Session;
extern "c" fn roxum_tls_handshake(*Session) Result;
extern "c" fn roxum_tls_session_free(*Session) void;

pub const Config = struct {
    credentials: *const Credentials,
    maximum_pending: usize,
    timeout_milliseconds: u64,
    open: *const @TypeOf(roxum_tls_session_open) = roxum_tls_session_open,
    step: *const @TypeOf(roxum_tls_handshake) = roxum_tls_handshake,
    free: *const @TypeOf(roxum_tls_session_free) = roxum_tls_session_free,
    finished: *const fn (Result) callconv(std.builtin.CallingConvention.c) void,
};
