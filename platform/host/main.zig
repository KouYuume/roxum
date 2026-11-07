const std = @import("std");
const arena = @import("allocator/arena.zig");
const builtin = @import("builtin");
const diagnostics = @import("diagnostics.zig");
const launch = @import("launch.zig");
const runtime = @import("runtime.zig");
const server = @import("server.zig");
const supervisor = @import("supervisor.zig");

const log_effect = @import("effect/log.zig");
const body_effect = @import("effect/body.zig");
const files_effect = @import("effect/files.zig");
const compress_effect = @import("effect/compress.zig");
const time_effect = @import("effect/time.zig");
const instant_effect = @import("effect/instant.zig");
const sleep_effect = @import("effect/sleep.zig");
const response_writer = @import("effect/response_writer.zig");
const random_effect = @import("effect/random.zig");
const file_effect = @import("effect/file.zig");
const secret_effect = @import("effect/secret.zig");
const rate_counter_effect = @import("effect/rate_counter.zig");
const concurrency_effect = @import("effect/concurrency.zig");
const tcp_effect = @import("effect/tcp.zig");

comptime {
    if (!builtin.is_test) {
        @export(&cMain, .{ .name = "main" });
    }

    @export(&runtime.rocAlloc, .{ .name = "roc_alloc" });
    @export(&runtime.rocDealloc, .{ .name = "roc_dealloc" });
    @export(&runtime.rocRealloc, .{ .name = "roc_realloc" });
    @export(&runtime.rocDebug, .{ .name = "roc_dbg" });
    @export(&runtime.rocExpectFailed, .{ .name = "roc_expect_failed" });
    @export(&runtime.rocCrashed, .{ .name = "roc_crashed" });

    @export(&log_effect.hostedLogWrite, .{
        .name = "roxum_log_write",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&time_effect.hostedTimeNowUnixMilliseconds, .{
        .name = "roxum_time_now_unix_milliseconds",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&instant_effect.hostedInstantNowNanoseconds, .{
        .name = "roxum_instant_now_nanoseconds",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&sleep_effect.hostedSleepMilliseconds, .{
        .name = "roxum_sleep_milliseconds",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&sleep_effect.hostedSleepUntil, .{
        .name = "roxum_sleep_until",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&response_writer.hostedStreamStart, .{
        .name = "roxum_stream_start",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&response_writer.hostedStreamWrite, .{
        .name = "roxum_stream_write",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&random_effect.hostedRandomU64, .{
        .name = "roxum_random_u64",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&body_effect.hostedBodyRead, .{
        .name = "roxum_body_read",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&body_effect.hostedBodyLimitWhole, .{
        .name = "roxum_body_limit_whole",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&body_effect.hostedBodyLimitStreamed, .{
        .name = "roxum_body_limit_streamed",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&files_effect.hostedFilesOpenRoot, .{
        .name = "roxum_files_open_root",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&files_effect.hostedFilesOpen, .{
        .name = "roxum_files_open",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&files_effect.hostedFilesSend, .{
        .name = "roxum_files_send",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&files_effect.hostedFilesClose, .{
        .name = "roxum_files_close",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&compress_effect.hostedCompressGzip, .{
        .name = "roxum_compress_gzip",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&compress_effect.hostedCompressDecompress, .{
        .name = "roxum_compress_decompress",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&file_effect.hostedFileRead, .{
        .name = "roxum_file_read",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&secret_effect.hostedSecretFromFile, .{
        .name = "roxum_secret_from_file",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&secret_effect.hostedSecretFromEnv, .{
        .name = "roxum_secret_from_env",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&secret_effect.hostedSecretDerive, .{
        .name = "roxum_secret_derive",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&rate_counter_effect.hostedRateCounterNew, .{
        .name = "roxum_rate_counter_new",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&rate_counter_effect.hostedRateCounterAdd, .{
        .name = "roxum_rate_counter_add",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&concurrency_effect.hostedConcurrencyNew, .{
        .name = "roxum_concurrency_new",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&concurrency_effect.hostedConcurrencyAcquire, .{
        .name = "roxum_concurrency_acquire",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpPool, .{
        .name = "roxum_tcp_pool",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpAcquire, .{
        .name = "roxum_tcp_acquire",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpAcquireOrigin, .{
        .name = "roxum_tcp_acquire_origin",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpConfigureOrigins, .{
        .name = "roxum_tcp_configure_origins",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpCheckCa, .{
        .name = "roxum_tcp_check_ca",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpRelease, .{
        .name = "roxum_tcp_release",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpIsNew, .{
        .name = "roxum_tcp_is_new",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpOpenScope, .{
        .name = "roxum_tcp_open_scope",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpCloseScope, .{
        .name = "roxum_tcp_close_scope",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpScopeActive, .{
        .name = "roxum_tcp_scope_active",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpDiscard, .{
        .name = "roxum_tcp_discard",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpWrite, .{
        .name = "roxum_tcp_write",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpWriteDerived, .{
        .name = "roxum_tcp_write_derived",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpRead, .{
        .name = "roxum_tcp_read",
        .visibility = std.builtin.SymbolVisibility.hidden,
    });
    @export(&tcp_effect.hostedTcpStartTls, .{
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
    const options = launch.parse(arguments) orelse return 2;
    launch.apply(options);

    supervisor.run(workerMain, .{}) catch |err| {
        diagnostics.hostFailed(err);
        return 1;
    };
}

fn workerMain(port_override: ?u16) c_int {
    var environment = arena.ArenaEnvironment.production();
    defer environment.deinit();

    server.run(&environment, .{}, port_override) catch |err| {
        diagnostics.hostFailed(err);
        return 1;
    };
    return 0;
}

test {
    _ = launch;
}
