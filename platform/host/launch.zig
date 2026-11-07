//! The executable's own command line. Arguments configure roxum at launch
//! and are never passed to the app.
const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const request_debug = @import("request_debug.zig");

pub const Options = struct {
    /// `--debug`: attach `dbg` output to responses. Never for production.
    debug: bool = false,
};

/// Null for an unknown or repeated argument; the caller exits with 2.
pub fn parse(arguments: []const [*:0]const u8) ?Options {
    var options = Options{};
    for (arguments) |argument| {
        const text = std.mem.span(argument);
        if (std.mem.eql(u8, text, "--debug") and !options.debug) {
            options.debug = true;
        } else {
            return null;
        }
    }
    return options;
}

/// Applies the options before workers fork, so every worker inherits them.
pub fn apply(options: Options) void {
    request_debug.enabled = options.debug;
    if (options.debug) {
        diagnostics.warning("debug mode: dbg output is attached to responses as X-Roxum-Dbg; do not use it in production");
    }
}

test "only --debug is accepted, once" {
    try std.testing.expectEqual(Options{}, parse(&.{}).?);
    try std.testing.expectEqual(Options{ .debug = true }, parse(&.{"--debug"}).?);
    try std.testing.expectEqual(@as(?Options, null), parse(&.{ "--debug", "--debug" }));
    try std.testing.expectEqual(@as(?Options, null), parse(&.{"--verbose"}));
}
