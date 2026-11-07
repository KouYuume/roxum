//! The event loop's readiness backend: kqueue on Darwin, epoll on Linux.
const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    std.Target.Os.Tag.linux => @import("epoll.zig"),
    else => @import("kqueue.zig"),
};

pub const Error = backend.Error;
pub const Event = backend.Event;
pub const Poller = backend.Poller;
pub const RawEvent = backend.RawEvent;
pub const events_per_raw = backend.events_per_raw;

test {
    _ = backend;
}
