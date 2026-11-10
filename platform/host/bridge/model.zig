const net = @import("../net.zig");
const std = @import("std");
const abi = @import("../roc_platform_abi.zig");
const request_id = @import("../request_id.zig");
const access_log = @import("../access_log.zig");

pub const RocBox = abi.RocBox;
pub const RocHost = abi.RocHost;
pub const InitResult = abi.Init_for_hostResult;
pub const InitResultTag = abi.Init_for_hostResultTag;
pub const allocateBox = abi.allocateBox;
pub const decrefBox = abi.decrefBox;
pub const decrefErasedCallable = abi.decrefErasedCallable;
pub const RocErasedCallable = abi.RocErasedCallable;
pub const allocateErasedCallable = abi.rocErasedCallableAllocate;
pub const erasedCallableCapturePtr = abi.rocErasedCallableCapturePtr;
pub const isUniqueBox = abi.isUniqueBox;
pub const rocInit = abi.roc_init;
pub const rocHandle = abi.roc_handle;

pub const ListenOptions = struct {
    endpoint: net.Endpoint,
    timeouts: Timeouts,
    limits: Limits,
    threads: Threads,
    processes: u16,
    drain_timeout_milliseconds: u64,
    request_id: request_id.Source,
    access_log: access_log.Mode,
    /// Where the supervisor answers the admin port; null when it is off.
    metrics: ?MetricsListen,
    /// The app's route patterns, host-owned, for the metrics.
    routes: []const []const u8,
};

pub const MetricsListen = net.Endpoint;

/// How many threads one process runs requests on.
pub const Threads = union(enum) {
    auto,
    fixed: u16,
};

/// A limit for one process: `auto` scales the per-thread default by the
/// process's threads.
pub const Count = union(enum) {
    auto,
    fixed: u64,

    fn of(value: abi.ServerCount) Count {
        return switch (value.tag) {
            .Auto => .auto,
            .Fixed => .{ .fixed = value.payload_fixed() },
        };
    }
};

/// What one process holds at once, chosen by the application.
pub const Limits = struct {
    maximum_streams: Count,
    maximum_queued_requests: Count,
    queue_timeout_milliseconds: u64,
    maximum_requests_in_progress: Count,
    maximum_connections: Count,
    request_memory: MemoryLimit,
    /// A request body read whole into memory, and one read as a stream
    /// (null for no limit).
    maximum_body_bytes: u64,
    maximum_streamed_body_bytes: ?u64,
};

/// How much memory a process's requests may hold, chosen by the application.
pub const MemoryLimit = union(enum) {
    auto,
    bytes: u64,
};

/// Connection time limits chosen by the application, in milliseconds.
pub const Timeouts = struct {
    initial_request_milliseconds: u64,
    keep_alive_idle_milliseconds: u64,
    request_head_milliseconds: u64,
    request_body_milliseconds: u64,
    response_write_milliseconds: u64,
};

pub const Application = struct {
    model_root: ModelRoot,
    listen_options: ListenOptions,

    /// Takes ownership of the model reference contained in a successful
    /// `roc_init` result, and copies the route patterns, releasing Roc's.
    /// Endpoint paths are copied before releasing the Roc strings.
    pub fn initOwned(
        value: abi.Init_for_hostOk,
        roc_host: *abi.RocHost,
    ) (error{OutOfMemory} || net.Error)!Application {
        defer abi.decrefListOfStr(value.routes, roc_host);
        defer value.listen.endpoint.decref(roc_host);
        defer value.listen.metrics.decref(roc_host);
        const endpoint = try endpointFromRoc(value.listen.endpoint);
        const metrics: ?MetricsListen = switch (value.listen.metrics.tag) {
            abi.ServerMetricsTag.Off => null,
            abi.ServerMetricsTag.Listen => try endpointFromRoc(value.listen.metrics.payload_listen()),
        };
        const routes = try copyRoutes(value.routes);
        return .{
            .model_root = ModelRoot.initOwned(
                value.model,
                roc_host,
            ),
            .listen_options = .{
                .endpoint = endpoint,
                .timeouts = .{
                    .initial_request_milliseconds = value.listen.timeouts.initial_request_milliseconds,
                    .keep_alive_idle_milliseconds = value.listen.timeouts.keep_alive_idle_milliseconds,
                    .request_head_milliseconds = value.listen.timeouts.request_head_milliseconds,
                    .request_body_milliseconds = value.listen.timeouts.request_body_milliseconds,
                    .response_write_milliseconds = value.listen.timeouts.response_write_milliseconds,
                },
                .limits = .{
                    .maximum_streams = Count.of(value.listen.limits.maximum_streams),
                    .maximum_queued_requests = Count.of(value.listen.limits.maximum_queued_requests),
                    .queue_timeout_milliseconds = value.listen.limits.queue_timeout_milliseconds,
                    .maximum_requests_in_progress = Count.of(value.listen.limits.maximum_requests_in_progress),
                    .maximum_connections = Count.of(value.listen.limits.maximum_connections),
                    .request_memory = switch (value.listen.limits.request_memory.tag) {
                        .Auto => .auto,
                        .Bytes => .{ .bytes = value.listen.limits.request_memory.payload_bytes() },
                    },
                    .maximum_body_bytes = value.listen.limits.maximum_body_bytes,
                    .maximum_streamed_body_bytes = switch (value.listen.limits.maximum_streamed_body_bytes.tag) {
                        .Unlimited => null,
                        .Bytes => value.listen.limits.maximum_streamed_body_bytes.payload_bytes(),
                    },
                },
                .threads = switch (value.listen.threads.tag) {
                    .Auto => .auto,
                    .Fixed => .{ .fixed = value.listen.threads.payload_fixed() },
                },
                .processes = value.listen.processes,
                .drain_timeout_milliseconds = value.listen.drain_timeout_milliseconds,
                .request_id = switch (value.listen.request_id) {
                    abi.ServerRequestIdSource.generate => request_id.Source.generate,
                    abi.ServerRequestIdSource.trust_incoming => request_id.Source.trust_incoming,
                },
                .access_log = switch (value.listen.access_log) {
                    abi.ServerAccessLog.off => access_log.Mode.off,
                    abi.ServerAccessLog.json_lines => access_log.Mode.json_lines,
                    abi.ServerAccessLog.json_lines_with_path => access_log.Mode.json_lines_with_path,
                },
                .metrics = metrics,
                .routes = routes,
            },
        };
    }
};

/// Copies the route patterns into host memory, which lives as long as the
/// worker.
fn copyRoutes(routes: abi.RocList(abi.RocStr)) error{OutOfMemory}![]const []const u8 {
    const items = routes.items();
    const copies = try std.heap.smp_allocator.alloc([]const u8, items.len);
    for (items, copies) |*route, *copy| copy.* = try std.heap.smp_allocator.dupe(u8, route.asSlice());
    return copies;
}

pub const ModelRoot = struct {
    model: abi.RocBox,
    roc_host: *abi.RocHost,
    released: bool = false,

    /// Owns the boxed model returned by `roc_init`. It is data, not a
    /// function: `roc_handle` calls the top-level router with it, so no
    /// call goes through Roc's erased-callable runtime.
    pub fn initOwned(
        model: abi.RocBox,
        roc_host: *abi.RocHost,
    ) ModelRoot {
        return .{
            .model = model,
            .roc_host = roc_host,
        };
    }

    /// Creates the owned reference consumed by one `roc_handle` call.
    pub fn retainForHandle(self: *const ModelRoot) abi.RocBox {
        std.debug.assert(!self.released);
        abi.increfBox(self.model, 1);
        return self.model;
    }

    /// Releases the host's reference when the worker ends. The box's
    /// payload type is the app's, which the host does not know, so values
    /// inside it are not released: the process is about to exit.
    pub fn deinit(self: *ModelRoot) void {
        std.debug.assert(!self.released);
        abi.decrefBox(self.model, self.roc_host);
        self.released = true;
    }
};

fn ipFromRoc(ip: abi.HttpIpAddr) net.IpAddress {
    return switch (ip.tag) {
        abi.HttpIpAddrTag.V4 => blk: {
            const v = ip.payload_v4();
            break :blk .{ .v4 = .{ v._0, v._1, v._2, v._3 } };
        },
        abi.HttpIpAddrTag.V6 => blk: {
            const v = ip.payload_v6();
            break :blk .{ .v6 = .{ v._0, v._1, v._2, v._3, v._4, v._5, v._6, v._7 } };
        },
    };
}

test "listener addresses preserve the Roc family and every group" {
    var ip = std.mem.zeroes(abi.HttpIpAddr);
    ip.tag = abi.HttpIpAddrTag.V4;
    const v4: *abi.HttpIpAddrV4 = @ptrCast(@alignCast(&ip.payload));
    v4.* = .{ ._0 = 0, ._1 = 1, ._2 = 254, ._3 = 255 };
    try std.testing.expectEqual([4]u8{ 0, 1, 254, 255 }, ipFromRoc(ip).v4);

    // Distinct groups expose reordering; byte and U16 boundaries expose truncation.
    ip.tag = abi.HttpIpAddrTag.V6;
    const v6: *abi.HttpIpAddrV6 = @ptrCast(@alignCast(&ip.payload));
    v6.* = .{ ._0 = 0, ._1 = 1, ._2 = 255, ._3 = 256, ._4 = 257, ._5 = 0x1234, ._6 = 65534, ._7 = 65535 };
    try std.testing.expectEqual([8]u16{ 0, 1, 255, 256, 257, 0x1234, 65534, 65535 }, ipFromRoc(ip).v6);
}

fn endpointFromRoc(endpoint: abi.ServerEndpoint) net.Error!net.Endpoint {
    return switch (endpoint.tag) {
        abi.ServerEndpointTag.Tcp => blk: {
            const tcp = endpoint.payload_tcp();
            break :blk .{ .tcp = .{ .address = ipFromRoc(tcp.address), .port = tcp.port } };
        },
        abi.ServerEndpointTag.Unix => .{ .unix = try net.UnixPath.init(endpoint.payload_unix().path.asSlice()) },
    };
}
