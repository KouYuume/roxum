//! Build only the pinned protocol library; no TLS, socket runtime, or applications.
const std = @import("std");

pub fn attach(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const source = b.dependency("nghttp2", .{});
    const generated = b.addWriteFiles();
    _ = generated.add("nghttp2/nghttp2ver.h", "#define NGHTTP2_VERSION \"1.71.0\"\n#define NGHTTP2_VERSION_NUM 0x014700\n");
    const binding_header = generated.add("bindings.h", "#define NGHTTP2_STATICLIB 1\n#include <nghttp2/nghttp2.h>\n");
    const bindings = b.addTranslateC(.{
        .root_source_file = binding_header,
        .target = target,
        .optimize = optimize,
    });
    bindings.addIncludePath(generated.getDirectory());
    bindings.addIncludePath(source.path("lib/includes"));
    module.addImport("nghttp2_c", bindings.createModule());
    module.addIncludePath(generated.getDirectory());
    module.addIncludePath(source.path("lib/includes"));
    // Keep in sync with NGHTTP2_SOURCES in the pinned lib/CMakeLists.txt.
    module.addCSourceFiles(.{
        .root = source.path("lib"),
        .files = &.{
            "nghttp2_pq.c",         "nghttp2_map.c",             "nghttp2_queue.c",         "nghttp2_frame.c",
            "nghttp2_buf.c",        "nghttp2_stream.c",          "nghttp2_outbound_item.c", "nghttp2_session.c",
            "nghttp2_submit.c",     "nghttp2_helper.c",          "nghttp2_alpn.c",          "nghttp2_hd.c",
            "nghttp2_hd_huffman.c", "nghttp2_hd_huffman_data.c", "nghttp2_version.c",       "nghttp2_priority_spec.c",
            "nghttp2_option.c",     "nghttp2_callbacks.c",       "nghttp2_mem.c",           "nghttp2_http.c",
            "nghttp2_rcbuf.c",      "nghttp2_extpri.c",          "nghttp2_ratelim.c",       "nghttp2_time.c",
            "nghttp2_debug.c",      "sfparse.c",
        },
        .flags = &.{
            "-std=c11",
            "-DNGHTTP2_STATICLIB",
            "-DBUILDING_NGHTTP2",
            "-DHAVE_ARPA_INET_H=1",
            "-DHAVE_NETINET_IN_H=1",
            "-DHAVE_CLOCK_GETTIME=1",
            "-DHAVE_DECL_CLOCK_MONOTONIC=1",
            "-D_POSIX_C_SOURCE=200809L",
        },
    });
    module.link_libc = true;
}
