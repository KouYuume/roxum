//! Host metrics: counters, histograms, and gauges every worker adds to
//! in one region of shared memory, which the supervisor renders in the
//! Prometheus text format on the admin port.
//!
//! The supervisor maps the region before it forks any worker, so every
//! worker shares it and a worker killed with SIGKILL loses nothing it
//! counted. Worker 0 writes the app's route patterns into it after `init!`;
//! the other workers fork after worker 0 is ready and find them there.
//! Requests are counted where their access log line is made, so the two
//! always agree.
const std = @import("std");
const access_log = @import("access_log.zig");
const diagnostics = @import("diagnostics.zig");

/// Route patterns past this many get no label (`route=""`), with a warning
/// at startup. Routes come from the app's code and do not grow at run time.
pub const maximum_routes: usize = 512;
/// Outbound origins (`host:port`) past this many, in the order first used,
/// are counted as `origin="other"`.
pub const maximum_origins: usize = 64;
pub const maximum_workers: usize = @import("worker_count.zig").maximum;
const maximum_origin_bytes: usize = 264;
/// Distinct route, method, status, and outcome combinations counted; past
/// this many, requests are counted in `roxum_metrics_dropped_total`.
const series_capacity: usize = 8192;

/// The bucket bounds of every histogram, as Prometheus clients use by
/// default (Go's `prometheus.DefBuckets`).
const bucket_bounds_nanoseconds = [_]u64{
    5 * std.time.ns_per_ms,   10 * std.time.ns_per_ms,  25 * std.time.ns_per_ms,
    50 * std.time.ns_per_ms,  100 * std.time.ns_per_ms, 250 * std.time.ns_per_ms,
    500 * std.time.ns_per_ms, 1 * std.time.ns_per_s,    2_500 * std.time.ns_per_ms,
    5 * std.time.ns_per_s,    10 * std.time.ns_per_s,
};
const bucket_labels = [_][]const u8{ "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "2.5", "5", "10" };

const methods = [_][]const u8{ "GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "QUERY", "CONNECT", "TRACE" };
const other_method: u64 = methods.len;
const no_method: u64 = methods.len + 1;
const no_route: usize = maximum_routes;
const other_origin: usize = maximum_origins;

const Counter = std.atomic.Value(u64);

fn add(counter: *Counter, amount: u64) void {
    _ = counter.fetchAdd(amount, std.builtin.AtomicOrder.monotonic);
}

fn read(counter: *const Counter) u64 {
    return counter.load(std.builtin.AtomicOrder.monotonic);
}

const Histogram = struct {
    /// Observations per bucket, not cumulative; the last is above 10 s.
    buckets: [bucket_bounds_nanoseconds.len + 1]Counter = @splat(Counter.init(0)),
    sum_nanoseconds: Counter = Counter.init(0),

    fn observe(self: *Histogram, nanoseconds: u64) void {
        const index = for (bucket_bounds_nanoseconds, 0..) |bound, index| {
            if (nanoseconds <= bound) break index;
        } else bucket_bounds_nanoseconds.len;
        add(&self.buckets[index], 1);
        add(&self.sum_nanoseconds, nanoseconds);
    }

    fn hasObservations(self: *const Histogram) bool {
        for (&self.buckets) |*bucket| {
            if (read(bucket) != 0) return true;
        }
        return false;
    }

    fn count(self: *const Histogram) u64 {
        var total: u64 = 0;
        for (&self.buckets) |*bucket| total += read(bucket);
        return total;
    }
};

/// One worker's current state, written by the worker and zeroed by the
/// supervisor when it ends.
pub const Gauges = struct {
    queued_requests: Counter = Counter.init(0),
    requests_in_progress: Counter = Counter.init(0),
    connections: Counter = Counter.init(0),
    streams: Counter = Counter.init(0),
    request_memory_bytes: Counter = Counter.init(0),
};

const Series = struct {
    /// 0 while the slot is free; otherwise the combination's key plus one.
    key: Counter = Counter.init(0),
    value: Counter = Counter.init(0),
};

const origin_empty: u32 = 0;
const origin_claimed: u32 = 1;
const origin_ready: u32 = 2;

const Region = struct {
    /// Set by worker 0 once the route patterns are written.
    routes_ready: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    route_count: usize = 0,
    /// False when the app has more routes than `maximum_routes`.
    route_labels: bool = true,
    route_names: [maximum_routes]access_log.Text(access_log.maximum_route_bytes) = @splat(.{}),
    series: [series_capacity]Series = @splat(.{}),
    dropped: Counter = Counter.init(0),
    route_duration: [maximum_routes + 1]Histogram = @splat(.{}),
    route_body_bytes: [maximum_routes + 1]Counter = @splat(Counter.init(0)),
    queue_wait: Histogram = .{},
    origin_states: [maximum_origins]std.atomic.Value(u32) = @splat(std.atomic.Value(u32).init(origin_empty)),
    origin_names: [maximum_origins]access_log.Text(maximum_origin_bytes) = @splat(.{}),
    origin_wait: [maximum_origins + 1]Histogram = @splat(.{}),
    origin_hold: [maximum_origins + 1]Histogram = @splat(.{}),
    workers: [maximum_workers]Gauges = @splat(.{}),
    worker_restarts: Counter = Counter.init(0),
    access_log_dropped: Counter = Counter.init(0),
};

var region: ?*Region = null;
/// Set in each worker when `listen.metrics` is on.
var counting: bool = false;
/// This worker's index, set in the worker after fork.
pub var worker_index: usize = 0;
/// Route pattern to its index in the region, per worker.
var route_indexes: std.StringHashMapUnmanaged(u16) = .empty;

/// Maps the shared region. Called by the supervisor before the first fork.
/// Its pages are zero and take no memory until a worker writes them.
pub fn createRegion() void {
    const mapped = std.c.mmap(
        null,
        std.mem.alignForward(usize, @sizeOf(Region), std.heap.page_size_min),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = @FieldType(std.c.MAP, "TYPE").SHARED, .ANONYMOUS = true },
        -1,
        0,
    );
    if (mapped == std.c.MAP_FAILED) return;
    // Zeroed pages are the region's initial state: every counter at 0 and
    // `route_labels` false until worker 0 sets it.
    region = @ptrCast(@alignCast(mapped));
}

pub fn enabled() bool {
    return counting;
}

/// Starts counting in this worker, for an app whose `listen.metrics` is on.
/// Worker 0 writes the route patterns first.
pub fn startWorker(routes: []const []const u8) error{ Unavailable, OutOfMemory }!void {
    const shared = region orelse return error.Unavailable;
    if (shared.routes_ready.load(std.builtin.AtomicOrder.acquire) == 0) {
        shared.route_labels = routes.len <= maximum_routes;
        if (!shared.route_labels) diagnostics.warning("the app has more than 512 route patterns; metrics count every request as route=\"\"");
        const kept = if (shared.route_labels) routes else &.{};
        for (kept, 0..) |route, index| shared.route_names[index].set(route);
        shared.route_count = kept.len;
        shared.routes_ready.store(1, std.builtin.AtomicOrder.release);
    }
    for (shared.route_names[0..shared.route_count], 0..) |*name, index| {
        try route_indexes.put(std.heap.smp_allocator, name.slice(), @intCast(index));
    }
    counting = true;
}

/// Counts a response that is done; called where its access log line is
/// made.
pub fn observeRequest(entry: *const access_log.Entry, duration_nanoseconds: u64) void {
    if (!counting) return;
    const shared = region orelse return;
    const route: usize = if (entry.route.len == 0) no_route else route_indexes.get(entry.route.slice()) orelse no_route;
    const key = seriesKey(route, methodIndex(entry.method.slice()), entry.status, @backingInt(entry.outcome));
    if (seriesFor(shared, key)) |series| add(&series.value, 1) else add(&shared.dropped, 1);
    shared.route_duration[route].observe(duration_nanoseconds);
    add(&shared.route_body_bytes[route], entry.body_bytes);
    if (entry.queue_nanoseconds) |nanoseconds| shared.queue_wait.observe(nanoseconds);
}

pub fn countAccessLogDropped() void {
    const shared = region orelse return;
    add(&shared.access_log_dropped, 1);
}

/// Counts a worker the supervisor restarts after it ended.
pub fn countRestart() void {
    const shared = region orelse return;
    add(&shared.worker_restarts, 1);
}

/// This worker's gauges, for it to write.
pub fn gauges() ?*Gauges {
    if (!counting) return null;
    const shared = region orelse return null;
    return &shared.workers[worker_index];
}

/// Zeroes the gauges of a worker that ended, so the supervisor does not
/// show what it held.
pub fn clearWorker(index: usize) void {
    const shared = region orelse return;
    shared.workers[index] = .{};
}

/// The index of an outbound origin, `host:port`, registering it when it is
/// first used. Past `maximum_origins`, `other`.
pub fn originIndex(name: []const u8) usize {
    const shared = region orelse return other_origin;
    for (&shared.origin_states, 0..) |*state, index| {
        while (true) {
            switch (state.load(std.builtin.AtomicOrder.acquire)) {
                origin_ready => {
                    if (std.mem.eql(u8, shared.origin_names[index].slice(), name[0..@min(name.len, maximum_origin_bytes)])) return index;
                    break;
                },
                origin_claimed => std.atomic.spinLoopHint(),
                else => {
                    if (state.cmpxchgWeak(origin_empty, origin_claimed, std.builtin.AtomicOrder.acquire, std.builtin.AtomicOrder.monotonic) != null) continue;
                    shared.origin_names[index].set(name);
                    state.store(origin_ready, std.builtin.AtomicOrder.release);
                    return index;
                },
            }
        }
    }
    return other_origin;
}

/// Time to get a connection from an outbound pool.
pub fn observeOriginWait(origin: usize, nanoseconds: u64) void {
    if (!counting) return;
    const shared = region orelse return;
    shared.origin_wait[origin].observe(nanoseconds);
}

/// Time a connection was lent before it came back.
pub fn observeOriginHold(origin: usize, nanoseconds: u64) void {
    if (!counting) return;
    const shared = region orelse return;
    shared.origin_hold[origin].observe(nanoseconds);
}

fn methodIndex(method: []const u8) u64 {
    if (method.len == 0) return no_method;
    for (methods, 0..) |known, index| {
        if (std.mem.eql(u8, known, method)) return index;
    }
    return other_method;
}

/// Route (10 bits), method (4), status (10), and outcome (4).
fn seriesKey(route: usize, method: u64, status: u16, outcome: u64) u64 {
    return (@as(u64, route) << 18) | (method << 14) | (@as(u64, @min(status, 1023)) << 4) | outcome;
}

fn unpackKey(key: u64) struct { route: usize, method: u64, status: u16, outcome: u64 } {
    return .{
        .route = @intCast(key >> 18),
        .method = (key >> 14) & 0xf,
        .status = @intCast((key >> 4) & 0x3ff),
        .outcome = key & 0xf,
    };
}

/// The series of `key`, claiming a free slot for a new one: open addressing
/// with linear probing, every worker adding to the same table.
fn seriesFor(shared: *Region, key: u64) ?*Series {
    const stored = key + 1;
    var index: usize = @intCast((stored *% 0x9e3779b97f4a7c15) >> 51);
    for (0..series_capacity) |_| {
        const series = &shared.series[index % series_capacity];
        const current = series.key.load(std.builtin.AtomicOrder.acquire);
        if (current == stored) return series;
        if (current == 0) {
            const won = series.key.cmpxchgStrong(0, stored, std.builtin.AtomicOrder.acq_rel, std.builtin.AtomicOrder.acquire);
            if (won == null or won.? == stored) return series;
        }
        index += 1;
    }
    return null;
}

/// Writes every metric in the Prometheus text format (0.0.4), for the
/// workers `0..worker_count`. Combinations never counted are left out.
pub fn render(writer: *std.Io.Writer, worker_count: usize) std.Io.Writer.Error!void {
    const shared = region orelse return;
    const route_count = if (shared.routes_ready.load(std.builtin.AtomicOrder.acquire) == 0) 0 else shared.route_count;

    try writer.writeAll("# HELP roxum_http_requests_total Responses, by route pattern, method, status, and outcome.\n# TYPE roxum_http_requests_total counter\n");
    for (&shared.series) |*series| {
        const stored = series.key.load(std.builtin.AtomicOrder.acquire);
        if (stored == 0) continue;
        const key = unpackKey(stored - 1);
        try writer.writeAll("roxum_http_requests_total{route=\"");
        try writeRoute(writer, shared, key.route, route_count);
        try writer.print("\",method=\"{s}\",status=\"{d}\",outcome=\"{s}\"}} {d}\n", .{
            methodLabel(key.method),
            key.status,
            outcomeLabel(key.outcome),
            read(&series.value),
        });
    }

    try writer.writeAll("# HELP roxum_http_request_duration_seconds Time from the complete request head to the response being done.\n# TYPE roxum_http_request_duration_seconds histogram\n");
    for (&shared.route_duration, 0..) |*histogram, route| {
        if (!histogram.hasObservations()) continue;
        var label_buffer: [access_log.maximum_route_bytes * 2 + 16]u8 = undefined;
        try writeHistogram(writer, "roxum_http_request_duration_seconds", try routeLabels(&label_buffer, shared, route, route_count), histogram);
    }

    try writer.writeAll("# HELP roxum_http_response_body_bytes_total Response body bytes, by route pattern.\n# TYPE roxum_http_response_body_bytes_total counter\n");
    for (&shared.route_body_bytes, 0..) |*bytes, route| {
        if (!shared.route_duration[route].hasObservations()) continue;
        try writer.writeAll("roxum_http_response_body_bytes_total{route=\"");
        try writeRoute(writer, shared, route, route_count);
        try writer.print("\"}} {d}\n", .{read(bytes)});
    }

    try writer.writeAll("# HELP roxum_queue_wait_seconds Time requests waited for a worker's Roc thread.\n# TYPE roxum_queue_wait_seconds histogram\n");
    try writeHistogram(writer, "roxum_queue_wait_seconds", "", &shared.queue_wait);

    try writer.writeAll("# HELP roxum_tcp_pool_wait_seconds Time to get a connection from an outbound pool, by origin.\n# TYPE roxum_tcp_pool_wait_seconds histogram\n");
    try writeOrigins(writer, shared, "roxum_tcp_pool_wait_seconds", &shared.origin_wait);
    try writer.writeAll("# HELP roxum_tcp_pool_hold_seconds Time a connection was lent before it came back, by origin.\n# TYPE roxum_tcp_pool_hold_seconds histogram\n");
    try writeOrigins(writer, shared, "roxum_tcp_pool_hold_seconds", &shared.origin_hold);

    const gauge_fields = [_]struct { name: []const u8, help: []const u8, field: []const u8 }{
        .{ .name = "roxum_queued_requests", .help = "Requests waiting for the worker's Roc thread.", .field = "queued_requests" },
        .{ .name = "roxum_requests_in_progress", .help = "Requests the worker started and has not finished.", .field = "requests_in_progress" },
        .{ .name = "roxum_connections", .help = "Connections the worker holds.", .field = "connections" },
        .{ .name = "roxum_streams", .help = "Streamed responses the worker is writing.", .field = "streams" },
        .{ .name = "roxum_request_memory_bytes", .help = "Memory the worker's requests hold.", .field = "request_memory_bytes" },
    };
    inline for (gauge_fields) |gauge| {
        try writer.print("# HELP {s} {s}\n# TYPE {s} gauge\n", .{ gauge.name, gauge.help, gauge.name });
        for (shared.workers[0..@min(worker_count, maximum_workers)], 0..) |*worker, index| {
            try writer.print("{s}{{worker=\"{d}\"}} {d}\n", .{ gauge.name, index, read(&@field(worker, gauge.field)) });
        }
    }

    try writer.print(
        "# HELP roxum_worker_restarts_total Workers the supervisor started again after one ended.\n# TYPE roxum_worker_restarts_total counter\nroxum_worker_restarts_total {d}\n" ++
            "# HELP roxum_access_log_dropped_total Access log lines dropped because stderr fell behind.\n# TYPE roxum_access_log_dropped_total counter\nroxum_access_log_dropped_total {d}\n" ++
            "# HELP roxum_metrics_dropped_total Requests not counted by route because too many combinations were seen.\n# TYPE roxum_metrics_dropped_total counter\nroxum_metrics_dropped_total {d}\n",
        .{ read(&shared.worker_restarts), read(&shared.access_log_dropped), read(&shared.dropped) },
    );
}

fn writeOrigins(writer: *std.Io.Writer, shared: *Region, name: []const u8, histograms: []Histogram) std.Io.Writer.Error!void {
    for (histograms, 0..) |*histogram, origin| {
        if (!histogram.hasObservations()) continue;
        var label_buffer: [maximum_origin_bytes * 2 + 16]u8 = undefined;
        var label_writer = std.Io.Writer.fixed(&label_buffer);
        try label_writer.writeAll("origin=\"");
        if (origin == other_origin) try label_writer.writeAll("other") else try writeLabelValue(&label_writer, shared.origin_names[origin].slice());
        try label_writer.writeByte('"');
        try writeHistogram(writer, name, label_writer.buffered(), histogram);
    }
}

fn routeLabels(buffer: []u8, shared: *Region, route: usize, route_count: usize) std.Io.Writer.Error![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("route=\"");
    try writeRoute(&writer, shared, route, route_count);
    try writer.writeByte('"');
    return writer.buffered();
}

fn writeRoute(writer: *std.Io.Writer, shared: *Region, route: usize, route_count: usize) std.Io.Writer.Error!void {
    if (route < route_count) try writeLabelValue(writer, shared.route_names[route].slice());
}

/// `labels` is empty or `name="value",...` without braces.
fn writeHistogram(writer: *std.Io.Writer, name: []const u8, labels: []const u8, histogram: *const Histogram) std.Io.Writer.Error!void {
    const separator = if (labels.len == 0) "" else ",";
    var cumulative: u64 = 0;
    for (bucket_labels, 0..) |bound, index| {
        cumulative += read(&histogram.buckets[index]);
        try writer.print("{s}_bucket{{{s}{s}le=\"{s}\"}} {d}\n", .{ name, labels, separator, bound, cumulative });
    }
    cumulative += read(&histogram.buckets[bucket_bounds_nanoseconds.len]);
    try writer.print("{s}_bucket{{{s}{s}le=\"+Inf\"}} {d}\n", .{ name, labels, separator, cumulative });
    const sum = read(&histogram.sum_nanoseconds);
    const braces_open = if (labels.len == 0) "" else "{";
    const braces_close = if (labels.len == 0) "" else "}";
    try writer.print("{s}_sum{s}{s}{s} {d}.{d:0>9}\n", .{ name, braces_open, labels, braces_close, sum / std.time.ns_per_s, sum % std.time.ns_per_s });
    try writer.print("{s}_count{s}{s}{s} {d}\n", .{ name, braces_open, labels, braces_close, cumulative });
}

/// Escapes a label value as the text format requires: backslash, double
/// quote, and line feed.
fn writeLabelValue(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            else => try writer.writeByte(byte),
        }
    }
}

fn methodLabel(method: u64) []const u8 {
    if (method < methods.len) return methods[method];
    if (method == other_method) return "other";
    return "";
}

fn outcomeLabel(outcome: u64) []const u8 {
    const info = @typeInfo(access_log.Outcome).@"enum";
    inline for (info.field_names, info.field_values) |name, value| {
        if (value == outcome) return name;
    }
    return "";
}

const testing = std.testing;

/// A region of its own, standing in for the shared one.
fn testRegion() !*Region {
    const created = try std.heap.page_allocator.create(Region);
    created.* = .{};
    region = created;
    counting = true;
    return created;
}

fn endTestRegion(created: *Region) void {
    route_indexes.clearAndFree(std.heap.smp_allocator);
    region = null;
    counting = false;
    std.heap.page_allocator.destroy(created);
}

fn testEntry(route: []const u8, method: []const u8, status: u16, outcome: access_log.Outcome) access_log.Entry {
    var entry = access_log.Entry{ .status = status, .outcome = outcome, .body_bytes = 5 };
    entry.route.set(route);
    entry.method.set(method);
    return entry;
}

test "histograms count an observation in the first bucket whose bound it does not pass" {
    var histogram = Histogram{};
    histogram.observe(5 * std.time.ns_per_ms - 1);
    histogram.observe(5 * std.time.ns_per_ms);
    histogram.observe(5 * std.time.ns_per_ms + 1);
    histogram.observe(10 * std.time.ns_per_s);
    histogram.observe(10 * std.time.ns_per_s + 1);
    try testing.expectEqual(@as(u64, 2), read(&histogram.buckets[0]));
    try testing.expectEqual(@as(u64, 1), read(&histogram.buckets[1]));
    try testing.expectEqual(@as(u64, 1), read(&histogram.buckets[bucket_bounds_nanoseconds.len - 1]));
    try testing.expectEqual(@as(u64, 1), read(&histogram.buckets[bucket_bounds_nanoseconds.len]));
    try testing.expectEqual(@as(u64, 5), histogram.count());
}

test "series keys keep every field at its limit" {
    const key = seriesKey(no_route, no_method, 999, @backingInt(access_log.Outcome.client_closed));
    const unpacked = unpackKey(key);
    try testing.expectEqual(no_route, unpacked.route);
    try testing.expectEqual(no_method, unpacked.method);
    try testing.expectEqual(@as(u16, 999), unpacked.status);
    try testing.expectEqual(@as(u64, @backingInt(access_log.Outcome.client_closed)), unpacked.outcome);
}

test "requests are counted by route, method, status, and outcome, and rendered once seen" {
    const created = try testRegion();
    defer endTestRegion(created);
    try startWorker(&.{ "/users/{id}", "fallback" });

    const user = testEntry("/users/{id}", "GET", 200, access_log.Outcome.handled);
    observeRequest(&user, 3 * std.time.ns_per_ms);
    observeRequest(&user, 20 * std.time.ns_per_ms);
    const refused = testEntry("", "", 503, access_log.Outcome.overloaded);
    observeRequest(&refused, 1);
    const unknown_method = testEntry("fallback", "BREW", 404, access_log.Outcome.handled);
    observeRequest(&unknown_method, 1);

    var buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try render(&writer, 1);
    const text = writer.buffered();
    const expected = [_][]const u8{
        "roxum_http_requests_total{route=\"/users/{id}\",method=\"GET\",status=\"200\",outcome=\"handled\"} 2\n",
        "roxum_http_requests_total{route=\"\",method=\"\",status=\"503\",outcome=\"overloaded\"} 1\n",
        "roxum_http_requests_total{route=\"fallback\",method=\"other\",status=\"404\",outcome=\"handled\"} 1\n",
        "roxum_http_request_duration_seconds_bucket{route=\"/users/{id}\",le=\"0.005\"} 1\n",
        "roxum_http_request_duration_seconds_bucket{route=\"/users/{id}\",le=\"0.025\"} 2\n",
        "roxum_http_request_duration_seconds_bucket{route=\"/users/{id}\",le=\"+Inf\"} 2\n",
        "roxum_http_request_duration_seconds_sum{route=\"/users/{id}\"} 0.023000000\n",
        "roxum_http_request_duration_seconds_count{route=\"/users/{id}\"} 2\n",
        "roxum_http_response_body_bytes_total{route=\"/users/{id}\"} 10\n",
        "roxum_queue_wait_seconds_count 0\n",
        "roxum_queued_requests{worker=\"0\"} 0\n",
        "roxum_worker_restarts_total 0\n",
    };
    for (expected) |line| {
        if (std.mem.indexOf(u8, text, line) == null) {
            std.debug.print("missing {s}in:\n{s}\n", .{ line, text });
            return error.TestUnexpectedResult;
        }
    }
    // Routes with no request have no histogram.
    try testing.expect(std.mem.indexOf(u8, text, "duration_seconds_count{route=\"fallback\"}") != null);
    try testing.expect(std.mem.indexOf(u8, text, "{route=\"/users\"") == null);
}

test "more routes than the limit are counted without a route label" {
    const created = try testRegion();
    defer endTestRegion(created);
    var names: [maximum_routes + 1][]const u8 = undefined;
    for (&names) |*name| name.* = "/r";
    try startWorker(&names);
    try testing.expect(!created.route_labels);
    try testing.expectEqual(@as(usize, 0), created.route_count);
    const entry = testEntry("/r", "GET", 200, access_log.Outcome.handled);
    observeRequest(&entry, 1);
    try testing.expectEqual(@as(u64, 1), created.route_duration[no_route].count());
}

test "a route at the limit keeps its label" {
    const created = try testRegion();
    defer endTestRegion(created);
    var names: [maximum_routes][]const u8 = undefined;
    var storage: [maximum_routes][8]u8 = undefined;
    for (&names, &storage, 0..) |*name, *bytes, index| name.* = std.fmt.bufPrint(bytes, "/{d}", .{index}) catch unreachable;
    try startWorker(&names);
    try testing.expect(created.route_labels);
    const last = testEntry(names[maximum_routes - 1], "GET", 200, access_log.Outcome.handled);
    observeRequest(&last, 1);
    try testing.expectEqual(@as(u64, 1), created.route_duration[maximum_routes - 1].count());
}

test "origins are registered once in first-use order, and past the limit counted as other" {
    const created = try testRegion();
    defer endTestRegion(created);
    try testing.expectEqual(@as(usize, 0), originIndex("db:5432"));
    try testing.expectEqual(@as(usize, 1), originIndex("api.example.com:443"));
    try testing.expectEqual(@as(usize, 0), originIndex("db:5432"));
    var buffer: [16]u8 = undefined;
    for (2..maximum_origins) |index| {
        try testing.expectEqual(index, originIndex(std.fmt.bufPrint(&buffer, "h{d}:1", .{index}) catch unreachable));
    }
    try testing.expectEqual(other_origin, originIndex("one-more:1"));
}

test "label values escape backslashes, quotes, and line feeds" {
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeLabelValue(&writer, "a\\b\"c\nd");
    try testing.expectEqualStrings("a\\\\b\\\"c\\nd", writer.buffered());
}

test "a full series table drops and counts" {
    const created = try testRegion();
    defer endTestRegion(created);
    for (0..series_capacity) |status| {
        try testing.expect(seriesFor(created, seriesKey(no_route, no_method, @intCast(status % 1000), status / 1000)) != null);
    }
    try testing.expect(seriesFor(created, seriesKey(0, 0, 200, 0)) == null);
}

test "histogram presence includes zero duration and every latency bucket" {
    var empty = Histogram{};
    try testing.expect(!empty.hasObservations());
    // Zero duration is an observation even though its sum remains zero.
    empty.observe(0);
    try testing.expect(empty.hasObservations());
    // One nanosecond above each bound covers each successive bucket,
    // including the final unbounded bucket. This tests presence, not rounding.
    for (bucket_bounds_nanoseconds) |bound| {
        var histogram = Histogram{};
        histogram.observe(bound + 1);
        try testing.expect(histogram.hasObservations());
    }
}
