//! Internal HTTP/2 boundary. One serialized owner drives a session; callbacks
//! only copy/queue borrowed metadata and data, and never execute application code.
const std = @import("std");
const c = @import("nghttp2_c");
const Memory = @import("memory.zig").Memory;

pub const StreamId = enum(i32) { _ };
pub const Header = @import("../http_field.zig").Header;
pub const Error = error{ OutOfMemory, Protocol, Closed, ReentrantCall, InvalidState, InvalidHeaders, LimitExceeded };
pub const Limits = struct {
    session_bytes: usize = 1024 * 1024,
    concurrent_streams: u32 = 16,
    header_bytes: usize = 16 * 1024,
    body_bytes: usize = 64 * 1024,
    response_bytes: usize = 64 * 1024,
    stream_chunk_bytes: usize = 16 * 1024,
    input_queue_bytes: u32 = 16 * 1024,
};
pub const Observer = struct {
    context: *anyopaque,
    headers_started: ?*const fn (*anyopaque, StreamId) void = null,
    headers_finished: ?*const fn (*anyopaque, StreamId) void = null,
    /// Initial metadata is complete, before body EOF; never emitted for trailers.
    headers_complete: ?*const fn (*anyopaque, StreamId) void = null,
    header: *const fn (*anyopaque, StreamId, Header) void,
    data: *const fn (*anyopaque, StreamId, []const u8) void,
    end: *const fn (*anyopaque, StreamId) void,
    closed: *const fn (*anyopaque, StreamId) void,
    /// The transport consumed all bytes through response END_STREAM.
    response_sent: ?*const fn (*anyopaque, StreamId) void = null,
};
pub const ReadResult = union(enum) { pending, end, data: usize };

const Slot = struct {
    id: i32 = 0,
    headers: usize = 0,
    received: usize = 0,
    input: std.ArrayList(u8) = std.ArrayList(u8).empty,
    input_ended: bool = false,
    discard_limit: ?u64 = null,
    rejected: bool = false,
    peer_reset: bool = false,
    responded: bool = false,
    streaming: bool = false,
    remaining_length: ?u64 = null,
    streaming_headers_sent: bool = false,
    awaiting_trailers: bool = false,
    body_done: bool = false,
    head_request: bool = false,
    response: ?[]u8 = null,
    offset: usize = 0,
    final_fields: [64]Header = undefined,
    final_count: usize = 0,
    final_bytes: ?[]u8 = null,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    memory: Memory,
    limits: Limits,
    observer: Observer,
    input_budget: ?*Memory = null,
    input_settings_acked: bool = false,
    session: ?*c.nghttp2_session = null,
    slots: [16]Slot = @splat(.{}),
    pending: []const u8 = &.{},
    pending_response_end: ?StreamId = null,
    entered: bool = false,
    failed: bool = false,
    /// Valid during the closed observer callback.
    close_error: u32 = 0,
    close_peer_reset: bool = false,

    pub fn create(allocator: std.mem.Allocator, limits: Limits, observer: Observer) Error!*Engine {
        return createWithInput(allocator, limits, observer, null);
    }

    /// The input budget is borrowed, serialized by the same owner, and must
    /// outlive the engine. Its backing allocator also accounts to the worker.
    pub fn createIncremental(allocator: std.mem.Allocator, limits: Limits, observer: Observer, input_budget: *Memory) Error!*Engine {
        if (limits.input_queue_bytes == 0 or limits.input_queue_bytes > 65535) return error.LimitExceeded;
        return createWithInput(allocator, limits, observer, input_budget);
    }

    fn createWithInput(allocator: std.mem.Allocator, limits: Limits, observer: Observer, input_budget: ?*Memory) Error!*Engine {
        if (limits.concurrent_streams == 0 or limits.concurrent_streams > 16) return error.LimitExceeded;
        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .memory = .{ .backing = allocator, .limit = limits.session_bytes }, .limits = limits, .observer = observer, .input_budget = input_budget };
        var callbacks: ?*c.nghttp2_session_callbacks = null;
        try check(c.nghttp2_session_callbacks_new(&callbacks));
        defer c.nghttp2_session_callbacks_del(callbacks);
        c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, beginHeaders);
        c.nghttp2_session_callbacks_set_on_header_callback(callbacks, headerReceived);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, dataReceived);
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, frameReceived);
        c.nghttp2_session_callbacks_set_on_frame_send_callback(callbacks, frameSent);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, streamClosed);
        var memory = c.nghttp2_mem{ .mem_user_data = &self.memory, .malloc = allocate, .calloc = calloc, .realloc = resize, .free = release };
        var options: ?*c.nghttp2_option = null;
        try check(c.nghttp2_option_new(&options));
        defer c.nghttp2_option_del(options);
        if (input_budget != null) c.nghttp2_option_set_no_auto_window_update(options, 1);
        try check(c.nghttp2_session_server_new3(&self.session, callbacks, self, options, &memory));
        errdefer c.nghttp2_session_del(self.session);
        const settings = [_]c.nghttp2_settings_entry{
            .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = limits.concurrent_streams },
            .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = limits.input_queue_bytes },
        };
        try check(c.nghttp2_submit_settings(self.session, c.NGHTTP2_FLAG_NONE, &settings, if (input_budget == null) 1 else settings.len));
        return self;
    }

    pub fn destroy(self: *Engine) void {
        std.debug.assert(!self.entered);
        c.nghttp2_session_del(self.session);
        for (&self.slots) |*slot| {
            self.releaseInput(slot);
            if (slot.response) |bytes| self.memory.release(bytes.ptr);
            if (slot.final_bytes) |bytes| self.memory.allocator().free(bytes);
        }
        std.debug.assert(self.memory.used == 0);
        self.allocator.destroy(self);
    }

    pub fn receive(self: *Engine, bytes: []const u8) Error!void {
        try self.enter();
        defer self.entered = false;
        const consumed = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
        if (consumed < 0 or consumed != bytes.len) {
            self.failed = true;
            if (consumed == c.NGHTTP2_ERR_NOMEM) return error.OutOfMemory;
            return error.Protocol;
        }
    }

    /// Copy into caller-owned storage without retaining it. Only actual reads
    /// return receive credit; EOF does not finish the response. Empty buffers
    /// are invalid so a zero-byte read cannot be mistaken for EOF or progress.
    pub fn readRequest(self: *Engine, id: StreamId, destination: []u8) Error!ReadResult {
        try self.enter();
        defer self.entered = false;
        if (self.input_budget == null or destination.len == 0) return error.InvalidState;
        const slot = self.find(@backingInt(id)) orelse return error.Closed;
        if (slot.rejected or slot.discard_limit != null) return error.Closed;
        const count = @min(destination.len, slot.input.items.len);
        if (count == 0) return if (slot.input_ended) ReadResult.end else ReadResult.pending;
        @memcpy(destination[0..count], slot.input.items[0..count]);
        std.mem.copyForwards(u8, slot.input.items[0 .. slot.input.items.len - count], slot.input.items[count..]);
        slot.input.items.len -= count;
        if (slot.input.items.len == 0) self.releaseInput(slot);
        // Consumption can allocate WINDOW_UPDATE frames. Failure may have
        // partially changed both windows, so never retry this session.
        check(c.nghttp2_session_consume(self.session, slot.id, count)) catch |err| {
            self.failed = true;
            return err;
        };
        return .{ .data = count };
    }

    /// Level-triggered readiness, checked under the same lock as reader parking.
    pub fn requestReady(self: *Engine, id: StreamId) Error!bool {
        try self.enter();
        defer self.entered = false;
        if (self.input_budget == null) return error.InvalidState;
        const slot = self.find(@backingInt(id)) orelse return error.Closed;
        if (slot.rejected or slot.discard_limit != null) return error.Closed;
        return slot.input.items.len != 0 or slot.input_ended;
    }

    /// Execution ended before input EOF. Drain within a cumulative bound while
    /// retaining the protocol lease and its body deadline; never queue more input.
    pub fn discardRequest(self: *Engine, id: StreamId, maximum: u64) Error!void {
        try self.enter();
        defer self.entered = false;
        if (self.input_budget == null) return error.InvalidState;
        const slot = self.find(@backingInt(id)) orelse return error.Closed;
        if (slot.rejected) return error.Closed;
        slot.discard_limit = maximum;
        if (slot.received > maximum) {
            if (self.reject(slot) != 0) {
                self.failed = true;
                return error.Protocol;
            }
            return;
        }
        const count = slot.input.items.len;
        self.releaseInput(slot);
        check(c.nghttp2_session_consume(self.session, slot.id, count)) catch |err| {
            self.failed = true;
            return err;
        };
    }

    fn releaseInput(self: *Engine, slot: *Slot) void {
        if (self.input_budget) |memory| slot.input.deinit(memory.allocator());
        slot.input = std.ArrayList(u8).empty;
    }

    fn discardInput(self: *Engine, slot: *Slot) c_int {
        const count = slot.input.items.len;
        self.releaseInput(slot);
        return self.discardCredit(count);
    }

    fn discardCredit(self: *Engine, count: usize) c_int {
        if (self.input_budget == null or count == 0) return 0;
        if (c.nghttp2_session_consume_connection(self.session, count) == 0) return 0;
        self.failed = true;
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    }

    /// The returned bytes remain owned by the engine. A partial socket write
    /// advances only via consumeOutput; another call returns the unsent suffix.
    pub fn output(self: *Engine) Error![]const u8 {
        try self.enter();
        defer self.entered = false;
        if (self.pending.len != 0) return self.pending;
        // Complete finite responses only after DATA EOF. Validation and the
        // retained copy were done before committing the initial response.
        for (&self.slots) |*slot| {
            if (slot.final_bytes != null and slot.body_done and !slot.rejected) {
                self.submitTrailers(slot, slot.final_fields[0..slot.final_count]) catch |err| {
                    self.failed = true;
                    return err;
                };
                self.memory.allocator().free(slot.final_bytes.?);
                slot.final_bytes = null;
            }
        }
        var data: [*c]const u8 = null;
        const length = c.nghttp2_session_mem_send2(self.session, &data);
        if (length < 0) {
            self.failed = true;
            if (length == c.NGHTTP2_ERR_NOMEM) return error.OutOfMemory;
            return error.Protocol;
        }
        self.pending = if (length == 0) &.{} else data[0..@intCast(length)];
        return self.pending;
    }

    pub fn consumeOutput(self: *Engine, count: usize) Error!void {
        if (self.entered) return error.ReentrantCall;
        if (count > self.pending.len) return error.InvalidState;
        self.entered = true;
        defer self.entered = false;
        self.pending = self.pending[count..];
        if (self.pending.len == 0) {
            if (self.pending_response_end) |id| {
                self.pending_response_end = null;
                if (self.observer.response_sent) |sent| sent(self.observer.context, id);
                // A complete streamed response no longer needs request input.
                // Queue NO_ERROR only after the socket consumed END_STREAM;
                // an earlier reset could discard accepted DATA or trailers.
                if (self.find(@backingInt(id))) |slot| {
                    if (slot.streaming and !slot.input_ended and !slot.rejected) {
                        check(c.nghttp2_submit_rst_stream(self.session, c.NGHTTP2_FLAG_NONE, slot.id, c.NGHTTP2_NO_ERROR)) catch |err| {
                            self.failed = true;
                            return err;
                        };
                        slot.rejected = true;
                        if (self.discardInput(slot) != 0) return error.OutOfMemory;
                    }
                }
            }
        }
    }

    /// Check protocol admission immediately before handing input to execution.
    /// A queued reset already rejects dispatch before its close callback runs.
    pub fn checkDispatchable(self: *Engine, id: StreamId) Error!void {
        try self.enter();
        defer self.entered = false;
        const slot = self.find(@backingInt(id)) orelse return error.Closed;
        if (slot.rejected) return error.Closed;
        if (slot.responded) return error.InvalidState;
    }

    /// Copies response bytes; callers may release their buffers on return.
    /// Submits a finite response with automatic end-of-stream framing.
    pub fn respond(self: *Engine, id: StreamId, status: u16, headers: []const Header, body: []const u8) Error!void {
        return self.submitResponse(id, status, headers, body, false, null);
    }

    /// Keep the response open for explicit trailers after the finite DATA provider ends.
    pub fn beginResponse(self: *Engine, id: StreamId, status: u16, headers: []const Header, body: []const u8) Error!void {
        return self.submitResponse(id, status, headers, body, true, null);
    }

    /// Commits headers without ending output. Streaming has no declared length.
    pub fn beginStreamingResponse(self: *Engine, id: StreamId, status: u16, headers: []const Header) Error!void {
        for (headers) |header| {
            if (std.mem.eql(u8, header.name, "content-length")) return error.InvalidHeaders;
        }
        try self.beginResponse(id, status, headers, "");
        self.find(@backingInt(id)).?.streaming = true;
    }

    /// The caller supplies the matching host-generated Content-Length field.
    pub fn beginSizedStreamingResponse(self: *Engine, id: StreamId, status: u16, headers: []const Header, length: u64) Error!void {
        try self.submitResponse(id, status, headers, "", true, length);
        const slot = self.find(@backingInt(id)).?;
        slot.streaming = true;
        slot.remaining_length = length;
    }

    /// Readiness for a streaming write or finish, under the serialized owner.
    pub fn streamingReady(self: *Engine, id: StreamId) Error!bool {
        try self.enter();
        defer self.entered = false;
        const slot = self.find(@backingInt(id)) orelse return error.Closed;
        if (slot.rejected) return error.Closed;
        if (!slot.streaming or !slot.awaiting_trailers) return error.InvalidState;
        return slot.streaming_headers_sent and slot.body_done and self.pending.len == 0;
    }

    /// Copies one bounded chunk. False means retry after driving transport output;
    /// no caller bytes are retained on that path. Success is not peer delivery.
    pub fn writeStreamingResponse(self: *Engine, id: StreamId, bytes: []const u8) Error!bool {
        try self.enter();
        defer self.entered = false;
        const slot = self.find(@backingInt(id)) orelse return error.Closed;
        if (slot.rejected) return error.Closed;
        if (!slot.streaming or !slot.awaiting_trailers) return error.InvalidState;
        if (slot.remaining_length) |left| {
            if (bytes.len > left) return error.InvalidState;
        }
        if (bytes.len > self.limits.stream_chunk_bytes) return error.LimitExceeded;
        if (!slot.streaming_headers_sent or !slot.body_done or self.pending.len != 0) return false;
        if (bytes.len == 0) return true;
        const allocation = self.memory.allocate(bytes.len) orelse return error.OutOfMemory;
        const copy = @as([*]u8, @ptrCast(allocation))[0..bytes.len];
        var retained = false;
        defer if (!retained) self.memory.release(copy.ptr);
        @memcpy(copy, bytes);
        const provider = c.nghttp2_data_provider2{ .source = .{ .ptr = slot }, .read_callback = readResponse };
        const result = c.nghttp2_submit_data2(self.session, c.NGHTTP2_FLAG_NONE, slot.id, &provider);
        // Do not replace a DATA provider still owned by nghttp2.
        if (result == c.NGHTTP2_ERR_DATA_EXIST) return false;
        try check(result);
        slot.response = copy;
        slot.offset = 0;
        slot.body_done = false;
        if (slot.remaining_length) |*left| left.* -= bytes.len;
        retained = true;
        return true;
    }

    /// Copies a complete finite response, including final metadata, before the
    /// caller releases its request. Final fields are emitted after DATA EOF.
    pub fn respondWithTrailers(self: *Engine, id: StreamId, status: u16, headers: []const Header, body: []const u8, trailers: []const Header) Error!void {
        if (trailers.len == 0) return self.respond(id, status, headers, body);
        try self.checkDispatchable(id);
        try self.validateTrailers(trailers);
        var size: usize = 0;
        for (trailers) |header| size += header.name.len + header.value.len;
        const bytes = try self.memory.allocator().alloc(u8, size);
        errdefer self.memory.allocator().free(bytes);
        try self.beginResponse(id, status, headers, body);
        const slot = self.find(@backingInt(id)).?;
        var offset: usize = 0;
        for (trailers, 0..) |header, index| {
            const name = bytes[offset..][0..header.name.len];
            @memcpy(name, header.name);
            offset += name.len;
            const value = bytes[offset..][0..header.value.len];
            @memcpy(value, header.value);
            offset += value.len;
            slot.final_fields[index] = .{ .name = name, .value = value };
        }
        slot.final_count = trailers.len;
        slot.final_bytes = bytes;
    }

    /// Validate a deferred response without committing protocol output.
    pub fn validateFiniteResponse(self: *Engine, id: StreamId, status: u16, headers: []const Header, body: []const u8, trailers: []const Header) Error!void {
        if (self.entered) return error.ReentrantCall;
        try self.validateTrailers(trailers);
        try self.validateResponseHead(id, status, headers, body, trailers.len > 0, null);
    }

    fn validateResponseHead(self: *Engine, id: StreamId, status: u16, headers: []const Header, body: []const u8, trailers: bool, streamed_length: ?u64) Error!void {
        const slot = self.find(@backingInt(id)) orelse return error.Closed;
        if (slot.rejected) return error.Closed;
        if (slot.responded) return error.InvalidState;
        if (trailers and (slot.head_request or status == 204 or status == 205 or status == 304)) return error.InvalidState;
        if (status < 200 or status > 599) return error.InvalidHeaders;
        if ((status == 204 or status == 205 or status == 304) and body.len != 0) return error.InvalidState;
        if (headers.len > 64 or body.len > self.limits.response_bytes) return error.LimitExceeded;
        var total: usize = 42; // :status + three digits + RFC field accounting.
        var has_content_length = false;
        for (headers) |header| {
            if (!validHeader(header)) return error.InvalidHeaders;
            if (std.mem.eql(u8, header.name, "content-length")) {
                if (has_content_length or status == 204 or header.value.len == 0) return error.InvalidHeaders;
                has_content_length = true;
                for (header.value) |byte| if (byte < '0' or byte > '9') return error.InvalidHeaders;
                const length = std.fmt.parseInt(u64, header.value, 10) catch return error.InvalidHeaders;
                // HEAD and 304 describe a representation that is not sent here.
                if (status == 205 or (!slot.head_request and status != 304)) {
                    if (length != (streamed_length orelse body.len)) return error.InvalidHeaders;
                }
            }
            total = std.math.add(usize, total, header.name.len) catch return error.LimitExceeded;
            total = std.math.add(usize, total, header.value.len) catch return error.LimitExceeded;
            total = std.math.add(usize, total, 32) catch return error.LimitExceeded;
        }
        if (streamed_length != null and !has_content_length) return error.InvalidHeaders;
        if (total > self.limits.header_bytes) return error.LimitExceeded;
    }

    fn submitResponse(self: *Engine, id: StreamId, status: u16, headers: []const Header, body: []const u8, trailers: bool, streamed_length: ?u64) Error!void {
        try self.enter();
        defer self.entered = false;
        const slot = self.find(@backingInt(id)) orelse return error.Closed;
        if (slot.rejected) return error.Closed;
        if (slot.responded) return error.InvalidState;
        try self.validateResponseHead(id, status, headers, body, trailers, streamed_length);
        var status_buffer: [3]u8 = undefined;
        const status_text = std.fmt.bufPrint(&status_buffer, "{d}", .{status}) catch unreachable;
        var fields: [65]c.nghttp2_nv = undefined;
        fields[0] = field(":status", status_text);
        for (headers, 0..) |header, i| fields[i + 1] = field(header.name, header.value);
        const response_body = if (slot.head_request) body[0..0] else body;
        if (response_body.len > 0) {
            const allocation = self.memory.allocate(response_body.len) orelse return error.OutOfMemory;
            slot.response = @as([*]u8, @ptrCast(allocation))[0..response_body.len];
            @memcpy(slot.response.?, response_body);
        }
        errdefer if (slot.response) |bytes| {
            self.memory.release(bytes.ptr);
            slot.response = null;
        };
        const provider = c.nghttp2_data_provider2{ .source = .{ .ptr = slot }, .read_callback = readResponse };
        if (trailers and response_body.len == 0) {
            try check(c.nghttp2_submit_headers(self.session, c.NGHTTP2_FLAG_NONE, slot.id, null, &fields, headers.len + 1, null));
            slot.body_done = true;
        } else {
            try check(c.nghttp2_submit_response2(self.session, slot.id, &fields, headers.len + 1, if (response_body.len == 0) null else &provider));
        }
        slot.responded = true;
        slot.awaiting_trailers = trailers;
    }

    /// Copies final fields exactly once, after DATA EOF. Failed validation/allocation
    /// leaves completion available for retry; a closed stream can never complete.
    pub fn finishResponse(self: *Engine, id: StreamId, trailers: []const Header) Error!void {
        try self.enter();
        defer self.entered = false;
        const slot = self.find(@backingInt(id)) orelse return error.Closed;
        if (slot.rejected) return error.Closed;
        if (!slot.awaiting_trailers or !slot.body_done) return error.InvalidState;
        if ((slot.remaining_length orelse 0) != 0 or slot.final_bytes != null) return error.InvalidState;
        if (slot.streaming and (!slot.streaming_headers_sent or self.pending.len != 0)) return error.InvalidState;
        try self.submitTrailers(slot, trailers);
    }

    pub fn validateTrailers(self: *const Engine, trailers: []const Header) Error!void {
        if (trailers.len > 64) return error.LimitExceeded;
        var total: usize = 0;
        for (trailers) |header| {
            if (!validHeader(header)) return error.InvalidHeaders;
            for ([_][]const u8{ "content-length", "host", "trailer", "content-type", "content-encoding", "content-range", "authorization", "proxy-authorization", "www-authenticate", "proxy-authenticate" }) |forbidden| {
                if (std.mem.eql(u8, header.name, forbidden)) return error.InvalidHeaders;
            }
            total = std.math.add(usize, total, header.name.len) catch return error.LimitExceeded;
            total = std.math.add(usize, total, header.value.len) catch return error.LimitExceeded;
            total = std.math.add(usize, total, 32) catch return error.LimitExceeded;
        }
        if (total > self.limits.header_bytes) return error.LimitExceeded;
    }

    fn submitTrailers(self: *Engine, slot: *Slot, trailers: []const Header) Error!void {
        try self.validateTrailers(trailers);
        var fields: [64]c.nghttp2_nv = undefined;
        for (trailers, 0..) |header, index| fields[index] = field(header.name, header.value);
        try check(c.nghttp2_submit_trailer(self.session, slot.id, &fields, trailers.len));
        slot.awaiting_trailers = false;
    }

    pub fn cancel(self: *Engine, id: StreamId) Error!void {
        try self.enter();
        defer self.entered = false;
        const slot = self.find(@backingInt(id)) orelse return error.Closed;
        try check(c.nghttp2_submit_rst_stream(self.session, c.NGHTTP2_FLAG_NONE, slot.id, c.NGHTTP2_CANCEL));
        slot.rejected = true;
        if (self.discardInput(slot) != 0) return error.OutOfMemory;
    }

    pub fn beginDrain(self: *Engine) Error!void {
        try self.enter();
        defer self.entered = false;
        try check(c.nghttp2_submit_goaway(self.session, c.NGHTTP2_FLAG_NONE, c.nghttp2_session_get_last_proc_stream_id(self.session), c.NGHTTP2_NO_ERROR, null, 0));
    }

    pub fn activeStreams(self: *const Engine) usize {
        var count: usize = 0;
        for (self.slots) |slot| if (slot.id != 0) {
            count += 1;
        };
        return count;
    }

    fn enter(self: *Engine) Error!void {
        if (self.entered) return error.ReentrantCall;
        if (self.failed) return error.Closed;
        self.entered = true;
    }

    fn find(self: *Engine, id: i32) ?*Slot {
        if (id == 0) return null;
        for (&self.slots) |*slot| if (slot.id == id) return slot;
        return null;
    }

    fn reject(self: *Engine, slot: *Slot) c_int {
        if (slot.rejected) return 0;
        slot.rejected = true;
        if (self.discardInput(slot) != 0) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        return if (c.nghttp2_submit_rst_stream(self.session, c.NGHTTP2_FLAG_NONE, slot.id, c.NGHTTP2_ENHANCE_YOUR_CALM) == 0) 0 else c.NGHTTP2_ERR_CALLBACK_FAILURE;
    }
};

fn engine(user: ?*anyopaque) *Engine {
    return @ptrCast(@alignCast(user.?));
}
fn budget(user: ?*anyopaque) *Memory {
    return @ptrCast(@alignCast(user.?));
}
fn allocate(size: usize, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) ?*anyopaque {
    return budget(user).allocate(size);
}
fn release(ptr: ?*anyopaque, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) void {
    budget(user).release(ptr);
}
fn resize(ptr: ?*anyopaque, size: usize, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) ?*anyopaque {
    return budget(user).resize(ptr, size);
}
fn calloc(count: usize, size: usize, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) ?*anyopaque {
    const length = std.math.mul(usize, count, size) catch return null;
    const ptr = budget(user).allocate(length) orelse return null;
    @memset(@as([*]u8, @ptrCast(ptr))[0..length], 0);
    return ptr;
}
fn check(result: c_int) Error!void {
    if (result == c.NGHTTP2_ERR_NOMEM) return error.OutOfMemory;
    if (result < 0) return error.Protocol;
}
fn field(name: []const u8, value: []const u8) c.nghttp2_nv {
    return .{ .name = @constCast(name.ptr), .namelen = name.len, .value = @constCast(value.ptr), .valuelen = value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
}
fn validHeader(header: Header) bool {
    if (header.name.len == 0 or header.name[0] == ':') return false;
    for ([_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te" }) |forbidden| {
        if (std.mem.eql(u8, header.name, forbidden)) return false;
    }
    return c.nghttp2_check_header_name(header.name.ptr, header.name.len) != 0 and c.nghttp2_check_header_value_rfc9113(header.value.ptr, header.value.len) != 0;
}
fn beginHeaders(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) c_int {
    const self = engine(user);
    if (frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;
    for (self.slots[0..self.limits.concurrent_streams]) |*slot| {
        if (slot.id != 0) continue;
        slot.* = .{ .id = frame.*.hd.stream_id };
        if (self.observer.headers_started) |started| started(self.observer.context, @fromBackingInt(@intCast(slot.id)));
        return 0;
    }
    return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
}
fn headerReceived(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, name: [*c]const u8, name_len: usize, value: [*c]const u8, value_len: usize, _: u8, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) c_int {
    const self = engine(user);
    const slot = self.find(frame.*.hd.stream_id) orelse return 0;
    if (slot.rejected) return 0;
    var total = std.math.add(usize, slot.headers, name_len) catch return self.reject(slot);
    total = std.math.add(usize, total, value_len) catch return self.reject(slot);
    total = std.math.add(usize, total, 32) catch return self.reject(slot);
    if (total > self.limits.header_bytes) return self.reject(slot);
    slot.headers = total;
    if (std.mem.eql(u8, name[0..name_len], ":method")) slot.head_request = std.mem.eql(u8, value[0..value_len], "HEAD");
    self.observer.header(self.observer.context, @fromBackingInt(@intCast(slot.id)), .{ .name = name[0..name_len], .value = value[0..value_len] });
    return 0;
}
fn dataReceived(_: ?*c.nghttp2_session, _: u8, id: i32, data: [*c]const u8, length: usize, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) c_int {
    const self = engine(user);
    const slot = self.find(id) orelse return self.discardCredit(length);
    if (slot.rejected) return self.discardCredit(length);
    if (self.input_budget) |memory| {
        const total = std.math.add(usize, slot.received, length) catch {
            if (self.discardCredit(length) != 0) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            return self.reject(slot);
        };
        slot.received = total;
        if (slot.discard_limit) |maximum| {
            if (total > maximum) {
                if (self.discardCredit(length) != 0) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                return self.reject(slot);
            }
            if (c.nghttp2_session_consume(self.session, id, length) != 0) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            return 0;
        }
        // A peer may send the default 65,535-byte window before acknowledging
        // our smaller SETTINGS. Retain that bounded flight until it is read.
        const limit = if (self.input_settings_acked) self.limits.input_queue_bytes else 65535;
        if (length > limit -| slot.input.items.len) {
            if (self.discardCredit(length) != 0) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            return self.reject(slot);
        }
        if (slot.input.capacity < slot.input.items.len + length) slot.input.ensureTotalCapacityPrecise(memory.allocator(), limit) catch {
            if (self.discardCredit(length) != 0) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            return self.reject(slot);
        };
        slot.input.appendSliceAssumeCapacity(data[0..length]);
        self.observer.data(self.observer.context, @fromBackingInt(@intCast(id)), data[0..length]);
        return 0;
    }
    if (length > self.limits.body_bytes - slot.received) return self.reject(slot);
    slot.received += length;
    self.observer.data(self.observer.context, @fromBackingInt(@intCast(id)), data[0..length]);
    return 0;
}
fn frameReceived(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) c_int {
    const self = engine(user);
    if (frame.*.hd.type == c.NGHTTP2_SETTINGS and frame.*.hd.flags & c.NGHTTP2_FLAG_ACK != 0) self.input_settings_acked = true;
    if (frame.*.hd.type == c.NGHTTP2_RST_STREAM) {
        if (self.find(frame.*.hd.stream_id)) |slot| slot.peer_reset = true;
    }
    if (frame.*.hd.type == c.NGHTTP2_HEADERS and frame.*.headers.cat == c.NGHTTP2_HCAT_REQUEST) {
        if (self.observer.headers_finished) |finished| finished(self.observer.context, @fromBackingInt(@intCast(frame.*.hd.stream_id)));
        if (self.find(frame.*.hd.stream_id)) |slot| {
            if (!slot.rejected) {
                if (self.observer.headers_complete) |notify| notify(self.observer.context, @fromBackingInt(@intCast(slot.id)));
            }
        }
    }
    if ((frame.*.hd.type == c.NGHTTP2_HEADERS or frame.*.hd.type == c.NGHTTP2_DATA) and frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) {
        if (self.find(frame.*.hd.stream_id)) |slot| {
            slot.input_ended = true;
            if (!slot.rejected) self.observer.end(self.observer.context, @fromBackingInt(@intCast(slot.id)));
        }
    }
    return 0;
}
fn frameSent(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) c_int {
    if (frame.*.hd.type == c.NGHTTP2_HEADERS) {
        if (engine(user).find(frame.*.hd.stream_id)) |slot| {
            if (slot.streaming) slot.streaming_headers_sent = true;
        }
    }
    // mem_send serializes before the transport writes. For HEADERS, nghttp2
    // calls this only after the final CONTINUATION has been serialized.
    if ((frame.*.hd.type == c.NGHTTP2_HEADERS or frame.*.hd.type == c.NGHTTP2_DATA) and frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) {
        engine(user).pending_response_end = @fromBackingInt(@intCast(frame.*.hd.stream_id));
    }
    return 0;
}
fn streamClosed(_: ?*c.nghttp2_session, id: i32, error_code: u32, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) c_int {
    const self = engine(user);
    const slot = self.find(id) orelse return 0;
    if (self.discardInput(slot) != 0) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    if (slot.response) |bytes| self.memory.release(bytes.ptr);
    if (slot.final_bytes) |bytes| self.memory.allocator().free(bytes);
    self.close_peer_reset = slot.peer_reset;
    slot.* = .{};
    self.close_error = error_code;
    self.observer.closed(self.observer.context, @fromBackingInt(@intCast(id)));
    return 0;
}
fn readResponse(_: ?*c.nghttp2_session, _: i32, buffer: [*c]u8, length: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, user: ?*anyopaque) callconv(std.builtin.CallingConvention.c) isize {
    const slot: *Slot = @ptrCast(@alignCast(source.*.ptr.?));
    const bytes = slot.response orelse &.{};
    const count = @min(length, bytes.len - slot.offset);
    @memcpy(buffer[0..count], bytes[slot.offset..][0..count]);
    slot.offset += count;
    if (slot.offset == bytes.len) {
        slot.body_done = true;
        flags.* = c.NGHTTP2_DATA_FLAG_EOF;
        if (slot.awaiting_trailers) flags.* |= c.NGHTTP2_DATA_FLAG_NO_END_STREAM;
        if (slot.streaming) {
            if (slot.response) |owned| engine(user).memory.release(owned.ptr);
            slot.response = null;
        }
    }
    return @intCast(count);
}

test {
    _ = @import("memory.zig");
}

const TestObserver = struct {
    fn header(_: *anyopaque, _: StreamId, _: Header) void {}
    fn data(_: *anyopaque, _: StreamId, _: []const u8) void {}
    fn end(_: *anyopaque, _: StreamId) void {}
    fn closed(_: *anyopaque, _: StreamId) void {}
    fn observer(context: *anyopaque) Observer {
        return .{ .context = context, .header = header, .data = data, .end = end, .closed = closed };
    }
};

test "initialization budget failure and allocator failures release everything" {
    var context: u8 = 0;
    try std.testing.expectError(error.OutOfMemory, Engine.create(std.testing.allocator, .{ .session_bytes = 0 }, TestObserver.observer(&context)));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var value: u8 = 0;
            const self = try Engine.create(allocator, .{}, TestObserver.observer(&value));
            defer self.destroy();
            _ = try self.output();
        }
    }.run, .{});
}

test "output cursor preserves partial writes and validates consumed bytes" {
    var context: u8 = 0;
    const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
    defer self.destroy();
    const first = try self.output();
    try std.testing.expect(first.len > 1);
    const pointer = first.ptr;
    const length = first.len;
    try std.testing.expectError(error.InvalidState, self.consumeOutput(length + 1));
    try self.consumeOutput(1);
    const remaining = try self.output();
    try std.testing.expectEqual(length - 1, remaining.len);
    try std.testing.expectEqual(@intFromPtr(pointer) + 1, @intFromPtr(remaining.ptr));
    try self.consumeOutput(remaining.len);
    try std.testing.expectEqual(@as(usize, 0), (try self.output()).len);
}

test "invalid preface terminates this engine" {
    var context: u8 = 0;
    const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
    defer self.destroy();
    try std.testing.expectError(error.Protocol, self.receive("GET / HTTP/1.1\r\n\r\n"));
    try std.testing.expectError(error.Closed, self.receive(""));
    try std.testing.expectError(error.Closed, self.output());
}

test "stream admission configuration boundaries" {
    var context: u8 = 0;
    for ([_]u32{ 0, 1, 15, 16, 17 }) |count| {
        if (count == 0 or count == 17) {
            try std.testing.expectError(error.LimitExceeded, Engine.create(std.testing.allocator, .{ .concurrent_streams = count }, TestObserver.observer(&context)));
        } else {
            const self = try Engine.create(std.testing.allocator, .{ .concurrent_streams = count }, TestObserver.observer(&context));
            self.destroy();
        }
    }
}

test "response headers reject HTTP/1 fields, pseudo-fields, invalid names and values" {
    try std.testing.expect(validHeader(.{ .name = "content-type", .value = "text/plain" }));
    try std.testing.expect(validHeader(.{ .name = "x-empty", .value = "" }));
    for ([_][]const u8{ "", ":status", "Connection", "connection", "transfer-encoding", "te", "bad name" }) |name| {
        try std.testing.expect(!validHeader(.{ .name = name, .value = "value" }));
    }
    for ([_][]const u8{ "bad\rvalue", "bad\nvalue", "bad\x00value", " leading", "trailing " }) |value| {
        try std.testing.expect(!validHeader(.{ .name = "x-test", .value = value }));
    }
}

fn openTestStream(self: *Engine) !void {
    const request = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
        "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
        "\x00\x00\x0e\x01\x05\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost";
    // Split inside every frame/header boundary, including the connection preface.
    for (request) |byte| try self.receive(&.{byte});
}

test "response size boundary, allocation failure rollback, and duplicate completion" {
    var context: u8 = 0;
    const self = try Engine.create(std.testing.allocator, .{ .response_bytes = 16 }, TestObserver.observer(&context));
    defer self.destroy();
    try openTestStream(self);
    const id: StreamId = @fromBackingInt(@intCast(1));
    try std.testing.expectError(error.LimitExceeded, self.respond(id, 200, &.{}, &@as([17]u8, @splat(1))));
    const budget_limit = self.memory.limit;
    self.memory.limit = self.memory.used;
    try std.testing.expectError(error.OutOfMemory, self.respond(id, 200, &.{}, &@as([16]u8, @splat(1))));
    self.memory.limit = budget_limit;
    try self.respond(id, 200, &.{}, &@as([16]u8, @splat(1)));
    try std.testing.expectError(error.InvalidState, self.respond(id, 200, &.{}, ""));
    while (true) {
        const bytes = try self.output();
        if (bytes.len == 0) break;
        try self.consumeOutput(bytes.len);
    }
    try std.testing.expectError(error.Closed, self.respond(id, 200, &.{}, ""));
}

test "response allocation failure paths release all native and C allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var context: u8 = 0;
            const self = try Engine.create(allocator, .{}, TestObserver.observer(&context));
            defer self.destroy();
            try openTestStream(self);
            try self.respond(@fromBackingInt(@intCast(1)), 200, &.{}, "response");
            while (true) {
                const bytes = try self.output();
                if (bytes.len == 0) break;
                try self.consumeOutput(bytes.len);
            }
        }
    }.run, .{});
}

test "finite response length and final status boundaries" {
    var context: u8 = 0;
    for ([_]usize{ 15, 16, 17 }) |size| {
        const self = try Engine.create(std.testing.allocator, .{ .response_bytes = 16 }, TestObserver.observer(&context));
        defer self.destroy();
        try openTestStream(self);
        const bytes: [17]u8 = @splat(1);
        if (size <= 16) {
            try self.respond(@fromBackingInt(@intCast(1)), 200, &.{}, bytes[0..size]);
        } else {
            try std.testing.expectError(error.LimitExceeded, self.respond(@fromBackingInt(@intCast(1)), 200, &.{}, bytes[0..size]));
        }
    }
    for ([_]u16{ 199, 200, 201, 598, 599, 600 }) |status| {
        const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
        defer self.destroy();
        try openTestStream(self);
        if (status >= 200 and status <= 599) {
            try self.respond(@fromBackingInt(@intCast(1)), status, &.{}, "");
        } else {
            try std.testing.expectError(error.InvalidHeaders, self.respond(@fromBackingInt(@intCast(1)), status, &.{}, ""));
        }
    }
}

test "body-forbidden statuses reject data before committing a response" {
    var context: u8 = 0;
    for ([_]u16{ 204, 205, 304 }) |status| {
        const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
        defer self.destroy();
        try openTestStream(self);
        try std.testing.expectError(error.InvalidState, self.respond(@fromBackingInt(@intCast(1)), status, &.{}, "x"));
        try self.respond(@fromBackingInt(@intCast(1)), status, &.{}, "");
    }
}

test "local cancellation invalidates the response and releases its slot" {
    var context: u8 = 0;
    const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
    defer self.destroy();
    try openTestStream(self);
    const id: StreamId = @fromBackingInt(@intCast(1));
    try self.cancel(id);
    try std.testing.expectError(error.Closed, self.respond(id, 200, &.{}, ""));
    while (true) {
        const bytes = try self.output();
        if (bytes.len == 0) break;
        try self.consumeOutput(bytes.len);
    }
    try std.testing.expect(self.find(1) == null);
}

test "an observer cannot recursively drive the session" {
    const Context = struct {
        self: ?*Engine = null,
        rejected: bool = false,
        fn end(ctx: *anyopaque, _: StreamId) void {
            const context: *@This() = @ptrCast(@alignCast(ctx));
            _ = context.self.?.output() catch |err| {
                context.rejected = err == error.ReentrantCall;
                return;
            };
        }
    };
    var context = Context{};
    var observer = TestObserver.observer(&context);
    observer.end = Context.end;
    const self = try Engine.create(std.testing.allocator, .{}, observer);
    defer self.destroy();
    context.self = self;
    try openTestStream(self);
    try std.testing.expect(context.rejected);
}

test "content length rejects malformed fields and mismatches without committing" {
    var context: u8 = 0;
    const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
    defer self.destroy();
    try openTestStream(self);
    const id: StreamId = @fromBackingInt(@intCast(1));
    // Nearest lengths below/at/above a one-byte body, plus invalid decimal syntax.
    for ([_][]const u8{ "0", "2", "", "-1", "+1", "1a", "1, 1", "18446744073709551616" }) |value| {
        try std.testing.expectError(error.InvalidHeaders, self.respond(id, 200, &.{.{ .name = "content-length", .value = value }}, "x"));
    }
    const duplicate = [_]Header{ .{ .name = "content-length", .value = "1" }, .{ .name = "content-length", .value = "1" } };
    try std.testing.expectError(error.InvalidHeaders, self.respond(id, 200, &duplicate, "x"));
    try self.respond(id, 200, &.{.{ .name = "content-length", .value = "1" }}, "x");
}

test "content length respects bodyless status and HEAD representation metadata" {
    var context: u8 = 0;
    for ([_]u16{ 204, 205, 304 }) |status| {
        const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
        defer self.destroy();
        try openTestStream(self);
        const id: StreamId = @fromBackingInt(@intCast(1));
        const nonzero = [_]Header{.{ .name = "content-length", .value = "1" }};
        if (status == 304) {
            try self.respond(id, status, &nonzero, "");
        } else {
            try std.testing.expectError(error.InvalidHeaders, self.respond(id, status, &nonzero, ""));
            const zero = [_]Header{.{ .name = "content-length", .value = "0" }};
            if (status == 204) {
                try std.testing.expectError(error.InvalidHeaders, self.respond(id, status, &zero, ""));
                try self.respond(id, status, &.{}, "");
            } else {
                try self.respond(id, status, &zero, "");
            }
        }
    }
    const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
    defer self.destroy();
    try openTestStream(self);
    self.find(1).?.head_request = true;
    try self.respond(@fromBackingInt(@intCast(1)), 200, &.{.{ .name = "content-length", .value = "123" }}, "");
}

test "representation content length accepts u64 boundary and rejects overflow" {
    var context: u8 = 0;
    for ([_][]const u8{ "18446744073709551614", "18446744073709551615", "18446744073709551616" }, 0..) |value, i| {
        const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
        defer self.destroy();
        try openTestStream(self);
        const id: StreamId = @fromBackingInt(@intCast(1));
        const headers = [_]Header{.{ .name = "content-length", .value = value }};
        if (i < 2) {
            try self.respond(id, 304, &headers, "");
        } else {
            try std.testing.expectError(error.InvalidHeaders, self.respond(id, 304, &headers, ""));
        }
    }
}

test "initial metadata notification precedes EOF and excludes trailers and rejected headers" {
    const Context = struct {
        heads: usize = 0,
        ends: usize = 0,
        fn head(ctx: *anyopaque, _: StreamId) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.heads += 1;
        }
        fn end(ctx: *anyopaque, _: StreamId) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(self.heads == 1);
            self.ends += 1;
        }
    };
    for ([_]bool{ false, true }) |rejected| {
        var context = Context{};
        var observer = TestObserver.observer(&context);
        observer.headers_complete = Context.head;
        observer.end = Context.end;
        const self = try Engine.create(std.testing.allocator, .{ .header_bytes = if (rejected) 0 else 1024 }, observer);
        defer self.destroy();
        const request = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
            "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
            "\x00\x00\x0e\x01\x04\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost";
        for (request[0 .. request.len - 1]) |byte| try self.receive(&.{byte});
        try std.testing.expectEqual(@as(usize, 0), context.heads);
        try self.receive(request[request.len - 1 ..]);
        try std.testing.expectEqual(@as(usize, if (rejected) 0 else 1), context.heads);
        try std.testing.expectEqual(@as(usize, 0), context.ends);
        if (!rejected) {
            // An empty trailing HEADERS block ends input without repeating initial metadata.
            try self.receive("\x00\x00\x00\x01\x05\x00\x00\x00\x01");
            try std.testing.expectEqual(@as(usize, 1), context.heads);
            try std.testing.expectEqual(@as(usize, 1), context.ends);
        }
    }
}

test "initial metadata handles END_STREAM continuation validation and reentry" {
    const Context = struct {
        engine: ?*Engine = null,
        heads: usize = 0,
        ends: usize = 0,
        ordered: bool = false,
        reentry_rejected: bool = false,
        fn head(ctx: *anyopaque, _: StreamId) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.heads += 1;
            _ = self.engine.?.output() catch |err| {
                self.reentry_rejected = err == error.ReentrantCall;
                return;
            };
        }
        fn end(ctx: *anyopaque, _: StreamId) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ordered = self.heads == 1;
            self.ends += 1;
        }
    };
    const Case = enum { header_only, continuation, missing_path };
    for ([_]Case{ Case.header_only, Case.continuation, Case.missing_path }) |case| {
        var context = Context{};
        var observer = TestObserver.observer(&context);
        observer.headers_complete = Context.head;
        observer.end = Context.end;
        const self = try Engine.create(std.testing.allocator, .{}, observer);
        defer self.destroy();
        context.engine = self;
        try self.receive("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00");
        switch (case) {
            Case.header_only => try self.receive("\x00\x00\x0e\x01\x05\x00\x00\x00\x01\x83\x86\x84\x01\x09localhost"),
            Case.continuation => {
                // END_STREAM belongs to HEADERS, while metadata completes only at END_HEADERS.
                try self.receive("\x00\x00\x03\x01\x01\x00\x00\x00\x01\x83\x86\x84");
                try std.testing.expectEqual(@as(usize, 0), context.heads);
                try std.testing.expectEqual(@as(usize, 0), context.ends);
                try self.receive("\x00\x00\x0b\x09\x04\x00\x00\x00\x01\x01\x09localhost");
            },
            Case.missing_path => try self.receive("\x00\x00\x0d\x01\x05\x00\x00\x00\x01\x83\x86\x01\x09localhost"),
        }
        const valid = case != Case.missing_path;
        try std.testing.expectEqual(@as(usize, if (valid) 1 else 0), context.heads);
        try std.testing.expectEqual(@as(usize, if (valid) 1 else 0), context.ends);
        try std.testing.expectEqual(valid, context.ordered);
        try std.testing.expectEqual(valid, context.reentry_rejected);
    }
}

test "explicit trailers complete empty and finite bodies once without DATA END_STREAM" {
    for ([_][]const u8{ "", "body" }) |body| {
        var context: u8 = 0;
        const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
        defer self.destroy();
        try openTestStream(self);
        const id: StreamId = @fromBackingInt(1);
        try std.testing.expectError(error.InvalidState, self.finishResponse(id, &.{}));
        try self.beginResponse(id, 200, &.{}, body);
        if (body.len > 0) try std.testing.expectError(error.InvalidState, self.finishResponse(id, &.{}));
        while (true) {
            const bytes = try self.output();
            if (bytes.len == 0) break;
            // nghttp2 emits complete frames in each mem_send batch.
            try std.testing.expect(bytes.len >= 9);
            if (bytes[3] == 0 or bytes[3] == 1) try std.testing.expect(bytes[4] & 1 == 0);
            try self.consumeOutput(bytes.len);
        }
        try std.testing.expectEqual(@as(usize, 1), self.activeStreams());
        for ([_][]const u8{ ":status", "content-length", "connection", "host", "content-type" }) |name| {
            try std.testing.expectError(error.InvalidHeaders, self.finishResponse(id, &.{.{ .name = name, .value = "x" }}));
        }
        try self.finishResponse(id, &.{.{ .name = "x-result", .value = "done" }});
        try std.testing.expectError(error.InvalidState, self.finishResponse(id, &.{}));
        const final = try self.output();
        try std.testing.expect(final.len >= 9);
        try std.testing.expectEqual(@as(u8, 1), final[3]);
        try std.testing.expect(final[4] & 1 != 0);
        try self.consumeOutput(final.len);
        try std.testing.expectEqual(@as(usize, 0), self.activeStreams());
        try std.testing.expectError(error.Closed, self.finishResponse(id, &.{}));
    }
}

test "trailer field accounting accepts below and at budget and rejects above" {
    for ([_]usize{ 63, 64, 65 }) |bytes| {
        var context: u8 = 0;
        const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
        defer self.destroy();
        try openTestStream(self);
        self.limits.header_bytes = 64;
        const id: StreamId = @fromBackingInt(1);
        try self.beginResponse(id, 200, &.{}, "");
        while (true) {
            const output = try self.output();
            if (output.len == 0) break;
            try self.consumeOutput(output.len);
        }
        const value: [32]u8 = @splat('a');
        const trailers = [_]Header{.{ .name = "x", .value = value[0 .. bytes - 33] }};
        if (bytes <= 64) {
            try self.finishResponse(id, &trailers);
        } else {
            try std.testing.expectError(error.LimitExceeded, self.finishResponse(id, &trailers));
            try self.finishResponse(id, &.{});
        }
    }
}

test "explicit trailer allocation failures release all owned storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var context: u8 = 0;
            const self = try Engine.create(allocator, .{}, TestObserver.observer(&context));
            defer self.destroy();
            try openTestStream(self);
            try self.beginResponse(@fromBackingInt(1), 200, &.{}, "data");
            while (true) {
                const bytes = try self.output();
                if (bytes.len == 0) break;
                try self.consumeOutput(bytes.len);
            }
            try self.finishResponse(@fromBackingInt(1), &.{.{ .name = "x-result", .value = "ok" }});
            while (true) {
                const bytes = try self.output();
                if (bytes.len == 0) break;
                try self.consumeOutput(bytes.len);
            }
        }
    }.run, .{});
}

test "trailer completion at stream window boundary needs no extra DATA credit" {
    for ([_]usize{ 65534, 65535, 65536 }) |size| {
        var context: u8 = 0;
        const self = try Engine.create(std.testing.allocator, .{ .response_bytes = 65536 }, TestObserver.observer(&context));
        defer self.destroy();
        try openTestStream(self);
        const body = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(body);
        @memset(body, 'x');
        const id: StreamId = @fromBackingInt(1);
        try self.beginResponse(id, 200, &.{}, body);
        while (true) {
            const bytes = try self.output();
            if (bytes.len == 0) break;
            try self.consumeOutput(bytes.len);
        }
        if (size == 65536) {
            try std.testing.expectError(error.InvalidState, self.finishResponse(id, &.{}));
            // Restore one byte of both stream and connection credit.
            try self.receive("\x00\x00\x04\x08\x00\x00\x00\x00\x00\x00\x00\x00\x01" ++
                "\x00\x00\x04\x08\x00\x00\x00\x00\x01\x00\x00\x00\x01");
            while (true) {
                const bytes = try self.output();
                if (bytes.len == 0) break;
                try self.consumeOutput(bytes.len);
            }
        }
        try self.finishResponse(id, &.{});
        const final = try self.output();
        try std.testing.expect(final.len >= 9 and final[3] == 1 and final[4] & 1 != 0);
        try self.consumeOutput(final.len);
    }
}

test "trailer field count boundary and reset reject terminal reuse" {
    for ([_]usize{ 63, 64, 65 }) |count| {
        var context: u8 = 0;
        const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
        defer self.destroy();
        try openTestStream(self);
        const id: StreamId = @fromBackingInt(1);
        for ([_]u16{ 204, 205, 304 }) |status| try std.testing.expectError(error.InvalidState, self.beginResponse(id, status, &.{}, ""));
        try self.beginResponse(id, 200, &.{}, "");
        const fields: [65]Header = @splat(.{ .name = "x", .value = "y" });
        if (count <= 64) {
            try self.finishResponse(id, fields[0..count]);
        } else {
            try std.testing.expectError(error.LimitExceeded, self.finishResponse(id, fields[0..count]));
            try self.cancel(id);
            try std.testing.expectError(error.Closed, self.finishResponse(id, &.{}));
        }
    }
}

// A retained copy must survive caller mutation, cancellation, and each OOM site.
test "finite trailers copy before commit and release on completion reset or destruction" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            for ([_]u8{ 0, 1, 2 }) |ending| {
                var context: u8 = 0;
                const self = try Engine.create(allocator, .{}, TestObserver.observer(&context));
                defer self.destroy();
                try openTestStream(self);
                const id: StreamId = @fromBackingInt(1);
                try std.testing.expectError(error.InvalidHeaders, self.respondWithTrailers(id, 200, &.{}, "body", &.{.{ .name = "content-length", .value = "4" }}));
                try self.checkDispatchable(id);
                var value = [_]u8{ 'o', 'k' };
                try self.respondWithTrailers(id, 200, &.{}, "body", &.{.{ .name = "x-final", .value = &value }});
                value[0] = 'X';
                try std.testing.expectEqualStrings("ok", self.find(1).?.final_fields[0].value);
                if (ending == 2) continue;
                if (ending == 1) try self.receive("\x00\x00\x04\x03\x00\x00\x00\x00\x01\x00\x00\x00\x08");
                var completed = false;
                while (true) {
                    const bytes = try self.output();
                    if (bytes.len == 0) break;
                    if (bytes[3] == 0) try std.testing.expect(bytes[4] & 1 == 0);
                    if (bytes[3] == 1 and bytes[4] & 1 != 0) completed = true;
                    try self.consumeOutput(bytes.len);
                }
                try std.testing.expectEqual(ending == 0, completed);
                try std.testing.expectEqual(@as(usize, 0), self.activeStreams());
            }
        }
    }.run, .{});
}

test "finite trailers reject bodyless statuses before committing initial headers" {
    for ([_]u16{ 204, 205, 304 }) |status| {
        var context: u8 = 0;
        const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
        defer self.destroy();
        try openTestStream(self);
        const id: StreamId = @fromBackingInt(1);
        try std.testing.expectError(error.InvalidState, self.respondWithTrailers(id, status, &.{}, "", &.{.{ .name = "x-final", .value = "done" }}));
        try self.checkDispatchable(id);
        try self.respond(id, status, &.{}, "");
    }
}

test "response completion follows the last CONTINUATION byte exactly once" {
    const Context = struct {
        sent: usize = 0,
        fn responseSent(ptr: *anyopaque, id: StreamId) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(@backingInt(id) == 1);
            self.sent += 1;
        }
    };
    var context = Context{};
    var observer = TestObserver.observer(&context);
    observer.response_sent = Context.responseSent;
    const self = try Engine.create(std.testing.allocator, .{ .header_bytes = 65536 }, observer);
    defer self.destroy();
    try openTestStream(self);
    // Incompressible enough to require HEADERS plus CONTINUATION, without
    // relying on a particular HPACK table layout or encoded byte count.
    var value: [32768]u8 = undefined;
    var random: u32 = 42;
    for (&value) |*byte| {
        random = random *% 1664525 +% 1013904223;
        byte.* = @intCast(33 + (random >> 16) % 93);
    }
    try self.respond(@fromBackingInt(1), 200, &.{.{ .name = "x-large", .value = &value }}, "");
    var continuations: usize = 0;
    while (true) {
        const bytes = try self.output();
        try std.testing.expect(bytes.len >= 9);
        try std.testing.expectEqual(@as(usize, 0), context.sent);
        if (bytes[3] == c.NGHTTP2_CONTINUATION) continuations += 1;
        if (self.pending_response_end != null) {
            try std.testing.expectEqual(@as(u8, c.NGHTTP2_CONTINUATION), bytes[3]);
            try std.testing.expect(bytes[4] & c.NGHTTP2_FLAG_END_HEADERS != 0);
            try self.consumeOutput(0);
            try self.consumeOutput(bytes.len - 1);
            try std.testing.expectEqual(@as(usize, 0), context.sent);
            try self.consumeOutput(1);
            break;
        }
        try self.consumeOutput(bytes.len);
    }
    try std.testing.expect(continuations > 0);
    try std.testing.expectEqual(@as(usize, 1), context.sent);
    try self.consumeOutput(0);
    while (true) {
        const bytes = try self.output();
        if (bytes.len == 0) break;
        try self.consumeOutput(bytes.len);
    }
    try std.testing.expectEqual(@as(usize, 1), context.sent);
}

fn drainTestOutput(self: *Engine) !void {
    while (true) {
        const bytes = try self.output();
        if (bytes.len == 0) break;
        try self.consumeOutput(bytes.len);
    }
}

test "streaming chunks bound retained memory and preserve partial output before completion" {
    for ([_]usize{ 15, 16, 17 }) |size| {
        var context: u8 = 0;
        const self = try Engine.create(std.testing.allocator, .{ .stream_chunk_bytes = 16, .response_bytes = 1 }, TestObserver.observer(&context));
        defer self.destroy();
        try openTestStream(self);
        const id: StreamId = @fromBackingInt(@intCast(1));
        try self.beginStreamingResponse(id, 200, &.{});
        try std.testing.expectError(error.InvalidState, self.beginStreamingResponse(id, 200, &.{}));
        try std.testing.expect(!try self.writeStreamingResponse(id, "early"));
        try drainTestOutput(self);
        try std.testing.expect(try self.writeStreamingResponse(id, ""));
        try std.testing.expectEqual(@as(usize, 0), (try self.output()).len);
        const payload = @as([17]u8, @splat(42));
        if (size == 17) {
            try std.testing.expectError(error.LimitExceeded, self.writeStreamingResponse(id, &payload));
            continue;
        }
        // More total output than the finite cap, without retaining prior chunks.
        for (0..3) |_| {
            var caller_bytes = payload;
            try std.testing.expect(try self.writeStreamingResponse(id, caller_bytes[0..size]));
            @memset(&caller_bytes, 0);
            try std.testing.expect(!try self.writeStreamingResponse(id, "next"));
            try std.testing.expectError(error.InvalidState, self.finishResponse(id, &.{}));
            const data = try self.output();
            try std.testing.expectEqual(@as(usize, 9) + size, data.len);
            try std.testing.expectEqual(@as(u8, c.NGHTTP2_DATA), data[3]);
            try std.testing.expectEqualSlices(u8, payload[0..size], data[9..]);
            try std.testing.expectEqual(@as(u8, 0), data[4] & c.NGHTTP2_FLAG_END_STREAM);
            try std.testing.expect(self.find(1).?.response == null);
            try self.consumeOutput(1);
            try std.testing.expect(!try self.writeStreamingResponse(id, "next"));
            try std.testing.expectError(error.InvalidState, self.finishResponse(id, &.{}));
            try std.testing.expectEqualSlices(u8, data[1..], try self.output());
            try self.consumeOutput(data.len - 1);
        }
        try self.finishResponse(id, &.{.{ .name = "x-result", .value = "done" }});
        try std.testing.expectError(error.InvalidState, self.writeStreamingResponse(id, ""));
        try std.testing.expectError(error.InvalidState, self.finishResponse(id, &.{}));
        try drainTestOutput(self);
    }
}

test "sized streaming counts only admitted bytes and requires the declared length at finish" {
    var context: u8 = 0;
    const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
    defer self.destroy();
    try openTestStream(self);
    const id: StreamId = @fromBackingInt(@intCast(1));
    const fields = [_]Header{.{ .name = "content-length", .value = "2" }};
    try std.testing.expectError(error.InvalidHeaders, self.beginSizedStreamingResponse(id, 200, &.{}, 2));
    try std.testing.expectError(error.InvalidHeaders, self.beginSizedStreamingResponse(id, 200, &fields, 1));
    try self.beginSizedStreamingResponse(id, 200, &fields, 2);
    try std.testing.expect(!try self.writeStreamingResponse(id, "ab"));
    try drainTestOutput(self);
    try std.testing.expect(try self.writeStreamingResponse(id, "a"));
    try drainTestOutput(self);
    try std.testing.expectError(error.InvalidState, self.finishResponse(id, &.{}));
    try std.testing.expectError(error.InvalidState, self.writeStreamingResponse(id, "bc"));
    try std.testing.expect(try self.writeStreamingResponse(id, "b"));
    try drainTestOutput(self);
    try self.finishResponse(id, &.{});
    try drainTestOutput(self);
}

test "streaming zero credit permits terminal headers but reset releases queued data" {
    for ([_]bool{ false, true }) |queued| {
        var context: u8 = 0;
        const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
        defer self.destroy();
        try openTestStream(self);
        // SETTINGS_INITIAL_WINDOW_SIZE = 0.
        try self.receive("\x00\x00\x06\x04\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00");
        const id: StreamId = @fromBackingInt(@intCast(1));
        try self.beginStreamingResponse(id, 200, &.{});
        try drainTestOutput(self);
        if (queued) {
            try std.testing.expect(try self.writeStreamingResponse(id, "blocked"));
            try std.testing.expectEqual(@as(usize, 0), (try self.output()).len);
            try std.testing.expect(!try self.writeStreamingResponse(id, "next"));
            try self.receive("\x00\x00\x04\x03\x00\x00\x00\x00\x01\x00\x00\x00\x08");
            try std.testing.expect(self.find(1) == null);
            try std.testing.expectError(error.Closed, self.writeStreamingResponse(id, "next"));
        } else {
            try self.finishResponse(id, &.{});
            try drainTestOutput(self);
            try std.testing.expectEqual(@as(usize, 0), self.activeStreams());
        }
    }
}

test "streaming allocation failures release copies and allow failed chunk admission retry" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var context: u8 = 0;
            const self = try Engine.create(allocator, .{}, TestObserver.observer(&context));
            defer self.destroy();
            try openTestStream(self);
            const id: StreamId = @fromBackingInt(@intCast(1));
            try self.beginStreamingResponse(id, 200, &.{});
            try drainTestOutput(self);
            try std.testing.expect(try self.writeStreamingResponse(id, "chunk"));
            try drainTestOutput(self);
            try self.finishResponse(id, &.{.{ .name = "x-result", .value = "done" }});
            try drainTestOutput(self);
        }
    }.run, .{});
    var context: u8 = 0;
    const self = try Engine.create(std.testing.allocator, .{}, TestObserver.observer(&context));
    defer self.destroy();
    try openTestStream(self);
    const id: StreamId = @fromBackingInt(@intCast(1));
    try std.testing.expectError(error.InvalidHeaders, self.beginStreamingResponse(id, 200, &.{.{ .name = "content-length", .value = "0" }}));
    try std.testing.expectError(error.InvalidState, self.beginStreamingResponse(id, 204, &.{}));
    try self.beginStreamingResponse(id, 200, &.{});
    try drainTestOutput(self);
    const limit = self.memory.limit;
    self.memory.limit = self.memory.used;
    try std.testing.expectError(error.OutOfMemory, self.writeStreamingResponse(id, "chunk"));
    try std.testing.expect(self.find(1).?.response == null);
    self.memory.limit = limit;
    try std.testing.expect(try self.writeStreamingResponse(id, "chunk"));
    try self.cancel(id);
    try drainTestOutput(self);
}

test "streaming provider spans frames and connection credit without growing retained chunks" {
    var context: u8 = 0;
    const self = try Engine.create(std.testing.allocator, .{ .stream_chunk_bytes = 65536 }, TestObserver.observer(&context));
    defer self.destroy();
    try openTestStream(self);
    // Stream credit exceeds the default connection window.
    try self.receive("\x00\x00\x06\x04\x00\x00\x00\x00\x00\x00\x04\x00\x02\x00\x00");
    const id: StreamId = @fromBackingInt(@intCast(1));
    try self.beginStreamingResponse(id, 200, &.{});
    try drainTestOutput(self);
    const payload: [65536]u8 = @splat(42);
    try std.testing.expect(try self.writeStreamingResponse(id, &payload));
    var sent: usize = 0;
    while (true) {
        const bytes = try self.output();
        if (bytes.len == 0) break;
        try std.testing.expectEqual(@as(u8, c.NGHTTP2_DATA), bytes[3]);
        sent += bytes.len - 9;
        try self.consumeOutput(bytes.len);
    }
    try std.testing.expectEqual(@as(usize, 65535), sent);
    try std.testing.expect(self.find(1).?.response != null);
    try std.testing.expect(!try self.writeStreamingResponse(id, "next"));
    try std.testing.expectError(error.InvalidState, self.finishResponse(id, &.{}));
    // One byte of connection credit releases the final byte and its owned chunk.
    try self.receive("\x00\x00\x04\x08\x00\x00\x00\x00\x00\x00\x00\x00\x01");
    const last = try self.output();
    try std.testing.expectEqual(@as(usize, 10), last.len);
    try std.testing.expect(self.find(1).?.response == null);
    try self.consumeOutput(last.len);
    try self.finishResponse(id, &.{});
    try drainTestOutput(self);
    try std.testing.expectEqual(@as(usize, 0), self.activeStreams());
}

const InputTest = struct {
    const id: StreamId = @fromBackingInt(@as(i32, 1));
    const Credit = struct { connection: usize = 0, stream: usize = 0, goaway: ?u32 = null };

    fn frame(self: *Engine, kind: u8, flags: u8, stream: u8, payload: []const u8) !void {
        const header = [_]u8{ @intCast(payload.len >> 16), @truncate(payload.len >> 8), @truncate(payload.len), kind, flags, 0, 0, 0, stream };
        try self.receive(&header);
        try self.receive(payload);
    }

    fn flush(self: *Engine) !Credit {
        var credit = Credit{};
        while (true) {
            const bytes = try self.output();
            if (bytes.len == 0) break;
            if (bytes[3] == c.NGHTTP2_GOAWAY) credit.goaway = std.mem.readInt(u32, bytes[13..17], std.builtin.Endian.big);
            if (bytes[3] == c.NGHTTP2_WINDOW_UPDATE) {
                const increment = std.mem.readInt(u32, bytes[9..13], std.builtin.Endian.big);
                if (bytes[8] == 0) credit.connection += increment else credit.stream += increment;
            }
            try self.consumeOutput(bytes.len);
        }
        return credit;
    }

    fn start(self: *Engine, acknowledge: bool) !void {
        try self.receive("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
        try frame(self, c.NGHTTP2_SETTINGS, 0, 0, "");
        _ = try flush(self);
        if (acknowledge) try frame(self, c.NGHTTP2_SETTINGS, c.NGHTTP2_FLAG_ACK, 0, "");
        try open(self, 1);
    }

    fn open(self: *Engine, stream: u8) !void {
        try frame(self, c.NGHTTP2_HEADERS, c.NGHTTP2_FLAG_END_HEADERS, stream, "\x83\x86\x84\x01\x09localhost");
    }
};

test "incremental input copies fragmented callbacks, drains before EOF and leaves output open" {
    var context: u8 = 0;
    var input_memory = Memory{ .backing = std.testing.allocator, .limit = 128 * 1024 };
    const self = try Engine.createIncremental(std.testing.allocator, .{ .body_bytes = 1 }, TestObserver.observer(&context), &input_memory);
    defer self.destroy();
    try InputTest.start(self, true);
    var destination: [3]u8 = undefined;
    try std.testing.expectEqual(ReadResult.pending, try self.readRequest(InputTest.id, &destination));
    try std.testing.expectError(error.InvalidState, self.readRequest(InputTest.id, &.{}));
    // Each receive splits a DATA payload; no callback storage may escape.
    try self.receive("\x00\x00\x05\x00\x01\x00\x00\x00\x01");
    var part = "ab".*;
    try self.receive(&part);
    @memset(&part, 'x');
    try std.testing.expectEqual(@as(usize, 2), (try self.readRequest(InputTest.id, &destination)).data);
    try std.testing.expectEqualStrings("ab", destination[0..2]);
    try std.testing.expectEqual(@as(usize, 0), input_memory.used);
    try std.testing.expectEqual(ReadResult.pending, try self.readRequest(InputTest.id, &destination));
    try self.receive("cde");
    try std.testing.expectEqual(@as(usize, 3), (try self.readRequest(InputTest.id, &destination)).data);
    try std.testing.expectEqualStrings("cde", &destination);
    for (0..2) |_| try std.testing.expectEqual(ReadResult.end, try self.readRequest(InputTest.id, &destination));
    try self.respond(InputTest.id, 200, &.{}, "still open");
    _ = try InputTest.flush(self);
    try std.testing.expectError(error.Closed, self.readRequest(InputTest.id, &destination));
    try std.testing.expectEqual(@as(usize, 0), input_memory.used);
}

test "incremental queue returns credit only on consumption and cumulative input exceeds finite cap" {
    var context: u8 = 0;
    var input_memory = Memory{ .backing = std.testing.allocator, .limit = 128 * 1024 };
    const self = try Engine.createIncremental(std.testing.allocator, .{ .body_bytes = 1 }, TestObserver.observer(&context), &input_memory);
    defer self.destroy();
    try InputTest.start(self, true);
    const payload: [16384]u8 = @splat('a');
    var destination: [16384]u8 = undefined;
    var connection_credit: usize = 0;
    for (0..8) |_| {
        try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, &payload);
        const queued = try InputTest.flush(self);
        try std.testing.expectEqual(@as(usize, 0), queued.stream);
        try std.testing.expectEqual(@as(usize, 0), queued.connection);
        try std.testing.expectEqual(@as(usize, 16384), self.find(1).?.input.items.len);
        // Immediately below the half-window threshold, then exactly at it.
        try std.testing.expectEqual(@as(usize, 8191), (try self.readRequest(InputTest.id, destination[0..8191])).data);
        try std.testing.expectEqual(@as(usize, 0), (try InputTest.flush(self)).stream);
        try std.testing.expectEqual(@as(usize, 1), (try self.readRequest(InputTest.id, destination[0..1])).data);
        const half = try InputTest.flush(self);
        try std.testing.expectEqual(@as(usize, 8192), half.stream);
        connection_credit += half.connection;
        try std.testing.expectEqual(@as(usize, 8192), (try self.readRequest(InputTest.id, &destination)).data);
        const rest = try InputTest.flush(self);
        try std.testing.expectEqual(@as(usize, 8192), rest.stream);
        connection_credit += rest.connection;
        try std.testing.expectEqual(@as(usize, 0), input_memory.used);
    }
    try std.testing.expectEqual(@as(usize, 131072), connection_credit);
}

test "pre-SETTINGS flight uses default window and shrinks without discarding buffered input" {
    var context: u8 = 0;
    var input_memory = Memory{ .backing = std.testing.allocator, .limit = 128 * 1024 };
    const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
    defer self.destroy();
    try InputTest.start(self, false);
    const payload: [16384]u8 = @splat('p');
    for (0..3) |_| try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, &payload);
    try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, payload[0..16383]);
    try std.testing.expectEqual(@as(usize, 65535), self.find(1).?.input.items.len);
    try InputTest.frame(self, c.NGHTTP2_SETTINGS, c.NGHTTP2_FLAG_ACK, 0, "");
    var destination: [65535]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 65535), (try self.readRequest(InputTest.id, &destination)).data);
    try std.testing.expectEqual(@as(usize, 0), input_memory.used);
    const credit = try InputTest.flush(self);
    try std.testing.expectEqual(@as(usize, 65535), credit.connection);
    try InputTest.frame(self, c.NGHTTP2_DATA, c.NGHTTP2_FLAG_END_STREAM, 1, &payload);
    try std.testing.expectEqual(@as(usize, 16384), (try self.readRequest(InputTest.id, &destination)).data);
    try std.testing.expectEqual(ReadResult.end, try self.readRequest(InputTest.id, &destination));
}

test "reset and cancellation recover connection credit once without restoring abandoned streams" {
    for ([_]bool{ false, true }) |peer_reset| {
        var context: u8 = 0;
        var input_memory = Memory{ .backing = std.testing.allocator, .limit = 128 * 1024 };
        const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
        defer self.destroy();
        try InputTest.start(self, true);
        const payload: [16384]u8 = @splat('r');
        var recovered: usize = 0;
        for (0..8) |index| {
            const stream: u8 = @intCast(1 + index * 2);
            if (index != 0) try InputTest.open(self, stream);
            try InputTest.frame(self, c.NGHTTP2_DATA, 0, stream, &payload);
            if (peer_reset) {
                try InputTest.frame(self, c.NGHTTP2_RST_STREAM, 0, stream, "\x00\x00\x00\x08");
            } else {
                try self.cancel(@fromBackingInt(@as(i32, stream)));
            }
            try std.testing.expectEqual(@as(usize, 0), input_memory.used);
            const credit = try InputTest.flush(self);
            try std.testing.expectEqual(@as(usize, 0), credit.stream);
            recovered += credit.connection;
            try std.testing.expectEqual(@as(usize, 0), (try InputTest.flush(self)).connection);
        }
        try std.testing.expectEqual(@as(usize, 131072), recovered);
        try InputTest.open(self, 17);
        try InputTest.frame(self, c.NGHTTP2_DATA, c.NGHTTP2_FLAG_END_STREAM, 17, "peer");
        var destination: [4]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 4), (try self.readRequest(@fromBackingInt(@as(i32, 17)), &destination)).data);
        try std.testing.expectEqualStrings("peer", &destination);
    }
}

test "padding credit is returned by nghttp2 exactly once independently of unread payload" {
    var context: u8 = 0;
    var input_memory = Memory{ .backing = std.testing.allocator, .limit = 128 * 1024 };
    const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
    defer self.destroy();
    try InputTest.start(self, true);
    // 256 frames: one data byte and 255 bytes of flow-controlled padding each.
    var payload: [256]u8 = @splat(0);
    payload[0] = 254;
    payload[1] = 'p';
    var credited = InputTest.Credit{};
    for (0..256) |_| {
        // Split the length byte, data and padding across receives too.
        try self.receive("\x00\x01\x00\x00\x08\x00\x00\x00\x01");
        try self.receive(payload[0..1]);
        try self.receive(payload[1..2]);
        try self.receive(payload[2..]);
        const credit = try InputTest.flush(self);
        credited.connection += credit.connection;
        credited.stream += credit.stream;
    }
    try std.testing.expectEqual(@as(usize, 256), self.find(1).?.input.items.len);
    var destination: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 256), (try self.readRequest(InputTest.id, &destination)).data);
    const credit = try InputTest.flush(self);
    credited.connection += credit.connection;
    credited.stream += credit.stream;
    // nghttp2 batches credits; the unadvertised residue stays below half a window.
    try std.testing.expect(credited.connection <= 65536 and credited.connection > 32768);
    try std.testing.expect(credited.stream <= 65536 and credited.stream > 57344);
    try std.testing.expectEqual(@as(i32, @intCast(credited.connection - 1)), c.nghttp2_session_get_local_window_size(self.session));
}

test "stalled input does not stop peer progress and aggregate budget failure is stream local" {
    var context: u8 = 0;
    var worker = @import("../allocator/http2_memory.zig").Budget{ .backing = std.testing.allocator, .limit = 32768 + 32 };
    var input_memory = Memory{ .backing = worker.allocator(), .limit = 32768 + 32 };
    const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
    defer self.destroy();
    try InputTest.start(self, true);
    const payload: [16384]u8 = @splat('s');
    try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, &payload);
    try InputTest.open(self, 3);
    try InputTest.frame(self, c.NGHTTP2_DATA, 0, 3, &payload);
    const retained = input_memory.used;
    try std.testing.expectEqual(input_memory.limit, retained);
    try InputTest.open(self, 5);
    // No aggregate capacity remains even though this stream has receive credit.
    try InputTest.frame(self, c.NGHTTP2_DATA, 0, 5, "x");
    try std.testing.expect(self.find(5).?.rejected);
    try std.testing.expectEqual(retained, input_memory.used);
    _ = try InputTest.flush(self);
    var destination: [16384]u8 = undefined;
    // Keep stream 1 completely stalled while stream 3 consumes multiple windows.
    var consumed: usize = 0;
    for (0..8) |index| {
        if (index != 0) try InputTest.frame(self, c.NGHTTP2_DATA, 0, 3, &payload);
        consumed += (try self.readRequest(@fromBackingInt(@as(i32, 3)), &destination)).data;
        _ = try InputTest.flush(self);
    }
    try std.testing.expectEqual(@as(usize, 131072), consumed);
    try std.testing.expectEqual(@as(usize, 16384), self.find(1).?.input.items.len);
    try self.cancel(InputTest.id);
    try self.cancel(@fromBackingInt(@as(i32, 3)));
    _ = try InputTest.flush(self);
    try std.testing.expectEqual(@as(usize, 0), input_memory.used);
    try std.testing.expectEqual(@as(usize, 0), worker.used.load(std.builtin.AtomicOrder.monotonic));
}

test "input allocation boundaries and backing failure discard current DATA and retain no queue" {
    for ([_]usize{ 16399, 16400, 16401 }) |limit| {
        var context: u8 = 0;
        var input_memory = Memory{ .backing = std.testing.allocator, .limit = limit };
        const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
        try InputTest.start(self, true);
        try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, "x");
        try std.testing.expectEqual(limit < 16400, self.find(1).?.rejected);
        self.destroy();
        try std.testing.expectEqual(@as(usize, 0), input_memory.used);
    }
    var context: u8 = 0;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var input_memory = Memory{ .backing = failing.allocator(), .limit = 128 * 1024 };
    const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
    defer self.destroy();
    try InputTest.start(self, true);
    var total: usize = 0;
    const payload: [16384]u8 = @splat('f');
    for (0..4) |index| {
        const stream: u8 = @intCast(1 + index * 2);
        if (index != 0) try InputTest.open(self, stream);
        try InputTest.frame(self, c.NGHTTP2_DATA, 0, stream, &payload);
        try std.testing.expect(self.find(stream).?.rejected);
        total += (try InputTest.flush(self)).connection;
    }
    try std.testing.expectEqual(@as(usize, 65536), total);
    try std.testing.expectEqual(@as(usize, 0), input_memory.used);
}

test "incremental input window boundaries reject excess wire credit without allocating excess input" {
    var context: u8 = 0;
    var input_memory = Memory{ .backing = std.testing.allocator, .limit = 128 * 1024 };
    for ([_]u32{ 0, 1, 65534, 65535, 65536 }) |limit| {
        const result = Engine.createIncremental(std.testing.allocator, .{ .input_queue_bytes = limit }, TestObserver.observer(&context), &input_memory);
        if (limit == 0 or limit == 65536) {
            try std.testing.expectError(error.LimitExceeded, result);
        } else (try result).destroy();
    }
    for ([_]usize{ 16383, 16384, 16385 }) |size| {
        const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
        defer self.destroy();
        try InputTest.start(self, true);
        const payload: [16384]u8 = @splat('b');
        try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, payload[0..@min(size, payload.len)]);
        if (size > payload.len) try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, "x");
        const output = try InputTest.flush(self);
        if (size > payload.len) {
            try std.testing.expectEqual(@as(?u32, c.NGHTTP2_FLOW_CONTROL_ERROR), output.goaway);
            try std.testing.expectEqual(payload.len, self.find(1).?.input.items.len);
            continue;
        }
        try std.testing.expectEqual(@as(?u32, null), output.goaway);
        try std.testing.expectEqual(size, self.find(1).?.input.items.len);
        try InputTest.open(self, 3);
        try InputTest.frame(self, c.NGHTTP2_DATA, c.NGHTTP2_FLAG_END_STREAM, 3, "ok");
        var destination: [2]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 2), (try self.readRequest(@fromBackingInt(@as(i32, 3)), &destination)).data);
        try std.testing.expectEqualStrings("ok", &destination);
    }
}

test "receive-credit allocation failure closes the session without retrying consumed input" {
    var context: u8 = 0;
    var input_memory = Memory{ .backing = std.testing.allocator, .limit = 128 * 1024 };
    const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
    defer self.destroy();
    try InputTest.start(self, true);
    const payload: [16384]u8 = @splat('c');
    try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, &payload);
    self.memory.limit = self.memory.used;
    var destination: [16384]u8 = undefined;
    try std.testing.expectError(error.OutOfMemory, self.readRequest(InputTest.id, &destination));
    try std.testing.expectEqual(@as(usize, 0), input_memory.used);
    try std.testing.expectError(error.Closed, self.readRequest(InputTest.id, &destination));
    try std.testing.expectError(error.Closed, self.receive(""));
    try std.testing.expectError(error.Closed, self.output());
}

test "cancelling within a fragmented DATA frame credits both queued and later ignored bytes once" {
    var context: u8 = 0;
    var input_memory = Memory{ .backing = std.testing.allocator, .limit = 128 * 1024 };
    const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
    defer self.destroy();
    try InputTest.start(self, true);
    const payload: [8192]u8 = @splat('d');
    var credit: usize = 0;
    for (0..4) |index| {
        const stream: u8 = @intCast(1 + 2 * index);
        if (index != 0) try InputTest.open(self, stream);
        try self.receive(&.{ 0, 64, 0, 0, 0, 0, 0, 0, stream });
        try self.receive(&payload);
        try self.cancel(@fromBackingInt(@as(i32, stream)));
        credit += (try InputTest.flush(self)).connection;
        try self.receive(&payload);
        credit += (try InputTest.flush(self)).connection;
        try std.testing.expectEqual(@as(usize, 0), input_memory.used);
    }
    try std.testing.expectEqual(@as(usize, 65536), credit);
}

test "early input disposal frees queues and enforces cumulative drain boundaries" {
    for ([_]usize{ 3, 4, 5 }) |size| {
        var context: u8 = 0;
        var input_memory = Memory{ .backing = std.testing.allocator, .limit = 128 * 1024 };
        const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
        defer self.destroy();
        try InputTest.start(self, true);
        try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, "abcde"[0..size]);
        try self.discardRequest(InputTest.id, 4);
        try std.testing.expectEqual(@as(usize, 0), input_memory.used);
        try std.testing.expectEqual(size > 4, self.find(1).?.rejected);
        try std.testing.expectError(error.Closed, self.requestReady(InputTest.id));
        var destination: [1]u8 = undefined;
        try std.testing.expectError(error.Closed, self.readRequest(InputTest.id, &destination));
        _ = try InputTest.flush(self);
        if (size > 4) continue;
        if (size < 4) try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, "d");
        try std.testing.expectEqual(@as(usize, 0), input_memory.used);
        try self.discardRequest(InputTest.id, 4);
        try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, "e");
        try std.testing.expect(self.find(1).?.rejected);
    }
    var context: u8 = 0;
    var input_memory = Memory{ .backing = std.testing.allocator, .limit = 128 * 1024 };
    const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
    defer self.destroy();
    try InputTest.start(self, true);
    const payload: [16384]u8 = @splat('d');
    try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, &payload);
    try self.respond(InputTest.id, 403, &.{}, "early");
    try self.discardRequest(InputTest.id, 65536);
    var total = try InputTest.flush(self);
    for (0..3) |_| {
        try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, &payload);
        const credit = try InputTest.flush(self);
        total.connection += credit.connection;
        total.stream += credit.stream;
        try std.testing.expectEqual(@as(usize, 0), input_memory.used);
    }
    try std.testing.expectEqual(@as(usize, 65536), total.connection);
    try std.testing.expectEqual(@as(usize, 65536), total.stream);
    try InputTest.frame(self, c.NGHTTP2_DATA, c.NGHTTP2_FLAG_END_STREAM, 1, "");
    try std.testing.expectEqual(@as(usize, 0), self.activeStreams());
}

test "streamed response closes unfinished input only after terminal consumption" {
    const InputEnd = enum { before_output, during_terminal, absent };
    for (std.enums.values(InputEnd)) |input_end| {
        var context: u8 = 0;
        var input_memory = Memory{ .backing = std.testing.allocator, .limit = 128 * 1024 };
        const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
        defer self.destroy();
        try InputTest.start(self, false);
        // Half the initial connection window makes discarded credit observable.
        const payload: [16384]u8 = @splat('q');
        for (0..2) |_| try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, &payload);
        if (input_end == InputEnd.before_output) try InputTest.frame(self, c.NGHTTP2_DATA, c.NGHTTP2_FLAG_END_STREAM, 1, "");
        try self.beginStreamingResponse(InputTest.id, 200, &.{});
        _ = try InputTest.flush(self);
        try std.testing.expect(try self.writeStreamingResponse(InputTest.id, "response"));
        _ = try InputTest.flush(self);
        try self.finishResponse(InputTest.id, &.{.{ .name = "x-result", .value = "done" }});
        const final = try self.output();
        try std.testing.expect(self.pending_response_end != null);
        try std.testing.expect(final.len > 1);
        try self.consumeOutput(0);
        try self.consumeOutput(final.len - 1);
        if (input_end != InputEnd.before_output) {
            try std.testing.expect(!self.find(1).?.rejected);
            try std.testing.expect(input_memory.used > 0);
        }
        if (input_end == InputEnd.during_terminal) try InputTest.frame(self, c.NGHTTP2_DATA, c.NGHTTP2_FLAG_END_STREAM, 1, "");
        try self.consumeOutput(1);
        try std.testing.expectEqual(@as(usize, 0), input_memory.used);
        var resets: usize = 0;
        var credit: usize = 0;
        while (true) {
            const frame = try self.output();
            if (frame.len == 0) break;
            if (frame[3] == c.NGHTTP2_RST_STREAM) {
                resets += 1;
                try std.testing.expectEqual(@as(u8, 1), frame[8]);
                try std.testing.expectEqual(@as(u32, c.NGHTTP2_NO_ERROR), std.mem.readInt(u32, frame[9..13], std.builtin.Endian.big));
            }
            if (frame[3] == c.NGHTTP2_WINDOW_UPDATE and frame[8] == 0) credit += std.mem.readInt(u32, frame[9..13], std.builtin.Endian.big);
            try self.consumeOutput(frame.len);
        }
        try std.testing.expectEqual(@as(usize, if (input_end == InputEnd.absent) 1 else 0), resets);
        try std.testing.expectEqual(@as(usize, 32768), credit);
        try std.testing.expectEqual(@as(usize, 0), self.activeStreams());
        // Late input for the closed stream cannot consume a peer's receive window.
        try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, &payload);
        try InputTest.open(self, 3);
        try InputTest.frame(self, c.NGHTTP2_DATA, c.NGHTTP2_FLAG_END_STREAM, 3, "peer");
        var bytes: [4]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 4), (try self.readRequest(@fromBackingInt(3), &bytes)).data);
        try std.testing.expectEqualStrings("peer", &bytes);
    }
}

test "failed response-first reset allocation fails the session and releases unread input" {
    var context: u8 = 0;
    var input_memory = Memory{ .backing = std.testing.allocator, .limit = 128 * 1024 };
    {
        const self = try Engine.createIncremental(std.testing.allocator, .{}, TestObserver.observer(&context), &input_memory);
        defer self.destroy();
        try InputTest.start(self, true);
        try InputTest.frame(self, c.NGHTTP2_DATA, 0, 1, "unread");
        try self.beginStreamingResponse(InputTest.id, 200, &.{});
        _ = try InputTest.flush(self);
        try self.finishResponse(InputTest.id, &.{});
        const final = try self.output();
        try std.testing.expect(self.pending_response_end != null);
        // The response is already serialized; the next allocation belongs to
        // its input-side reset. Failure cannot leave a usable half-open session.
        self.memory.limit = self.memory.used;
        try std.testing.expectError(error.OutOfMemory, self.consumeOutput(final.len));
        try std.testing.expect(self.failed);
        try std.testing.expectError(error.Closed, self.requestReady(InputTest.id));
    }
    try std.testing.expectEqual(@as(usize, 0), input_memory.used);
}
