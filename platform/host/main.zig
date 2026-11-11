const std = @import("std");
const arena = @import("allocator/arena.zig");
const builtin = @import("builtin");
const diagnostics = @import("diagnostics.zig");
const launch = @import("launch.zig");
const server = @import("server.zig");
const supervisor = @import("supervisor.zig");

comptime {
    if (!builtin.is_test) @export(&cMain, .{ .name = "main" });
    @import("exports.zig").exportRuntime();
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
