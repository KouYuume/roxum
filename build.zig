const std = @import("std");
const nghttp2_build = @import("tools/nghttp2-build.zig");

pub fn build(b: *std.Build) void {
    const http2_module = b.createModule(.{
        .root_source_file = b.path("platform/host/http2.zig"),
        .target = b.graph.host,
        .optimize = std.builtin.OptimizeMode.ReleaseSafe,
    });
    nghttp2_build.attach(b, http2_module, b.graph.host, std.builtin.OptimizeMode.ReleaseSafe);
    const http2_tests = b.addTest(.{ .root_module = http2_module, .use_llvm = true });
    const http2_test_step = b.step("test-http2-engine", "Test the internal HTTP/2 engine and its allocation bounds");
    http2_test_step.dependOn(&b.addRunArtifact(http2_tests).step);

    const http2_ownership_module = b.createModule(.{
        .root_source_file = b.path("tests/http2-engine/ownership_test.zig"),
        .target = b.graph.host,
        .optimize = std.builtin.OptimizeMode.ReleaseSafe,
        .link_libc = true,
    });
    http2_ownership_module.addImport("http2_engine", http2_module);
    const http2_ownership_tests = b.addTest(.{ .root_module = http2_ownership_module, .use_llvm = true });
    http2_test_step.dependOn(&b.addRunArtifact(http2_ownership_tests).step);

    const contract_alloc = b.option(
        bool,
        "contract-alloc",
        "Link the tracking allocator that checks each request for leaks, canary damage, and invalid frees",
    ) orelse false;
    const roc_opt = b.option(
        []const u8,
        "opt",
        "Roc optimization mode: speed, dev, or interpreter",
    ) orelse "speed";

    if (!std.mem.eql(u8, roc_opt, "speed") and
        !std.mem.eql(u8, roc_opt, "dev") and
        !std.mem.eql(u8, roc_opt, "interpreter"))
    {
        @panic("-Dopt must be one of: speed, dev, interpreter");
    }

    const roc_target = b.option(
        []const u8,
        "roc-target",
        "Roc target of the host and examples: arm64mac, arm64musl, or x64musl (default: this machine)",
    ) orelse nativeRocTarget(b);
    if (zigTargetOf(roc_target) == null) {
        @panic("-Droc-target must be one of: arm64mac, arm64musl, x64musl");
    }
    const http2_target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = zigTargetOf(roc_target).? }) catch @panic("invalid target"));
    const http2_fixture_engine = b.createModule(.{ .root_source_file = b.path("platform/host/http2.zig"), .target = http2_target, .optimize = std.builtin.OptimizeMode.ReleaseSafe });
    nghttp2_build.attach(b, http2_fixture_engine, http2_target, std.builtin.OptimizeMode.ReleaseSafe);
    const http2_fixture_module = b.createModule(.{ .root_source_file = b.path("tests/http2-engine/server.zig"), .target = http2_target, .optimize = std.builtin.OptimizeMode.ReleaseSafe, .link_libc = true });
    http2_fixture_module.addImport("http2_engine", http2_fixture_engine);
    const http2_fixture = b.addExecutable(.{ .name = "http2-engine-server", .root_module = http2_fixture_module });
    const install_http2_fixture = b.addInstallArtifact(http2_fixture, .{});
    const http2_fixture_step = b.step("http2-engine-fixture", "Build the independent-client HTTP/2 fixture for roc-target");
    http2_fixture_step.dependOn(&install_http2_fixture.step);
    const http2_wire = b.addSystemCommand(&.{ "bash", "tests/http2-engine/run.sh" });
    http2_wire.addArtifactArg(http2_fixture);
    const http2_wire_step = b.step("test-http2-wire", "Verify finite HTTP/2 exchanges with the pinned independent client");
    http2_wire_step.dependOn(&http2_wire.step);

    const http2_roc = b.step("test-http2-roc", "Exercise real Roc HTTP/2 handlers in every backend and allocator mode");
    http2_roc.dependOn(addHttp2RocFixture(b, roc_target, http2_target));

    const host_archive = b.fmt("platform/targets/{s}/libhost.a", .{roc_target});
    // Diagnostic only: measures what the safety checks cost. Release bundles
    // always use ReleaseSafe.
    const host_optimize = b.option(
        std.builtin.OptimizeMode,
        "host-optimize",
        "Optimization mode of the development host (default ReleaseSafe; for performance diagnostics)",
    ) orelse std.builtin.OptimizeMode.ReleaseSafe;
    const development_host = HostBuild{ .platform_dir = "platform", .strip = false, .optimize = host_optimize };

    const host = b.step("host", "Build platform/targets/<roc-target>/ (libhost.a, and crt1.o / libc.a for musl)");
    const build_selected_host = addHostBuild(b, roc_target, contract_alloc, development_host);
    host.dependOn(build_selected_host);
    const hosts = b.step("hosts", "Build the host for every Roc target");
    for (roc_targets) |each_target| {
        if (std.mem.eql(u8, each_target, roc_target)) {
            hosts.dependOn(build_selected_host);
        } else {
            hosts.dependOn(addHostBuild(b, each_target, contract_alloc, development_host));
        }
    }

    const release = b.step("release", "Bundle the platform with stripped hosts for every target into zig-out/release/");
    // Where the release's bundles are served from, which the integrations'
    // bundles name the platform's under.
    const release_url = b.option([]const u8, "release-url", "The URL the release's bundles are served from, such as https://github.com/<owner>/<repo>/releases/download/v0.1.0") orelse "";
    const bundle_release = b.addSystemCommand(&.{ "bash", "tools/release-bundle.sh", release_url });
    for (roc_targets) |each_target| {
        bundle_release.step.dependOn(addHostBuild(b, each_target, false, HostBuild.release));
    }
    release.dependOn(&bundle_release.step);

    const glue = b.step("glue", "Regenerate the committed Roc/Zig ABI glue");
    const regenerate_glue = b.addSystemCommand(&.{ "bash", "tools/regen-glue.sh" });
    glue.dependOn(&regenerate_glue.step);

    const examples = b.step("examples", "Build the example applications");
    const make_example_output_dir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/bin" });
    const build_examples = b.addSystemCommand(&.{
        "roc",
        "build",
        b.fmt("--opt={s}", .{roc_opt}),
        b.fmt("--target={s}", .{roc_target}),
        "--output=zig-out/bin/roxum-hello",
        "examples/hello/app.roc",
    });
    build_examples.addFileInput(
        b.path(host_archive),
    );
    build_examples.step.dependOn(build_selected_host);
    build_examples.step.dependOn(&make_example_output_dir.step);
    examples.dependOn(&build_examples.step);
    const build_echo_fixture = b.addSystemCommand(&.{
        "roc",
        "build",
        b.fmt("--opt={s}", .{roc_opt}),
        b.fmt("--target={s}", .{roc_target}),
        "--output=zig-out/bin/roxum-echo",
        "tests/e2e/app.roc",
    });
    build_echo_fixture.addFileInput(
        b.path(host_archive),
    );
    build_echo_fixture.step.dependOn(build_selected_host);
    build_echo_fixture.step.dependOn(&make_example_output_dir.step);
    const build_ddd_example = b.addSystemCommand(&.{
        "roc",
        "build",
        b.fmt("--opt={s}", .{roc_opt}),
        b.fmt("--target={s}", .{roc_target}),
        "--output=zig-out/bin/roxum-ddd",
        "examples/ddd/app.roc",
    });
    build_ddd_example.addFileInput(b.path(host_archive));
    build_ddd_example.step.dependOn(build_selected_host);
    build_ddd_example.step.dependOn(&make_example_output_dir.step);
    examples.dependOn(&build_ddd_example.step);
    const build_middleware_example = b.addSystemCommand(&.{
        "roc",
        "build",
        b.fmt("--opt={s}", .{roc_opt}),
        b.fmt("--target={s}", .{roc_target}),
        "--output=zig-out/bin/roxum-middleware",
        "examples/middleware/app.roc",
    });
    build_middleware_example.addFileInput(b.path(host_archive));
    build_middleware_example.step.dependOn(build_selected_host);
    build_middleware_example.step.dependOn(&make_example_output_dir.step);
    examples.dependOn(&build_middleware_example.step);

    const test_step = b.step("test", "Run Zig unit tests, Roc module tests and negative fixtures, and the parser fuzz tests");
    test_step.dependOn(http2_test_step);
    const run_platform_tests = b.addSystemCommand(&.{
        "bash",
        "tests/roc/run-platform-tests.sh",
    });
    const run_router_tests = b.addSystemCommand(&.{
        "bash",
        "tests/roc/run-router-tests.sh",
    });
    const run_contextual_literal_tests = b.addSystemCommand(&.{
        "bash",
        "tests/roc/run-contextual-literal-tests.sh",
    });
    const run_extractor_response_tests = b.addSystemCommand(&.{
        "bash",
        "tests/roc/run-extractor-response-tests.sh",
    });
    const run_effect_tests = b.addSystemCommand(&.{
        "bash",
        "tests/roc/run-effect-tests.sh",
    });
    test_step.dependOn(&run_platform_tests.step);
    test_step.dependOn(&run_router_tests.step);
    test_step.dependOn(&run_contextual_literal_tests.step);
    test_step.dependOn(&run_extractor_response_tests.step);
    const run_http_client_tests = b.addSystemCommand(&.{
        "bash",
        "tests/roc/run-http-client-tests.sh",
    });
    test_step.dependOn(&run_effect_tests.step);
    test_step.dependOn(&run_http_client_tests.step);
    const run_protobuf_tests = b.addSystemCommand(&.{ "bash", "tests/protobuf/unit.sh" });
    test_step.dependOn(&run_protobuf_tests.step);
    addZigTests(b, test_step, &unit_tests, .{});
    addZigTests(b, test_step, &http1_tests, .{});

    const fuzz_parser_module = b.createModule(.{
        .root_source_file = b.path("fuzz/http1_parser.zig"),
        .target = b.graph.host,
        .optimize = std.builtin.OptimizeMode.Debug,
        .error_tracing = false,
    });
    const fuzz_http1_parser_module = b.createModule(.{
        .root_source_file = b.path("platform/host/http1/parser.zig"),
        .target = b.graph.host,
        .optimize = std.builtin.OptimizeMode.Debug,
        .error_tracing = false,
    });
    fuzz_parser_module.addImport(
        "http1_parser",
        fuzz_http1_parser_module,
    );

    const fuzz_parser_tests = b.addTest(.{
        .root_module = fuzz_parser_module,
        // Coverage-guided fuzzing needs LLVM's instrumentation; Zig's own x86_64
        // backend, the default for Debug there, leaves the fuzzer no coverage.
        .use_llvm = true,
    });
    const run_fuzz_parser_tests = b.addRunArtifact(
        fuzz_parser_tests,
    );
    const fuzz_step = b.step(
        "fuzz",
        "Fuzz the HTTP/1 parser and its incremental contract",
    );
    fuzz_step.dependOn(&run_fuzz_parser_tests.step);
    test_step.dependOn(&run_fuzz_parser_tests.step);
    // One fuzz test per `--fuzz` run: Zig 0.16's fuzzers, started together
    // on an empty cache, fail to create their files there on macOS.
    const fuzz_parser_step = b.step("fuzz-parser", "Fuzz the HTTP/1 parser and its incremental contract");
    fuzz_parser_step.dependOn(&run_fuzz_parser_tests.step);

    const fuzz_router_step = b.step(
        "fuzz-router",
        "Run the typed Roc Router fuzz campaign",
    );
    const run_fuzz_router = b.addSystemCommand(&.{
        "bash",
        "tools/fuzz-roc-router.sh",
    });
    fuzz_router_step.dependOn(&run_fuzz_router.step);

    const fuzz_chunked_module = b.createModule(.{
        .root_source_file = b.path("fuzz/http1_chunked.zig"),
        .target = b.graph.host,
        .optimize = std.builtin.OptimizeMode.Debug,
        .error_tracing = false,
    });
    const fuzz_http1_chunked_module = b.createModule(.{
        .root_source_file = b.path("platform/host/http1/chunked.zig"),
        .target = b.graph.host,
        .optimize = std.builtin.OptimizeMode.Debug,
        .error_tracing = false,
    });
    fuzz_chunked_module.addImport(
        "http1_chunked",
        fuzz_http1_chunked_module,
    );

    const fuzz_chunked_tests = b.addTest(.{
        .root_module = fuzz_chunked_module,
        // Coverage-guided fuzzing needs LLVM's instrumentation; Zig's own x86_64
        // backend, the default for Debug there, leaves the fuzzer no coverage.
        .use_llvm = true,
    });
    const run_fuzz_chunked_tests = b.addRunArtifact(
        fuzz_chunked_tests,
    );
    fuzz_step.dependOn(&run_fuzz_chunked_tests.step);
    test_step.dependOn(&run_fuzz_chunked_tests.step);
    const fuzz_chunked_step = b.step("fuzz-chunked", "Fuzz the chunked transfer decoder");
    fuzz_chunked_step.dependOn(&run_fuzz_chunked_tests.step);

    const test_http1_release = b.step(
        "test-http1-release",
        "Test HTTP/1 modules in ReleaseSafe and ReleaseFast",
    );
    addZigTests(b, test_http1_release, &http1_tests, .{ .optimize = "ReleaseSafe" });
    addZigTests(b, test_http1_release, &http1_tests, .{ .optimize = "ReleaseFast" });

    const test_tsan = b.step(
        "test-tsan",
        "Run the unit tests of what the process's threads share under the thread sanitizer",
    );
    addZigTests(b, test_tsan, &tsan_tests, .{ .sanitize_thread = true });

    const bench = b.step("bench", "Benchmark the HTTP/1 parser");
    const run_http1_parser_bench = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "run",
        "-O",
        "ReleaseFast",
        "-lc",
        "--dep",
        "http1_parser",
        "-Mroot=bench/http1_parser.zig",
        "-Mhttp1_parser=platform/host/http1/parser.zig",
    });
    bench.dependOn(&run_http1_parser_bench.step);

    const bench_encoder = b.step(
        "bench-encoder",
        "Benchmark the HTTP/1 response encoder",
    );
    const run_http1_encoder_bench = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "run",
        "-O",
        "ReleaseFast",
        "-lc",
        "--dep",
        "http1_encoder",
        "-Mroot=bench/http1_encoder.zig",
        "-Mhttp1_encoder=platform/host/http1/encoder.zig",
    });
    bench_encoder.dependOn(&run_http1_encoder_bench.step);

    const bench_unread_body = b.step(
        "bench-unread-body",
        "Benchmark unread request-body recovery policies",
    );
    const run_unread_body_bench = b.addSystemCommand(&.{
        "bash",
        "bench/m5_unread_body/build-and-run.sh",
    });
    bench_unread_body.dependOn(&run_unread_body_bench.step);

    const bench_m6 = b.step("bench-m6", "Build the M6 worker-pool benchmark host");
    const build_m6_bench = b.addSystemCommand(&.{
        "bash",
        "bench/m6/build.sh",
        "zig-out/bin/roxum-m6-bench",
    });
    bench_m6.dependOn(&build_m6_bench.step);

    const test_e2e = b.step("test-e2e", "Run end-to-end tests");
    const run_e2e = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "test",
        "tests/e2e/echo_test.zig",
        "-lc",
    });

    if (b.graph.environ_map.get("ROXUM_PREBUILT_EXE") == null) {
        run_e2e.step.dependOn(&build_echo_fixture.step);
        run_e2e.setEnvironmentVariable(
            "ROXUM_PREBUILT_EXE",
            "zig-out/bin/roxum-echo",
        );
    }
    run_e2e.setEnvironmentVariable(
        "ROXUM_CONTRACT_ALLOC",
        if (contract_alloc) "1" else "0",
    );
    run_e2e.setEnvironmentVariable("ROXUM_OPT", roc_opt);
    test_e2e.dependOn(&run_e2e.step);
    const run_supervisor_e2e = b.addSystemCommand(&.{
        "python3",
        "tests/e2e/supervisor_test.py",
    });
    run_supervisor_e2e.addArg(
        b.graph.environ_map.get("ROXUM_PREBUILT_EXE") orelse
            "zig-out/bin/roxum-echo",
    );
    run_supervisor_e2e.step.dependOn(&run_e2e.step);
    test_e2e.dependOn(&run_supervisor_e2e.step);
    const run_many_connections_e2e = b.addSystemCommand(&.{
        "python3",
        "tests/e2e/many_connections_test.py",
    });
    run_many_connections_e2e.addArg(
        b.graph.environ_map.get("ROXUM_PREBUILT_EXE") orelse
            "zig-out/bin/roxum-echo",
    );
    run_many_connections_e2e.setEnvironmentVariable("ROXUM_OPT", roc_opt);
    run_many_connections_e2e.step.dependOn(&run_supervisor_e2e.step);
    test_e2e.dependOn(&run_many_connections_e2e.step);
    const run_slow_reader_e2e = b.addSystemCommand(&.{
        "python3",
        "tests/e2e/slow_reader_test.py",
    });
    run_slow_reader_e2e.addArg(
        b.graph.environ_map.get("ROXUM_PREBUILT_EXE") orelse
            "zig-out/bin/roxum-echo",
    );
    run_slow_reader_e2e.step.dependOn(&run_many_connections_e2e.step);
    test_e2e.dependOn(&run_slow_reader_e2e.step);
    const run_lingering_close_e2e = b.addSystemCommand(&.{
        "python3",
        "tests/e2e/lingering_close_test.py",
    });
    run_lingering_close_e2e.addArg(
        b.graph.environ_map.get("ROXUM_PREBUILT_EXE") orelse
            "zig-out/bin/roxum-echo",
    );
    run_lingering_close_e2e.step.dependOn(&run_slow_reader_e2e.step);
    test_e2e.dependOn(&run_lingering_close_e2e.step);
    const run_slow_body_e2e = b.addSystemCommand(&.{
        "python3",
        "tests/e2e/slow_body_test.py",
    });
    run_slow_body_e2e.addArg(
        b.graph.environ_map.get("ROXUM_PREBUILT_EXE") orelse
            "zig-out/bin/roxum-echo",
    );
    run_slow_body_e2e.step.dependOn(&run_lingering_close_e2e.step);
    test_e2e.dependOn(&run_slow_body_e2e.step);
    const run_large_body_e2e = b.addSystemCommand(&.{
        "python3",
        "tests/e2e/large_body_test.py",
    });
    run_large_body_e2e.addArg(
        b.graph.environ_map.get("ROXUM_PREBUILT_EXE") orelse
            "zig-out/bin/roxum-echo",
    );
    run_large_body_e2e.step.dependOn(&run_slow_body_e2e.step);
    test_e2e.dependOn(&run_large_body_e2e.step);
    // The readiness test runs a Zig fixture, not the Roc app, so it does not
    // vary with -Dopt or -Dcontract-alloc; tools/check.py runs it once.
    const e2e_readiness = b.option(bool, "e2e-readiness", "Run the supervisor readiness test with test-e2e (default true)") orelse true;
    if (e2e_readiness) {
        const run_readiness_tests = b.addSystemCommand(&.{ "python3", "tests/e2e/supervisor_readiness_test.py", b.graph.zig_exe });
        test_e2e.dependOn(&run_readiness_tests.step);
    }

    const contract = b.step("test-contract", "Run the M-1 execution-model contract tests");
    const run_contract = b.addSystemCommand(&.{ "bash", "tests/contract/run.sh" });
    contract.dependOn(&run_contract.step);

    const abi_sentinel = b.step(
        "test-abi",
        "Run semantic Roc compiler/glue ABI checks in every backend",
    );
    const run_abi_sentinel = b.addSystemCommand(&.{
        "bash",
        "tests/contract/abi-sentinel/run.sh",
    });
    run_abi_sentinel.setEnvironmentVariable("OPT", "all");
    abi_sentinel.dependOn(&run_abi_sentinel.step);

    const test_platform_package = b.step(
        "test-m9p1",
        "Run the platform-dependent package spike in every backend",
    );
    const run_platform_package = b.addSystemCommand(&.{
        "bash",
        "tests/platform-package/run.sh",
    });
    test_platform_package.dependOn(&run_platform_package.step);

    const test_platform_identity = b.step(
        "test-m9p2",
        "Verify exact platform identity across the dependency graph",
    );
    const run_platform_identity = b.addSystemCommand(&.{
        "bash",
        "tests/platform-package/identity/run.sh",
    });
    test_platform_identity.dependOn(&run_platform_identity.step);

    const test_integration_manifest = b.step(
        "test-m9p3",
        "Verify integration release compatibility metadata",
    );
    const run_integration_manifest = b.addSystemCommand(&.{
        "bash",
        "tests/platform-package/manifest/run.sh",
    });
    test_integration_manifest.dependOn(&run_integration_manifest.step);

    const test_sse_integration = b.step(
        "test-m9p4",
        "Run the roxum-sse integration in every backend",
    );
    const run_sse_integration = b.addSystemCommand(&.{
        "bash",
        "integrations/roxum-sse/example/run.sh",
    });
    test_sse_integration.dependOn(&run_sse_integration.step);

    const test_middleware_core = b.step(
        "test-m9-1",
        "Run the core Middleware contract in every backend and allocator mode",
    );
    const run_middleware_core = b.addSystemCommand(&.{
        "bash",
        "tests/middleware/run.sh",
    });
    test_middleware_core.dependOn(&run_middleware_core.step);

    const test_router_middleware = b.step(
        "test-m9-2",
        "Run Router Middleware integration in every backend and allocator mode",
    );
    const run_router_middleware = b.addSystemCommand(&.{
        "bash",
        "tests/router-middleware/run.sh",
    });
    test_router_middleware.dependOn(&run_router_middleware.step);

    const test_set_header_integration = b.step(
        "test-m9-3",
        "Run the roxum-set-header integration in every backend and allocator mode",
    );
    const run_set_header_integration = b.addSystemCommand(&.{
        "bash",
        "integrations/roxum-set-header/example/run.sh",
    });
    test_set_header_integration.dependOn(&run_set_header_integration.step);

    const test_cookie_integration = b.step(
        "test-cookie",
        "Run the roxum-cookie integration in every backend and allocator mode",
    );
    const run_cookie_integration = b.addSystemCommand(&.{
        "bash",
        "integrations/roxum-cookie/example/run.sh",
    });
    test_cookie_integration.dependOn(&run_cookie_integration.step);

    const test_concurrency_limit_integration = b.step(
        "test-concurrency-limit",
        "Run the roxum-concurrency-limit integration in every backend and allocator mode",
    );
    const run_concurrency_limit_integration = b.addSystemCommand(&.{
        "bash",
        "integrations/roxum-concurrency-limit/example/run.sh",
    });
    test_concurrency_limit_integration.dependOn(&run_concurrency_limit_integration.step);

    const test_rate_limit_integration = b.step(
        "test-rate-limit",
        "Run the roxum-rate-limit integration in every backend and allocator mode",
    );
    const run_rate_limit_integration = b.addSystemCommand(&.{
        "bash",
        "integrations/roxum-rate-limit/example/run.sh",
    });
    test_rate_limit_integration.dependOn(&run_rate_limit_integration.step);

    const test_trace_integration = b.step(
        "test-m9-3b",
        "Run the roxum-trace integration in every backend and allocator mode",
    );
    const run_trace_integration = b.addSystemCommand(&.{
        "bash",
        "integrations/roxum-trace/example/run.sh",
    });
    test_trace_integration.dependOn(&run_trace_integration.step);

    const test_normalize_path_integration = b.step(
        "test-m9-4a",
        "Run the roxum-normalize-path integration in every backend and allocator mode",
    );
    const run_normalize_path_integration = b.addSystemCommand(&.{
        "bash",
        "integrations/roxum-normalize-path/example/run.sh",
    });
    test_normalize_path_integration.dependOn(&run_normalize_path_integration.step);

    const test_cors_integration = b.step(
        "test-m9-4b",
        "Run the roxum-cors integration in every backend and allocator mode",
    );
    const run_cors_integration = b.addSystemCommand(&.{
        "bash",
        "integrations/roxum-cors/example/run.sh",
    });
    test_cors_integration.dependOn(&run_cors_integration.step);

    const test_timeouts = b.step(
        "test-m11a",
        "Run the configurable connection timeout checks in every backend",
    );
    const run_timeouts = b.addSystemCommand(&.{
        "bash",
        "tests/timeouts/run.sh",
    });
    test_timeouts.dependOn(&run_timeouts.step);

    const test_files = b.step(
        "test-files",
        "Check files served from a root in every backend",
    );
    const run_files = b.addSystemCommand(&.{
        "bash",
        "tests/files/run.sh",
    });
    test_files.dependOn(&run_files.step);

    const test_compression = b.step(
        "test-compression",
        "Check response compression in every backend",
    );
    const run_compression = b.addSystemCommand(&.{
        "bash",
        "tests/compression/run.sh",
    });
    test_compression.dependOn(&run_compression.step);

    const test_stream_limit = b.step(
        "test-stream-limit",
        "Check Server.Limits.maximum_streams in every backend",
    );
    const run_stream_limit = b.addSystemCommand(&.{
        "bash",
        "tests/stream-limit/run.sh",
    });
    test_stream_limit.dependOn(&run_stream_limit.step);

    const test_file_secret = b.step(
        "test-file-secret",
        "Check File.read_bytes! and Secret in every backend and allocator mode",
    );
    const run_file_secret = b.addSystemCommand(&.{
        "bash",
        "tests/file-secret/run.sh",
    });
    test_file_secret.dependOn(&run_file_secret.step);

    const test_config = b.step(
        "test-config",
        "Check Config (base and config/local.toml) in every backend and allocator mode",
    );
    const run_config = b.addSystemCommand(&.{
        "bash",
        "tests/config/run.sh",
    });
    test_config.dependOn(&run_config.step);

    const test_listen_options = b.step(
        "test-listen-options",
        "Check the worker count and the drain timeout in Server.ListenOptions in every backend",
    );
    const run_listen_options = b.addSystemCommand(&.{
        "bash",
        "tests/listen-options/run.sh",
    });
    test_listen_options.dependOn(&run_listen_options.step);

    const test_graceful_shutdown = b.step(
        "test-graceful-shutdown",
        "Stop the server during requests, streams, and a handler that never returns, in every backend and allocator mode",
    );
    const run_graceful_shutdown = b.addSystemCommand(&.{
        "bash",
        "tests/graceful-shutdown/run.sh",
    });
    test_graceful_shutdown.dependOn(&run_graceful_shutdown.step);

    const test_admission = b.step(
        "test-admission",
        "Overload one worker past each admission limit and check the 503s, in every backend and allocator mode",
    );
    const run_admission = b.addSystemCommand(&.{
        "bash",
        "tests/admission/run.sh",
    });
    test_admission.dependOn(&run_admission.step);

    const test_observability = b.step(
        "test-observability",
        "Check the access log lines of the app's and the host's answers, in every backend and allocator mode",
    );
    const run_observability = b.addSystemCommand(&.{
        "bash",
        "tests/observability/run.sh",
    });
    test_observability.dependOn(&run_observability.step);

    const test_tcp = b.step(
        "test-tcp",
        "Check outbound Tcp connections, pools, TLS, and waiting on a fiber in every backend and allocator mode",
    );
    const run_tcp = b.addSystemCommand(&.{
        "bash",
        "tests/tcp/run.sh",
    });
    test_tcp.dependOn(&run_tcp.step);

    const test_http_client = b.step(
        "test-http-client",
        "Run roxum-http-client against local HTTP and HTTPS servers in every backend and allocator mode",
    );
    const run_http_client = b.addSystemCommand(&.{
        "bash",
        "tests/http-client/run.sh",
    });
    test_http_client.dependOn(&run_http_client.step);

    const test_postgres = b.step(
        "test-postgres",
        "Run the roxum-postgres integration against a throwaway PostgreSQL in every backend and allocator mode",
    );
    const run_postgres = b.addSystemCommand(&.{
        "bash",
        "integrations/roxum-postgres/example/run.sh",
    });
    test_postgres.dependOn(&run_postgres.step);

    const test_http2_listener = b.step("test-http2-listener", "Exercise production HTTP/2 TCP and Unix listeners in all backend/allocator modes");
    const run_http2_listener = b.addSystemCommand(&.{ "python3", "tools/check.py", "--only", "test-http2-listener" });
    test_http2_listener.dependOn(&run_http2_listener.step);

    const test_grpc_probe = b.step("test-grpc-probe", "Verify fixed-byte gRPC interoperability on TCP and Unix listeners");
    const run_grpc_probe = b.addSystemCommand(&.{ "python3", "tools/check.py", "--only", "test-grpc-probe" });
    test_grpc_probe.dependOn(&run_grpc_probe.step);

    const test_protobuf_layouts = b.step("test-protobuf-layouts", "Check candidate recursive Protobuf layouts in all backend/allocator modes");
    const run_protobuf_layouts = b.addSystemCommand(&.{ "python3", "tools/check.py", "--only", "test-protobuf-layouts" });
    test_protobuf_layouts.dependOn(&run_protobuf_layouts.step);
    const test_protobuf_codegen = b.step("test-protobuf-codegen", "Check generated Protobuf scalar codecs in all backend/allocator modes");
    const run_protobuf_codegen = b.addSystemCommand(&.{ "python3", "tools/check.py", "--only", "test-protobuf-codegen" });
    test_protobuf_codegen.dependOn(&run_protobuf_codegen.step);
    const test_protobuf = b.step("test-protobuf", "Check pure Protobuf wire operations in all backend/allocator modes");
    const run_protobuf = b.addSystemCommand(&.{ "python3", "tools/check.py", "--only", "test-protobuf" });
    test_protobuf.dependOn(&run_protobuf.step);
    const fuzz_protobuf = b.step("fuzz-protobuf", "Fuzz pure Protobuf wire parsing with the pinned Roc fuzz runner");
    const run_protobuf_fuzz = b.addSystemCommand(&.{ "bash", "tools/fuzz-roc-protobuf.sh" });
    fuzz_protobuf.dependOn(&run_protobuf_fuzz.step);

    const test_layered_app = b.step(
        "test-layered-app",
        "Build the layered sample application and check its HTTP responses in every backend",
    );
    const run_layered_app = b.addSystemCommand(&.{
        "python3",
        "tools/check.py",
        "--only",
        "test-layered-app",
    });
    test_layered_app.dependOn(&run_layered_app.step);

    const test_crud_service = b.step(
        "test-crud-service",
        "Run the layered sample with PostgreSQL and the tax service: CRUD, metrics, a restart, and SIGTERM under load, in every backend",
    );
    const run_crud_service = b.addSystemCommand(&.{
        "python3",
        "tools/check.py",
        "--only",
        "test-crud-service",
    });
    test_crud_service.dependOn(&run_crud_service.step);

    const test_proxy_headers_integration = b.step(
        "test-m11b",
        "Run the roxum-proxy-headers integration in every backend and allocator mode",
    );
    const run_proxy_headers_integration = b.addSystemCommand(&.{
        "bash",
        "integrations/roxum-proxy-headers/example/run.sh",
    });
    test_proxy_headers_integration.dependOn(&run_proxy_headers_integration.step);

    const test_debug_mode = b.step(
        "test-m9b-4",
        "Check request-labeled dbg / crash logs and --debug in every backend and allocator mode",
    );
    const run_debug_mode = b.addSystemCommand(&.{
        "bash",
        "tests/debug/run.sh",
    });
    test_debug_mode.dependOn(&run_debug_mode.step);

    const test_static_pages = b.step(
        "test-m9b-2",
        "Check that top-level page values are computed at build time in every backend and allocator mode",
    );
    const run_static_pages = b.addSystemCommand(&.{
        "bash",
        "tests/static/run.sh",
    });
    test_static_pages.dependOn(&run_static_pages.step);

    const test_ddd_example = b.step(
        "test-m9b-5",
        "Run the DDD example and check that a domain effect is a type error",
    );
    const run_ddd_example = b.addSystemCommand(&.{
        "bash",
        "tests/ddd/run.sh",
    });
    test_ddd_example.dependOn(&run_ddd_example.step);

    const test_release_bundle = b.step(
        "test-m13a",
        "Build the release bundle and run an app that fetches it by URL in every backend",
    );
    const run_release_bundle = b.addSystemCommand(&.{
        "bash",
        "tests/release/run.sh",
    });
    test_release_bundle.dependOn(&run_release_bundle.step);

    const test_guides = b.step(
        "test-m13b",
        "Build the guide examples in every backend, check what the guides describe, and generate the API reference",
    );
    const run_guides = b.addSystemCommand(&.{
        "bash",
        "tests/guide/run.sh",
    });
    test_guides.dependOn(&run_guides.step);

    // Requires caddy on PATH (or CADDY_BIN); CI installs a pinned Caddy.
    const test_reverse_proxy = b.step(
        "test-m11c",
        "Run roxum behind Caddy and check forwarded client information",
    );
    const run_reverse_proxy = b.addSystemCommand(&.{
        "bash",
        "tests/reverse-proxy/run.sh",
    });
    test_reverse_proxy.dependOn(&run_reverse_proxy.step);
}

/// A `zig test` root. `imports` are the named modules the root imports;
/// `modules` defines them, each with the named modules it imports itself.
/// A root with neither is a source file run on its own.
const ZigTest = struct {
    root: []const u8,
    imports: []const []const u8 = &.{},
    modules: []const Module = &.{},
    link_libc: bool = false,
    link_http2: bool = false,
    /// Runs only when the build machine runs this OS.
    os: ?std.Target.Os.Tag = null,
};

const Module = struct {
    name: []const u8,
    source: []const u8,
    imports: []const []const u8 = &.{},
};

const host_test_module = Module{ .name = "host", .source = "platform/host/host.zig" };
const bridge_test_module = Module{ .name = "bridge", .source = "platform/host/bridge.zig" };
const host_allocator_test_module = Module{ .name = "host_allocator", .source = "platform/host/allocator/host_allocator.zig" };
const tracking_allocator_test_module = Module{ .name = "tracking_allocator", .source = "tests/support/allocator/tracking_allocator.zig" };

/// Zig runs the tests of an imported file only when the root exposes that
/// file (for example `pub const x = @import("x.zig")`, as `host.zig` does); a
/// file the root uses internally is not tested. So every file with tests is
/// listed here as a root, even if another root also runs some of its tests.
const unit_tests = [_]ZigTest{
    .{ .root = "tests/zig/root.zig" },
    .{ .root = "platform/host/allocator/host_allocator.zig" },
    .{ .root = "tests/zig/host_allocator_test.zig", .imports = &.{"host_allocator"}, .modules = &.{host_allocator_test_module} },
    .{ .root = "platform/host/allocator/arena.zig" },
    .{ .root = "platform/host/allocator/meta.zig" },
    .{ .root = "platform/host/allocator/prefix.zig" },
    .{ .root = "platform/host/allocator/request_heap.zig" },
    .{ .root = "platform/host/runtime.zig", .link_libc = true },
    .{ .root = "platform/host/main.zig", .link_libc = true },
    .{ .root = "platform/host/host.zig", .link_libc = true },
    .{ .root = "platform/host/launch.zig", .link_libc = true },
    .{ .root = "platform/host/log_text.zig", .link_libc = true },
    .{ .root = "platform/host/request_debug.zig", .link_libc = true },
    .{ .root = "platform/host/request_id.zig", .link_libc = true },
    .{ .root = "platform/host/access_log.zig", .link_libc = true },
    .{ .root = "platform/host/metrics.zig", .link_libc = true },
    .{ .root = "platform/host/boxy.zig", .link_libc = true },
    .{ .root = "platform/host/stdio.zig", .link_libc = true },
    .{ .root = "platform/host/net/tcp.zig", .link_libc = true },
    .{ .root = "platform/host/net/deadline.zig", .link_libc = true },
    .{ .root = "platform/host/net/poller.zig", .link_libc = true },
    .{ .root = "platform/host/net/kqueue.zig", .link_libc = true, .os = std.Target.Os.Tag.macos },
    .{ .root = "platform/host/net/epoll.zig", .link_libc = true, .os = std.Target.Os.Tag.linux },
    .{ .root = "platform/host/net/listener_transfer.zig", .link_libc = true },
    .{ .root = "platform/host/bridge.zig", .link_libc = true },
    .{ .root = "platform/host/sync.zig", .link_libc = true },
    .{ .root = "platform/host/event_loop.zig", .link_libc = true, .link_http2 = true },
    .{ .root = "platform/host/http1/date.zig" },
    .{ .root = "platform/host/server.zig", .link_libc = true, .link_http2 = true },
    .{ .root = "platform/host/connection.zig", .link_libc = true },
    .{ .root = "platform/host/supervisor.zig", .link_libc = true },
    .{ .root = "tests/zig/request_reader_timeout_test.zig", .imports = &.{"host"}, .modules = &.{host_test_module}, .link_libc = true },
    .{ .root = "platform/host/http1/syntax.zig" },
    .{ .root = "platform/host/http1/authority.zig" },
    .{
        .root = "tests/zig/http1_differential_test.zig",
        .imports = &.{"http1_parser"},
        .modules = &.{.{ .name = "http1_parser", .source = "platform/host/http1/parser.zig" }},
    },
    .{ .root = "tests/zig/request_bridge_test.zig", .imports = &.{"bridge"}, .modules = &.{bridge_test_module} },
    .{
        .root = "tests/zig/response_bridge_test.zig",
        .imports = &.{ "bridge", "request_heap" },
        .modules = &.{ .{ .name = "request_heap", .source = "platform/host/allocator/request_heap.zig" }, bridge_test_module },
    },
    .{
        .root = "tests/zig/tracking_allocator_test.zig",
        .imports = &.{ "host_allocator", "tracking_allocator" },
        .modules = &.{ host_allocator_test_module, tracking_allocator_test_module },
        // The tracker's lock is a pthread mutex.
        .link_libc = true,
    },
    .{ .root = "tests/support/allocator/tracking_allocator.zig", .link_libc = true },
    .{
        .root = "tests/support/allocator/tracking_environment.zig",
        .imports = &.{ "host", "tracking_allocator" },
        .modules = &.{ host_test_module, tracking_allocator_test_module },
        .link_libc = true,
    },
    .{
        .root = "tests/zig/ffi_contract_test.zig",
        .link_libc = true,
        .imports = &.{ "bridge", "contract_environment" },
        .modules = &.{
            bridge_test_module,
            .{
                .name = "contract_environment",
                .source = "tests/support/ffi/contract_environment.zig",
                .imports = &.{ "bridge", "tracking_allocator" },
            },
            tracking_allocator_test_module,
        },
    },
};

/// What the process's threads share: fibers that move between
/// threads, the waits, the job queues, the connections' locks, the Tcp
/// pools, and the tracking allocator. `test-tsan` runs them under the
/// thread sanitizer.
const tsan_tests = [_]ZigTest{
    .{ .root = "platform/host/fiber.zig", .link_libc = true },
    .{ .root = "platform/host/scheduler.zig", .link_libc = true },
    .{ .root = "platform/host/work_queue.zig", .link_libc = true, .link_http2 = true },
    .{ .root = "platform/host/event_loop.zig", .link_libc = true, .link_http2 = true },
    .{ .root = "platform/host/host.zig", .link_libc = true },
    .{
        .root = "tests/support/allocator/tracking_environment.zig",
        .imports = &.{ "host", "tracking_allocator" },
        .modules = &.{ host_test_module, tracking_allocator_test_module },
        .link_libc = true,
    },
};

/// HTTP/1 test roots run in Debug by `test` and again in ReleaseSafe and
/// ReleaseFast by `test-http1-release`.
const http1_tests = [_]ZigTest{
    .{ .root = "tests/zig/http1_parser_test.zig", .imports = &.{"http1_parser"}, .modules = &.{.{ .name = "http1_parser", .source = "platform/host/http1/parser.zig" }} },
    .{ .root = "tests/zig/http1_framing_test.zig", .imports = &.{"http1_parser"}, .modules = &.{.{ .name = "http1_parser", .source = "platform/host/http1/parser.zig" }} },
    .{ .root = "tests/zig/http1_chunked_test.zig", .imports = &.{"http1_chunked"}, .modules = &.{.{ .name = "http1_chunked", .source = "platform/host/http1/chunked.zig" }} },
    .{ .root = "tests/zig/http1_encoder_test.zig", .imports = &.{"http1_encoder"}, .modules = &.{.{ .name = "http1_encoder", .source = "platform/host/http1/encoder.zig" }} },
    .{ .root = "tests/zig/http1_persistence_test.zig", .imports = &.{"http1_persistence"}, .modules = &.{.{ .name = "http1_persistence", .source = "platform/host/http1/persistence.zig" }} },
    .{ .root = "tests/zig/http1_response_framing_test.zig", .imports = &.{"http1_response_framing"}, .modules = &.{.{ .name = "http1_response_framing", .source = "platform/host/http1/response_framing.zig" }} },
    .{ .root = "platform/host/http1/error_response.zig" },
    .{ .root = "platform/host/http1/expectation.zig" },
    .{ .root = "platform/host/http1/request_limits.zig" },
};

const TestBuild = struct {
    /// `-O`; Debug when null.
    optimize: ?[]const u8 = null,
    sanitize_thread: bool = false,
};

/// Adds a `zig test` command for every root in `tests` to `step`, built as
/// `options` says.
fn addZigTests(b: *std.Build, step: *std.Build.Step, tests: []const ZigTest, options: TestBuild) void {
    for (tests) |spec| {
        if (spec.os) |os| if (os != b.graph.host.result.os.tag) continue;
        if (spec.link_http2) {
            std.debug.assert(spec.imports.len == 0 and spec.modules.len == 0);
            const optimize = if (options.optimize) |mode|
                std.meta.stringToEnum(std.builtin.OptimizeMode, mode).?
            else
                std.builtin.OptimizeMode.Debug;
            const module = b.createModule(.{
                .root_source_file = b.path(spec.root),
                .target = b.graph.host,
                .optimize = optimize,
                .sanitize_thread = options.sanitize_thread,
                .link_libc = spec.link_libc,
            });
            nghttp2_build.attach(b, module, b.graph.host, optimize);
            const executable = b.addTest(.{ .root_module = module, .use_llvm = true });
            step.dependOn(&b.addRunArtifact(executable).step);
            continue;
        }
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "test" });
        // The fiber's file-scope assembly requires LLVM on x86_64; the
        // default Debug backend leaves its entry/switch symbols undefined.
        if (b.graph.host.result.cpu.arch == std.Target.Cpu.Arch.x86_64) run.addArg("-fllvm");
        if (options.optimize) |mode| run.addArgs(&.{ "-O", mode });
        if (options.sanitize_thread) run.addArg("-fsanitize-thread");
        if (spec.imports.len == 0 and spec.modules.len == 0) {
            run.addArg(spec.root);
        } else {
            for (spec.imports) |name| run.addArgs(&.{ "--dep", name });
            run.addArg(b.fmt("-Mroot={s}", .{spec.root}));
            for (spec.modules) |module| {
                for (module.imports) |name| run.addArgs(&.{ "--dep", name });
                run.addArg(b.fmt("-M{s}={s}", .{ module.name, module.source }));
            }
        }
        if (spec.link_libc) run.addArg("-lc");
        step.dependOn(&run.step);
    }
}

const roc_targets = [_][]const u8{ "arm64mac", "arm64musl", "x64musl" };

fn zigTargetOf(roc_target: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, roc_target, "arm64mac")) return "aarch64-macos";
    if (std.mem.eql(u8, roc_target, "arm64musl")) return "aarch64-linux-musl";
    if (std.mem.eql(u8, roc_target, "x64musl")) return "x86_64-linux-musl";
    return null;
}

fn nativeRocTarget(b: *std.Build) []const u8 {
    const native = b.graph.host.result;
    return switch (native.os.tag) {
        std.Target.Os.Tag.macos => "arm64mac",
        std.Target.Os.Tag.linux => switch (native.cpu.arch) {
            std.Target.Cpu.Arch.aarch64 => "arm64musl",
            std.Target.Cpu.Arch.x86_64 => "x64musl",
            else => @panic("unsupported Linux architecture; pass -Droc-target"),
        },
        else => @panic("unsupported operating system; pass -Droc-target"),
    };
}

/// Builds `platform/targets/<roc_target>/libhost.a`. Musl targets also get
/// the `crt1.o` and `libc.a` that `platform/main.roc` lists as link inputs.
/// Where a host goes and whether it keeps debug information.
const HostBuild = struct {
    /// Directory holding the platform's `targets/`.
    platform_dir: []const u8,
    /// Release bundles drop debug information to stay under Roc's 10 MB
    /// package limit; panics then show addresses without function names.
    strip: bool,
    optimize: std.builtin.OptimizeMode,

    const release = HostBuild{ .platform_dir = release_platform_dir, .strip = true, .optimize = std.builtin.OptimizeMode.ReleaseSafe };
};

/// Staging copy of the platform for `zig build release`.
const release_platform_dir = "zig-out/release/platform";

fn addHostBuild(b: *std.Build, roc_target: []const u8, contract_alloc: bool, options: HostBuild) *std.Build.Step {
    const target_dir = b.fmt("{s}/targets/{s}", .{ options.platform_dir, roc_target });
    const host_object = b.fmt("{s}/host.o", .{target_dir});
    const resolved_target = b.resolveTargetQuery(
        std.Target.Query.parse(.{ .arch_os_abi = zigTargetOf(roc_target).? }) catch @panic("invalid Zig target"),
    );
    const musl = std.mem.endsWith(u8, roc_target, "musl");
    // A compile step, unlike a system command, is cached: an unchanged host
    // is not rebuilt (about 20 s per target).
    const host_module = struct {
        fn create(owner: *std.Build, path: []const u8, target: std.Build.ResolvedTarget, build_options: HostBuild, roc: []const u8, is_musl: bool) *std.Build.Module {
            return owner.createModule(.{
                .root_source_file = owner.path(path),
                .target = target,
                .optimize = build_options.optimize,
                .link_libc = true,
                .strip = build_options.strip,
                // Roc links musl apps as static PIE.
                .pic = if (is_musl) true else null,
                // LLVM's x86_64 stack protector pass is quadratic in one large
                // host function and runs for over 30 minutes (Zig 0.16);
                // without it the host builds in about 20 s. ReleaseSafe bounds
                // checks still apply. With it, `zig build-obj` for x86_64-linux-musl
                // with -fcompiler-rt -lc in ReleaseSafe also crashes (SIGSEGV),
                // even for a one-line file.
                .stack_protector = if (std.mem.eql(u8, roc, "x64musl")) false else null,
            });
        }
    }.create;
    const root_module = if (contract_alloc) blk: {
        const module = host_module(b, "tests/support/tracking_main.zig", resolved_target, options, roc_target, musl);
        module.addImport("host", host_module(b, "platform/host/host.zig", resolved_target, options, roc_target, musl));
        module.addImport("tracking_allocator", host_module(b, "tests/support/allocator/tracking_allocator.zig", resolved_target, options, roc_target, musl));
        break :blk module;
    } else host_module(b, "platform/host/main.zig", resolved_target, options, roc_target, musl);
    // Preserve the Zig object's exported Roc ABI symbols: compile the C engine
    // separately and archive both objects, rather than partial-linking them.
    const engine_module = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("nghttp2-root.zig", ""),
        .target = resolved_target,
        .optimize = options.optimize,
        .strip = options.strip,
        .pic = if (musl) true else null,
    });
    nghttp2_build.attach(b, engine_module, resolved_target, options.optimize);
    const engine_object = b.addObject(.{ .name = "nghttp2", .root_module = engine_module });
    const engine_bindings = engine_module.import_table.get("nghttp2_c").?;
    root_module.addImport("nghttp2_c", engine_bindings);
    if (root_module.import_table.get("host")) |host_namespace| host_namespace.addImport("nghttp2_c", engine_bindings);
    const compile_host = b.addObject(.{ .name = "host", .root_module = root_module });
    // musl's libc.a carries no compiler-rt, so the host brings its own.
    if (musl) compile_host.bundle_compiler_rt = true;

    const place_host_object = b.addUpdateSourceFiles();
    place_host_object.addCopyFileToSource(compile_host.getEmittedBin(), host_object);
    const archive_host = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "ar",
        "rcs",
        b.fmt("{s}/libhost.a", .{target_dir}),
        host_object,
    });
    archive_host.addFileArg(engine_object.getEmittedBin());
    archive_host.step.dependOn(&place_host_object.step);
    const write_musl_runtime = b.addSystemCommand(&.{
        "bash",
        "tools/musl-runtime.sh",
    });
    if (options.strip) write_musl_runtime.addArg("--strip");
    write_musl_runtime.addArgs(&.{ roc_target, target_dir });
    write_musl_runtime.step.dependOn(&archive_host.step);
    return &write_musl_runtime.step;
}

fn addHttp2RocFixture(b: *std.Build, roc_target: []const u8, target: std.Build.ResolvedTarget) *std.Build.Step {
    const compile_step = b.step("http2-roc-hosts", "Compile the real Roc HTTP/2 fixture hosts for roc-target");
    const musl = std.mem.endsWith(u8, roc_target, "musl");
    const c_module = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("http2-roc-engine.zig", ""),
        .target = target,
        .optimize = std.builtin.OptimizeMode.ReleaseSafe,
        .pic = if (musl) true else null,
    });
    nghttp2_build.attach(b, c_module, target, std.builtin.OptimizeMode.ReleaseSafe);
    const engine_object = b.addObject(.{ .name = "http2-roc-engine", .root_module = c_module });
    compile_step.dependOn(&engine_object.step);
    const run = b.addSystemCommand(&.{ "bash", "tests/http2-roc/run.sh", roc_target });
    for ([_]bool{ false, true }) |tracking| {
        const host_module = b.createModule(.{
            .root_source_file = b.path("platform/host/host.zig"),
            .target = target,
            .optimize = std.builtin.OptimizeMode.ReleaseSafe,
            .link_libc = true,
            .pic = if (musl) true else null,
            .stack_protector = if (std.mem.eql(u8, roc_target, "x64musl")) false else null,
        });
        host_module.addImport("nghttp2_c", c_module.import_table.get("nghttp2_c").?);
        const tracker = b.createModule(.{ .root_source_file = b.path("tests/support/allocator/tracking_allocator.zig"), .target = target, .optimize = std.builtin.OptimizeMode.ReleaseSafe });
        const environment = b.createModule(.{ .root_source_file = b.path("tests/support/allocator/tracking_environment.zig"), .target = target, .optimize = std.builtin.OptimizeMode.ReleaseSafe });
        environment.addImport("host", host_module);
        environment.addImport("tracking_allocator", tracker);
        const root = b.createModule(.{
            .root_source_file = b.path("tests/http2-roc/host.zig"),
            .target = target,
            .optimize = std.builtin.OptimizeMode.ReleaseSafe,
            .link_libc = true,
            .pic = if (musl) true else null,
            .stack_protector = if (std.mem.eql(u8, roc_target, "x64musl")) false else null,
        });
        root.addImport("host", host_module);
        root.addImport("tracking_environment", environment);
        const options = b.addOptions();
        options.addOption(bool, "tracking", tracking);
        root.addOptions("options", options);
        const object = b.addObject(.{ .name = if (tracking) "http2-roc-tracking" else "http2-roc-arena", .root_module = root });
        if (musl) object.bundle_compiler_rt = true;
        compile_step.dependOn(&object.step);
        run.addFileArg(object.getEmittedBin());
    }
    run.addFileArg(engine_object.getEmittedBin());
    return &run.step;
}
