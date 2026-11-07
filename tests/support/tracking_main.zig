const std = @import("std");
const builtin = @import("builtin");
const host = @import("host");
const tracking_environment = @import("allocator/tracking_environment.zig");

comptime {
    if (!builtin.is_test) {
        @export(&cMain, .{ .name = "main" });
    }

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
    @export(&host.sleep_effect.hostedSleepMilliseconds, .{
        .name = "roxum_sleep_milliseconds",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.sleep_effect.hostedSleepUntil, .{
        .name = "roxum_sleep_until",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.response_writer.hostedStreamStart, .{
        .name = "roxum_stream_start",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.response_writer.hostedStreamWrite, .{
        .name = "roxum_stream_write",
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
    @export(&host.body_effect.hostedBodyLimitWhole, .{
        .name = "roxum_body_limit_whole",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.body_effect.hostedBodyLimitStreamed, .{
        .name = "roxum_body_limit_streamed",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.files_effect.hostedFilesOpenRoot, .{
        .name = "roxum_files_open_root",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.files_effect.hostedFilesOpen, .{
        .name = "roxum_files_open",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.files_effect.hostedFilesSend, .{
        .name = "roxum_files_send",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.files_effect.hostedFilesClose, .{
        .name = "roxum_files_close",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.compress_effect.hostedCompressGzip, .{
        .name = "roxum_compress_gzip",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.compress_effect.hostedCompressDecompress, .{
        .name = "roxum_compress_decompress",
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
    @export(&host.tcp_effect.hostedTcpOpenScope, .{
        .name = "roxum_tcp_open_scope",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpCloseScope, .{
        .name = "roxum_tcp_close_scope",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&host.tcp_effect.hostedTcpScopeActive, .{
        .name = "roxum_tcp_scope_active",
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

fn cMain(
    argc: c_int,
    argv: [*][*:0]u8,
) callconv(std.builtin.CallingConvention.c) c_int {
    if (argc < 1) return 2;
    const arguments: []const [*:0]const u8 = @ptrCast(argv[1..@intCast(argc)]);
    const options = host.launch.parse(arguments) orelse return 2;
    host.launch.apply(options);

    host.supervisor.run(workerMain, .{}) catch |err| {
        host.diagnostics.hostFailed(err);
        return 1;
    };
}

fn workerMain(port_override: ?u16) c_int {
    var environment = tracking_environment.Environment.init(
        std.heap.page_allocator,
    );
    defer environment.deinit();

    host.server.run(&environment, .{}, port_override) catch |err| {
        host.diagnostics.hostFailed(err);
        return 1;
    };
    return 0;
}
