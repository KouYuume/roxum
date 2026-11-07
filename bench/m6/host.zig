const std = @import("std");
const builtin = @import("builtin");
const host = @import("host");

comptime {
    if (!builtin.is_test) @export(&cMain, .{ .name = "main" });
    @export(&host.runtime.rocAlloc, .{ .name = "roc_alloc" });
    @export(&host.runtime.rocDealloc, .{ .name = "roc_dealloc" });
    @export(&host.runtime.rocRealloc, .{ .name = "roc_realloc" });
    @export(&host.runtime.rocDebug, .{ .name = "roc_dbg" });
    @export(&host.runtime.rocExpectFailed, .{ .name = "roc_expect_failed" });
    @export(&host.runtime.rocCrashed, .{ .name = "roc_crashed" });
    @export(&host.log_effect.hostedLogWrite, .{
        .name = "roxum_log_write",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.time_effect.hostedTimeNowUnixMilliseconds, .{
        .name = "roxum_time_now_unix_milliseconds",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.instant_effect.hostedInstantNowNanoseconds, .{
        .name = "roxum_instant_now_nanoseconds",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.random_effect.hostedRandomU64, .{
        .name = "roxum_random_u64",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.body_effect.hostedBodyRead, .{
        .name = "roxum_body_read",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.file_effect.hostedFileRead, .{
        .name = "roxum_file_read",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.secret_effect.hostedSecretFromFile, .{
        .name = "roxum_secret_from_file",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.secret_effect.hostedSecretFromEnv, .{
        .name = "roxum_secret_from_env",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.secret_effect.hostedSecretDerive, .{
        .name = "roxum_secret_derive",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.rate_counter_effect.hostedRateCounterNew, .{
        .name = "roxum_rate_counter_new",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.rate_counter_effect.hostedRateCounterAdd, .{
        .name = "roxum_rate_counter_add",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.concurrency_effect.hostedConcurrencyNew, .{
        .name = "roxum_concurrency_new",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.concurrency_effect.hostedConcurrencyAcquire, .{
        .name = "roxum_concurrency_acquire",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpPool, .{
        .name = "roxum_tcp_pool",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpAcquire, .{
        .name = "roxum_tcp_acquire",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpAcquireOrigin, .{
        .name = "roxum_tcp_acquire_origin",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpConfigureOrigins, .{
        .name = "roxum_tcp_configure_origins",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpCheckCa, .{
        .name = "roxum_tcp_check_ca",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpRelease, .{
        .name = "roxum_tcp_release",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpIsNew, .{
        .name = "roxum_tcp_is_new",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpDiscard, .{
        .name = "roxum_tcp_discard",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpWrite, .{
        .name = "roxum_tcp_write",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpWriteDerived, .{
        .name = "roxum_tcp_write_derived",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpRead, .{
        .name = "roxum_tcp_read",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpStartTls, .{
        .name = "roxum_tcp_start_tls",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
}

/// The comparison of one multi-threaded process against one process per
/// CPU ended with processes; thread mode was removed from the host, so only
/// `processes` remains.
fn cMain(
    argc: c_int,
    argv: [*][*:0]u8,
) callconv(std.builtin.CallingConvention.c) c_int {
    if (argc != 2) return 2;
    if (!std.mem.eql(u8, std.mem.span(argv[1]), "processes")) return 2;

    host.supervisor.run(workerMain, .{}) catch |err| {
        host.diagnostics.hostFailed(err);
        return 1;
    };
}

fn workerMain(port_override: ?u16) c_int {
    var environment = host.arena.ArenaEnvironment.production();
    defer environment.deinit();
    host.server.run(&environment, host.ConnectionLimits{}, port_override) catch |err| {
        host.diagnostics.hostFailed(err);
        return 1;
    };
    return 0;
}
