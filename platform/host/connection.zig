const std = @import("std");
const raw_bytes = @import("raw_bytes.zig");
const blocking = @import("blocking.zig");
const gzip = @import("gzip.zig");
const fiber = @import("fiber.zig");
const http_date = @import("http1/date.zig");
const wall_time = @import("effect/time.zig");
const allocator_context = @import("allocator/context.zig");
const host_allocator_module = @import("allocator/host_allocator.zig");
const bridge = @import("bridge.zig");
const diagnostics = @import("diagnostics.zig");
const error_response = @import("http1/error_response.zig");
const expectation = @import("http1/expectation.zig");
const persistence = @import("http1/persistence.zig");
const net = @import("net.zig");
const runtime = @import("runtime.zig");
const request_reader = @import("connection/request_reader.zig");
const body_effect = @import("effect/body.zig");
const response_writer = @import("effect/response_writer.zig");
const http1_encoder = @import("http1/encoder.zig");
const http1_parser = @import("http1/parser.zig");
const request_debug = @import("request_debug.zig");
const request_id = @import("request_id.zig");
const access_log = @import("access_log.zig");

comptime {
    std.debug.assert(request_debug.maximum_headers <= bridge.maximum_response_extra_headers);
}

const Domain = host_allocator_module.Domain;
const HostAllocator = host_allocator_module.HostAllocator;

pub const Error = request_reader.Error ||
    persistence.Error ||
    bridge.RequestError ||
    bridge.ResponseEncodeError ||
    bridge.ResponseWriteError ||
    bridge.ResponseAdvanceError;

pub const Limits = struct {
    initial_request_timeout_milliseconds: u64 = 5_000,
    keep_alive_idle_timeout_milliseconds: u64 = 15_000,
    request_head_timeout_milliseconds: u64 = 5_000,
    request_body_timeout_milliseconds: u64 = 30_000,
    response_write_timeout_milliseconds: u64 = 30_000,
    /// A body read whole into memory, and a body read as a stream
    /// (`maxInt` for no limit); a route's `BodyLimit` layers change them
    ///.
    maximum_body_bytes: u64 = 2 * 1024 * 1024,
    maximum_streamed_body_bytes: u64 = std.math.maxInt(u64),
    unread_body_policy: UnreadBodyPolicy = UnreadBodyPolicy.buffered_only,
    unread_body_maximum_bytes: usize = 16 * 1024,
    unread_body_timeout_milliseconds: u64 = 5,
    /// Bodies handlers write at once (`Reply.stream`): past this many,
    /// a new one is answered 503.
    maximum_streams: usize = 64,
    /// How long a worker drains after SIGTERM before it cuts what is left
    ///.
    drain_timeout_milliseconds: u64 = 20_000,
    /// Admission. Requests waiting for the Roc thread: past this many
    /// the worker stops accepting, and a request that waited longer than
    /// the timeout is answered 503 without running. Requests the Roc thread
    /// has started and not finished (most of them waiting on a fiber): past
    /// this many, new ones are answered 503.
    maximum_queued_requests: usize = 1024,
    /// Connections one worker holds at once.
    maximum_connections: u32 = 4096,
    /// Bytes the worker's live requests may hold; null for
    /// `Server.MemoryLimit.Auto`, which the worker sizes once it knows how
    /// many workers run.
    request_memory_bytes: ?u64 = null,
    queue_timeout_milliseconds: u64 = 5_000,
    maximum_requests_in_progress: usize = 1024,
    /// Where request IDs come from.
    request_id_source: request_id.Source = request_id.Source.generate,
};

pub const UnreadBodyPolicy = enum {
    close,
    buffered_only,
    bounded_drain,
};

pub const Outcome = enum {
    reuse,
    close,
};

/// What a written body's guard needs from the connection: see
/// `fiber.StreamGuard`.
pub const ClientHooks = struct {
    context: *anyopaque,
    arm: *const fn (context: *anyopaque, target: *fiber.Fiber, serial: u64, ends_on_drain: bool) fiber.Stop,
    disarm: *const fn (context: *anyopaque) void,
    restore: *const fn (context: *anyopaque) void,
};

/// A body the handler writes as it goes: what its head needs, and
/// how far it got.
const Written = struct {
    version: persistence.HttpVersion,
    request_semantics: bridge.ResponseRequestSemantics,
    persistence: persistence.Decision,
    body_stream: ?*request_reader.BodyStream,
    /// The request body was closed when the head went out.
    body_closed: bool = false,
    state: State = State.not_started,
    /// Holds a place in `maximum_streams`.
    counted: bool = false,
    chunked: bool = false,
    transmit_body: bool = false,
    reuse: bool = false,
    body_bytes: u64 = 0,
    /// For a body of a known length: the bytes still to write. The
    /// connection closes when the body ends short of it.
    remaining: ?u64 = null,
    /// For a body sent gzip-compressed: each part is compressed and
    /// flushed on a blocking-work thread before it goes out, and the gzip
    /// stream ends before the body does.
    compressor: ?*gzip.Compressor = null,

    const State = enum {
        not_started,
        /// The host answered in its place (503, 500); no stream.
        answered,
        /// The head is out and the handler writes the body.
        writing,
        /// A write failed or timed out; the connection closes.
        failed,
    };
};

fn startWrittenThunk(context: *anyopaque, response: *const bridge.HttpResponse, keep_alive_milliseconds: u64, keep_alive_bytes: []const u8, ends_on_drain: bool, content_length: ?u64, gzip_body: bool) bool {
    const self: *Session = @ptrCast(@alignCast(context));
    return self.startWritten(response, keep_alive_milliseconds, keep_alive_bytes, ends_on_drain, content_length, gzip_body);
}

fn abortWrittenThunk(context: *anyopaque) void {
    const self: *Session = @ptrCast(@alignCast(context));
    _ = self.failWritten();
}

/// A step of a written body's compression, on a blocking-work thread.
const CompressStep = struct {
    job: blocking.Job = .{ .run = run },
    compressor: *gzip.Compressor,
    input: []const u8,
    /// Ends the gzip stream rather than flushing.
    final: bool,
    ok: bool = false,

    fn run(job: *blocking.Job) void {
        const self: *CompressStep = @fieldParentPtr("job", job);
        self.compressor.write(self.input) catch return;
        if (self.final) {
            self.compressor.finish() catch return;
        } else {
            self.compressor.flush() catch return;
        }
        self.ok = true;
    }
};

fn writeWrittenThunk(context: *anyopaque, bytes: []const u8) bool {
    const self: *Session = @ptrCast(@alignCast(context));
    return self.writeWritten(bytes);
}

const WriteContext = struct {
    socket: net.Socket,
    deadline: net.Deadline,
    session: ?*Session = null,
};

/// Response bytes the socket did not accept at once. The event loop finishes
/// writing them so a slow reader does not hold the Roc thread.
pub const PendingOutput = struct {
    /// The whole allocation, for freeing; it may be longer than `length`.
    allocation: []u8,
    length: usize,
    deadline: net.Deadline,
};

const pending_allocator = std.heap.smp_allocator;

pub const continue_response = request_reader.continue_response;

pub const BodyPrefetch = enum {
    /// The loop did not wait for the body: the request has none, the head
    /// is rejected, which the Roc thread answers without reading the body,
    /// or the body is larger than the loop receives, which the handler's
    /// reads wait for.
    not_read,
    /// The whole body is in the seeded bytes; a chunked body is decoded, see
    /// `Prefetch.decoded_body_length`.
    complete,
    /// The start of a larger chunked body is decoded in the seeded bytes,
    /// see `Prefetch.predecoded`; the handler's reads go on.
    partial,
    /// The body did not arrive before `body_deadline`.
    timed_out,
    /// The client closed before sending the whole body.
    closed,
    /// The chunked framing is invalid: 400.
    invalid,
    /// The chunked framing is out of proportion to the data: 413.
    too_large,
    /// The loop's buffer budget for bodies is used up: 503.
    over_budget,
};

/// What the event loop did with a request before handing it over.
pub const Prefetch = struct {
    /// The absolute limit for the head, started at its first byte.
    head_deadline: ?net.Deadline = null,
    /// The absolute limit for the body, started when the head was complete.
    body_deadline: ?net.Deadline = null,
    body: BodyPrefetch = BodyPrefetch.not_read,
    /// For a chunked body the loop decoded: its length. The decoded bytes
    /// follow the head in place of the chunked framing.
    decoded_body_length: ?usize = null,
    /// For a chunked body the loop decoded the start of: how far it got.
    predecoded: ?request_reader.Predecoded = null,
};

/// What the host decides about a request head before running any Roc code.
pub const Screen = union(enum) {
    /// Answer with this error and close.
    reject: error_response.Kind,
    proceed: Proceed,

    pub const Proceed = struct {
        persistence: persistence.Decision,
        /// HTTP/1.1 `Expect: 100-continue` on a request with a body.
        send_continue: bool,
    };
};

/// Checks a parsed head in the order the host answers problems: the
/// `Connection` field (400), the method and target (501 or 400), then
/// `Expect` (417). Pure, so the event loop can reach the same decision
/// before it waits for a body.
pub fn screenHead(
    request_line: http1_parser.RequestLine,
    headers: []const http1_parser.Header,
    head_bytes: []const u8,
    framing: http1_parser.BodyFraming,
) Screen {
    const decision = persistence.decideParsed(request_line.version, headers, head_bytes) catch
        return Screen{ .reject = error_response.Kind.bad_request };
    bridge.validateParsedRequestHead(head_bytes, request_line) catch |validation_error|
        return Screen{ .reject = switch (validation_error) {
            error.UnsupportedMethod => error_response.Kind.not_implemented,
            error.InvalidSpan,
            error.InvalidTarget,
            => error_response.Kind.bad_request,
        } };
    const send_continue = switch (expectation.decide(request_line.version, headers, head_bytes, framing)) {
        expectation.Decision.none => false,
        expectation.Decision.send_continue => true,
        expectation.Decision.unsupported => return Screen{ .reject = error_response.Kind.expectation_failed },
    };
    return Screen{ .proceed = .{ .persistence = decision, .send_continue = send_continue } };
}

pub const Session = struct {
    accepted: net.AcceptedSocket,
    reader: request_reader.Reader = .{},
    limits: Limits,
    completed_requests: usize = 0,
    /// When set, a buffered (non-streaming) response is written without
    /// waiting; bytes the socket does not accept are kept for the caller.
    defer_buffered_writes: bool = false,
    pending_buffer: []u8 = &.{},
    pending_length: usize = 0,
    pending_deadline: net.Deadline = undefined,
    /// The `dbg` headers of the response being encoded. Kept here: on the
    /// stack, a safe build would fill the array for every response.
    debug_headers: [request_debug.maximum_headers]http1_encoder.Header = undefined,
    head_scratch: bridge.HeadScratch = .{},
    /// The body the handler writes as it goes, while its Roc code
    /// runs.
    written: ?Written = null,
    /// The connection's side of a written body's guard, which the
    /// caller sets when the session runs on a request fiber.
    client_hooks: ?ClientHooks = null,
    /// While a written body is on: what the request fiber's waits also do.
    guard: fiber.StreamGuard = undefined,
    /// The written body's keep-alive bytes, a `raw_bytes` copy.
    keep_alive_bytes: []u8 = &.{},
    /// The process's written bodies. A body takes its place in the
    /// count before it starts, so threads that start at once stay within
    /// the limit.
    active_streams: ?*std.atomic.Value(usize) = null,
    /// Set by the event loop when the worker drains: a response then says
    /// `Connection: close` and the connection is not reused. Read after the
    /// handler returns, like `active_streams`.
    draining: ?*const std.atomic.Value(bool) = null,
    /// The current request's access log entry, filled in while the
    /// access log is on. `answered` says a response was sent or begun, so a
    /// line is due.
    access: access_log.Entry = .{},
    answered: bool = false,
    date_cache: http_date.Cache = .{},
    /// The second of the last stream-limit warning; see `warnStreamLimit`.
    stream_limit_warned_second: ?i64 = null,

    pub fn initWithLimits(
        accepted: net.AcceptedSocket,
        limits: Limits,
    ) Session {
        return .{
            .accepted = accepted,
            .limits = limits,
        };
    }

    /// Handles one request whose first bytes were read by the event loop and
    /// seeded into the reader. `prefetch` says what the loop already did; an
    /// expired head or body deadline answers 408 without waiting again.
    pub fn handleDispatched(
        self: *Session,
        host_allocator: *HostAllocator,
        generation: usize,
        model_root: *bridge.ModelRoot,
        roc_host: *bridge.RocHost,
        prefetch: Prefetch,
    ) Error!?Outcome {
        self.answered = false;
        if (access_log.enabled()) self.access.reset();
        const first_byte_timeout = if (self.completed_requests == 0)
            self.limits.initial_request_timeout_milliseconds
        else
            self.limits.keep_alive_idle_timeout_milliseconds;
        const head_deadline = prefetch.head_deadline;
        const parsed_head = self.reader.nextHead(
            self.accepted.socket,
            .{
                .first_byte_milliseconds = first_byte_timeout,
                .head_milliseconds = self.limits.request_head_timeout_milliseconds,
                .head_deadline = head_deadline,
            },
        ) catch |err| return self.handleReadError(err);
        const head = parsed_head orelse return null;
        const head_bytes = self.reader.headBytes(head);
        const id = request_id.decide(self.limits.request_id_source, head.headers, head_bytes);
        if (access_log.enabled()) {
            self.access.method.set(head.request_line.method.slice(head_bytes));
            const target = head.request_line.target.slice(head_bytes);
            self.access.path.set(target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len]);
            self.access.request_id = id;
        }
        const request_semantics = if (std.mem.eql(
            u8,
            head.request_line.method.slice(head_bytes),
            "HEAD",
        ))
            bridge.ResponseRequestSemantics.head
        else
            bridge.ResponseRequestSemantics.regular;

        const screened = switch (screenHead(
            head.request_line,
            head.headers,
            head_bytes,
            head.framing,
        )) {
            Screen.reject => |kind| {
                self.sendError(kind, head.request_line.version);
                return Outcome.close;
            },
            Screen.proceed => |proceed| proceed,
        };
        const persistence_decision = screened.persistence;
        // The loop sends `100 Continue` before it reads a body; a body it did
        // not read is answered with an error, which RFC 9110 §10.1.1 allows in
        // place of the interim response. When the loop gave up waiting for
        // the body, answer before any Roc code runs, as for a head that did
        // not arrive in time.
        switch (prefetch.body) {
            BodyPrefetch.timed_out => return self.handleReadError(error.RequestBodyTimeout),
            BodyPrefetch.closed => return self.handleReadError(error.IncompleteBody),
            BodyPrefetch.invalid => return self.handleReadError(error.InvalidChunkedBody),
            BodyPrefetch.too_large => return self.handleReadError(error.RequestBodyTooLarge),
            BodyPrefetch.over_budget => {
                self.sendErrorFor(error_response.Kind.service_unavailable, head.request_line.version, access_log.Outcome.body_budget);
                return Outcome.close;
            },
            BodyPrefetch.not_read, BodyPrefetch.complete, BodyPrefetch.partial => {},
        }

        // Names the request in `dbg` and crash logs until its response is
        // done, including streaming producers.
        request_debug.beginRequest(
            head.request_line.method.slice(head_bytes),
            head.request_line.target.slice(head_bytes),
            id.slice(),
            findHeader(head.headers, head_bytes, "traceparent"),
        );
        defer request_debug.endRequest();

        allocator_context.setCurrent(.{
            .host_allocator = host_allocator,
            .domain = Domain.request,
            .generation = generation,
        });
        defer allocator_context.clearCurrent();

        const use_stream = request_reader.hasBody(head.framing);
        var body_stream: request_reader.BodyStream = undefined;
        var body_stream_active = false;
        defer if (body_stream_active) body_effect.deactivate();

        const request_host = bridge.RequestHost{
            .roc_host = roc_host,
            .try_alloc = runtime.tryAllocWithHost,
        };
        const roc_request = (if (use_stream) blk: {
            const body_deadline = prefetch.body_deadline orelse
                (net.Deadline.afterMilliseconds(
                    self.limits.request_body_timeout_milliseconds,
                ) catch |err| return self.handleReadError(err));
            // A chunked body the loop decoded is read like a Content-Length
            // body; the app still sees the request's own fields.
            var body_head = head;
            if (prefetch.decoded_body_length) |length| body_head.framing = http1_parser.BodyFraming{ .content_length = length };
            body_stream = self.reader.beginBodyStreamWith(
                self.accepted.socket,
                body_head,
                .{
                    .deadline = body_deadline,
                    .limits = .{
                        .whole_bytes = self.limits.maximum_body_bytes,
                        .streamed_bytes = self.limits.maximum_streamed_body_bytes,
                        .idle_timeout_milliseconds = self.limits.request_body_timeout_milliseconds,
                    },
                    // The loop sends it before it receives a body; one it
                    // did not receive gets it at the handler's first read
                    //, as hyper does.
                    .send_continue = screened.send_continue and prefetch.body == BodyPrefetch.not_read,
                    .predecoded = if (prefetch.body == BodyPrefetch.partial) prefetch.predecoded else null,
                },
            ) catch |err| return self.handleReadError(err);
            const token = body_effect.activate(&body_stream);
            body_stream_active = true;
            break :blk bridge.requestFromParsedStream(
                self.reader.headBytes(head),
                head.request_line,
                head.headers,
                token,
                self.remoteAddress(),
                id.slice(),
                request_host,
            );
        } else blk: {
            const request = self.reader.finish(head);
            break :blk bridge.requestFromParsed(
                request.head_bytes,
                request.request_line,
                request.headers,
                request.body,
                self.remoteAddress(),
                id.slice(),
                request_host,
            );
        }) catch |conversion_error| switch (conversion_error) {
            error.UnsupportedMethod => {
                self.sendError(
                    error_response.Kind.not_implemented,
                    head.request_line.version,
                );
                return Outcome.close;
            },
            error.InvalidSpan, error.InvalidTarget => {
                self.sendError(
                    error_response.Kind.bad_request,
                    head.request_line.version,
                );
                return Outcome.close;
            },
            error.AllocationTooLarge, error.OutOfMemory => {
                self.sendError(
                    error_response.Kind.internal_server_error,
                    head.request_line.version,
                );
                return Outcome.close;
            },
        };

        self.written = .{
            .version = head.request_line.version,
            .request_semantics = request_semantics,
            .persistence = persistence_decision,
            .body_stream = if (body_stream_active) &body_stream else null,
        };
        response_writer.activate(.{ .context = @ptrCast(self), .start = startWrittenThunk, .write = writeWrittenThunk, .abort = abortWrittenThunk });
        const answered = bridge.rocHandle(
            model_root.retainForHandle(),
            roc_request,
        );
        response_writer.deactivate();
        if (access_log.enabled()) self.access.route.set(answered.route.asSlice());
        answered.route.decref(roc_host);
        const response = answered.response;
        if (self.written.?.state != Written.State.not_started) {
            // The handler wrote the body; the response is only its head.
            response.decref(roc_host);
            if (body_stream_active and !self.written.?.body_closed) body_effect.deactivate();
            body_stream_active = false;
            return self.finishWritten();
        }
        self.written = null;
        if (body_stream_active) {
            body_effect.deactivate();
            body_stream_active = false;
        }
        const request_body_consumed = !use_stream or
            self.recoverUnreadBody(&body_stream);
        const draining = if (self.draining) |flag| flag.load(std.builtin.AtomicOrder.acquire) else false;
        const response_connection = if (request_body_consumed and !draining)
            persistence_decision.response_connection
        else
            bridge.ResponseConnection.close;
        const write_deadline = net.Deadline.afterMilliseconds(
            self.limits.response_write_timeout_milliseconds,
        ) catch |err| {
            response.decref(roc_host);
            return err;
        };
        const date = self.currentDate();
        // The head is encoded here and sent (or copied to pending output)
        // before this function returns, so its 32 KiB buffer is allocated
        // only meanwhile: a request waiting on a fiber does not hold one
        //.
        const response_buffer = createResponseBuffer() orelse {
            response.decref(roc_host);
            self.sendError(error_response.Kind.service_unavailable, head.request_line.version);
            return Outcome.close;
        };
        // Read before encoding takes the response. A HEAD response, and a
        // 204, 205, or 304 (which encoding requires to be empty), send no body.
        const answered_status = response.status;
        const answered_body_bytes: u64 = if (request_semantics == bridge.ResponseRequestSemantics.head or
            response.body.tag != bridge.HttpResponseBodyTag.Bytes)
            0
        else
            response.body.payload_bytes().items().len;
        defer destroyResponseBuffer(response_buffer);
        var encoded = bridge.OwnedResponseEncoder.initForRequestWithExtra(
            response,
            roc_host,
            response_buffer,
            &self.head_scratch,
            head.request_line.version,
            response_connection,
            request_semantics,
            date,
            request_debug.takeResponseHeaders(&self.debug_headers, debugRoom(response)),
        ) catch {
            self.sendErrorFor(
                error_response.Kind.internal_server_error,
                head.request_line.version,
                access_log.Outcome.encode_failed,
            );
            return Outcome.close;
        };
        self.noteAnswer(answered_status, access_log.Outcome.handled);
        self.access.body_bytes = answered_body_bytes;
        var write_context = WriteContext{
            .socket = self.accepted.socket,
            .deadline = write_deadline,
            .session = self,
        };
        const outcome_after = if (persistence_decision.reuse_connection and
            request_body_consumed and
            !draining)
            Outcome.reuse
        else
            Outcome.close;
        // Deferred writes never wait.
        encoded.sendAll(
            @ptrCast(&write_context),
            if (self.defer_buffered_writes) writeIovecsDeferred else writeIovecs,
        ) catch {
            self.discardPendingOutput();
            self.access.outcome = access_log.Outcome.client_closed;
            return Outcome.close;
        };

        self.completed_requests += 1;
        return outcome_after;
    }

    /// Transfers the unwritten response bytes, if any, to the caller. The
    /// caller frees them with `std.heap.smp_allocator`.
    /// The allocation is handed over whole: shrinking it could fail, and a
    /// shorter slice must not be freed in place of the original.
    pub fn takePendingOutput(self: *Session) ?PendingOutput {
        if (self.pending_length == 0) return null;
        const output = PendingOutput{
            .allocation = self.pending_buffer,
            .length = self.pending_length,
            .deadline = self.pending_deadline,
        };
        self.pending_buffer = &.{};
        self.pending_length = 0;
        return output;
    }

    pub fn discardPendingOutput(self: *Session) void {
        raw_bytes.free(self.pending_buffer);
        self.pending_buffer = &.{};
        self.pending_length = 0;
    }

    /// Keeps the iovec bytes after the first `skip` bytes for later writing.
    fn appendPending(
        self: *Session,
        iovecs: []const std.posix.iovec_const,
        skip: usize,
        deadline: net.Deadline,
    ) error{OutOfMemory}!void {
        var total: usize = 0;
        for (iovecs) |iovec| total += iovec.len;
        const needed = self.pending_length + total - skip;
        if (needed > self.pending_buffer.len) {
            self.pending_buffer = try raw_bytes.realloc(
                self.pending_buffer,
                @max(needed, self.pending_buffer.len * 2),
            );
        }
        if (self.pending_length == 0) self.pending_deadline = deadline;
        var remaining_skip = skip;
        for (iovecs) |iovec| {
            const bytes = iovec.base[0..iovec.len];
            if (remaining_skip >= bytes.len) {
                remaining_skip -= bytes.len;
                continue;
            }
            const kept = bytes[remaining_skip..];
            remaining_skip = 0;
            @memcpy(self.pending_buffer[self.pending_length..][0..kept.len], kept);
            self.pending_length += kept.len;
        }
    }

    fn recoverUnreadBody(
        self: *Session,
        body_stream: *request_reader.BodyStream,
    ) bool {
        if (body_stream.isFullyConsumed()) return true;

        const outcome = switch (self.limits.unread_body_policy) {
            UnreadBodyPolicy.close => return false,
            UnreadBodyPolicy.buffered_only => body_stream.discardBuffered() catch return false,
            UnreadBodyPolicy.bounded_drain => body_stream.drainBounded(
                self.limits.unread_body_maximum_bytes,
                self.limits.unread_body_timeout_milliseconds,
            ) catch return false,
        };
        return switch (outcome) {
            request_reader.RecoveryOutcome.recovered => true,
            request_reader.RecoveryOutcome.incomplete,
            request_reader.RecoveryOutcome.limit_exceeded,
            request_reader.RecoveryOutcome.timed_out,
            => false,
        };
    }

    fn remoteAddress(self: *const Session) bridge.RemoteAddress {
        return .{ .v4 = .{
            .octets = self.accepted.remote_octets,
            .port = self.accepted.remote_port,
        } };
    }

    fn handleReadError(
        self: *Session,
        read_error: request_reader.Error,
    ) Error!?Outcome {
        const kind: ?error_response.Kind = switch (read_error) {
            // No request started: a clean close with no response.
            error.IdleTimeout => return null,
            error.InvalidRequest,
            error.InvalidChunkedBody,
            error.MissingRequestLine,
            error.MissingBodyFraming,
            => error_response.Kind.bad_request,
            error.RequestHeadTimeout,
            error.RequestBodyTimeout,
            => error_response.Kind.request_timeout,
            error.RequestHeadTooLarge => error_response.Kind.header_fields_too_large,
            error.RequestTargetTooLong => error_response.Kind.uri_too_long,
            error.RequestBodyTooLarge => error_response.Kind.content_too_large,
            error.UnsupportedHttpVersion => error_response.Kind.http_version_not_supported,
            // The connection is broken; close it without a response.
            error.IncompleteRequest,
            error.IncompleteBody,
            error.ReceiveFailed,
            error.PollFailed,
            => null,
            // The reader turns these into the errors above; if one reaches
            // here anyway it concerns this connection only, so close it
            // rather than end the worker.
            error.ReceiveTimeout => error_response.Kind.request_timeout,
            error.SocketFailed,
            error.SetSocketOptionFailed,
            error.BindFailed,
            error.ListenFailed,
            error.GetSocketNameFailed,
            error.SendFailed,
            error.SendTimeout,
            error.SetNonBlockingFailed,
            => null,
            // Process-wide failures end the worker.
            error.OutOfMemory,
            error.ClockFailed,
            => return read_error,
        };

        if (kind) |response_kind| {
            self.sendError(
                response_kind,
                self.reader.requestVersion() orelse
                    persistence.HttpVersion.http_1_1,
            );
        }
        return Outcome.close;
    }

    /// Notes that a response was sent or begun, so the access log has a line
    /// for it. A response before the head was read has no ID yet.
    /// Sends the head of a body the handler writes. Past
    /// `maximum_streams` (counting only responses with a body), or when the
    /// head cannot be encoded, the host answers instead and the stream does
    /// not start.
    fn startWritten(self: *Session, response: *const bridge.HttpResponse, keep_alive_milliseconds: u64, keep_alive_bytes: []const u8, ends_on_drain: bool, content_length: ?u64, gzip_body: bool) bool {
        const written = &self.written.?;
        std.debug.assert(written.state == Written.State.not_started);
        written.state = Written.State.answered;
        // The request body closes once the head goes out: what is left
        // unread now decides whether the connection is kept, as for any
        // response (Go also lets HTTP/1.x handlers read only before writing).
        const request_body_consumed = if (written.body_stream) |body_stream| blk: {
            const consumed = self.recoverUnreadBody(body_stream);
            body_effect.deactivate();
            written.body_stream = null;
            written.body_closed = true;
            break :blk consumed;
        } else true;
        const draining = if (self.draining) |flag| flag.load(std.builtin.AtomicOrder.acquire) else false;
        const response_connection = if (request_body_consumed and !draining)
            written.persistence.response_connection
        else
            bridge.ResponseConnection.close;
        const response_buffer = createResponseBuffer() orelse {
            self.sendError(error_response.Kind.service_unavailable, written.version);
            return false;
        };
        defer destroyResponseBuffer(response_buffer);
        var head = bridge.WrittenHead.init(
            response,
            response_buffer,
            &self.head_scratch,
            written.version,
            response_connection,
            written.request_semantics,
            self.currentDate(),
            request_debug.takeResponseHeaders(&self.debug_headers, debugRoom(response.*)),
            content_length,
        ) catch {
            self.sendErrorFor(error_response.Kind.internal_server_error, written.version, access_log.Outcome.encode_failed);
            return false;
        };
        // Only a body takes a place among the streams: a `HEAD` request or a
        // 204 / 304 answers with the head alone.
        if (head.transmit_body) {
            if (self.active_streams) |count| {
                if (count.fetchAdd(1, std.builtin.AtomicOrder.monotonic) >= self.limits.maximum_streams) {
                    _ = count.fetchSub(1, std.builtin.AtomicOrder.monotonic);
                    self.warnStreamLimit();
                    self.sendErrorFor(error_response.Kind.service_unavailable, written.version, access_log.Outcome.stream_limit);
                    return false;
                }
                written.counted = true;
            }
        }
        self.noteAnswer(response.status, access_log.Outcome.handled);
        written.state = Written.State.writing;
        written.chunked = head.chunked;
        written.transmit_body = head.transmit_body;
        written.remaining = if (head.transmit_body) content_length else null;
        if (gzip_body and head.transmit_body) {
            std.debug.assert(content_length == null);
            written.compressor = gzip.Compressor.create() catch return self.failWritten();
        }
        written.reuse = written.persistence.reuse_connection and request_body_consumed and !draining and !head.force_connection_close;
        self.guardWritten(if (head.transmit_body) keep_alive_milliseconds else 0, keep_alive_bytes, ends_on_drain) catch return self.failWritten();
        var write_context = self.writeContext() catch return self.failWritten();
        self.guard.writing = true;
        defer self.guard.writing = false;
        head.send(@ptrCast(&write_context), writeIovecs) catch return self.failWritten();
        self.guard.last_write_at = net.monotonicNanoseconds() catch self.guard.last_write_at;
        return true;
    }

    /// From the head on, the request fiber's waits watch the client
    ///: a gone client stops the request at its wait, as does a drain
    /// with `ends_on_drain`, and a quiet body gets its keep-alive
    /// bytes. Off a request fiber nothing watches.
    fn guardWritten(self: *Session, keep_alive_milliseconds: u64, keep_alive_bytes: []const u8, ends_on_drain: bool) error{ OutOfMemory, ClockFailed }!void {
        if (self.client_hooks == null) return;
        const locals = fiber.currentLocals() orelse return;
        const beats = keep_alive_milliseconds != 0 and keep_alive_bytes.len != 0;
        if (beats) self.keep_alive_bytes = try raw_bytes.dupe(keep_alive_bytes);
        self.guard = .{
            .context = @ptrCast(self),
            .client_socket = self.accepted.socket,
            .arm = armThunk,
            .disarm = disarmThunk,
            .restore = restoreThunk,
            .beat = beatThunk,
            .end = endThunk,
            .ends_on_drain = ends_on_drain,
            .keep_alive_nanoseconds = if (beats) keep_alive_milliseconds *| std.time.ns_per_ms else 0,
            .last_write_at = try net.monotonicNanoseconds(),
        };
        locals.stream_guard = &self.guard;
    }

    /// Ends what `guardWritten` began.
    fn unguardWritten(self: *Session) void {
        if (fiber.currentLocals()) |locals| locals.stream_guard = null;
        raw_bytes.free(self.keep_alive_bytes);
        self.keep_alive_bytes = &.{};
    }

    fn armThunk(context: *anyopaque, target: *fiber.Fiber, serial: u64, ends_on_drain: bool) fiber.Stop {
        const self: *Session = @ptrCast(@alignCast(context));
        const hooks = self.client_hooks.?;
        return hooks.arm(hooks.context, target, serial, ends_on_drain);
    }

    fn disarmThunk(context: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(context));
        const hooks = self.client_hooks.?;
        hooks.disarm(hooks.context);
    }

    fn restoreThunk(context: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(context));
        const hooks = self.client_hooks.?;
        hooks.restore(hooks.context);
    }

    fn beatThunk(context: *anyopaque) bool {
        const self: *Session = @ptrCast(@alignCast(context));
        return self.writeWritten(self.keep_alive_bytes);
    }

    /// Ends a written body as its request stops for a drain: the
    /// chunked body gets its end, so the client sees a whole response. The
    /// connection then closes, as the request is abandoned.
    fn endThunk(context: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(context));
        const written = &self.written.?;
        if (written.state != Written.State.writing) return;
        if (access_log.enabled()) {
            self.access.body_bytes = written.body_bytes;
            self.access.outcome = access_log.Outcome.drained;
        }
        if (!self.endCompression()) return;
        if (!written.transmit_body or !written.chunked) return;
        var write_context = self.writeContext() catch {
            _ = self.failWritten();
            return;
        };
        self.guard.writing = true;
        defer self.guard.writing = false;
        bridge.writeBodyEnd(@ptrCast(&write_context), writeIovecs) catch {
            _ = self.failWritten();
        };
    }

    /// Writes the next part of a written body, waiting (on the request's
    /// fiber) while the client does not take it, for up to the response
    /// write timeout.
    fn writeWritten(self: *Session, bytes: []const u8) bool {
        const written = &self.written.?;
        if (written.state != Written.State.writing) return false;
        if (!written.transmit_body or bytes.len == 0) return true;
        if (written.compressor != null) return self.compressPart(bytes, false);
        return self.writePart(bytes);
    }

    /// Compresses `bytes` and writes what the compressor produced: flushed,
    /// so the part reaches the client now, or with the gzip stream's end.
    fn compressPart(self: *Session, bytes: []const u8, final: bool) bool {
        const compressor = self.written.?.compressor.?;
        var step = CompressStep{ .compressor = compressor, .input = bytes, .final = final };
        blocking.run(&step.job);
        if (!step.ok) return self.failWritten();
        defer compressor.forgetProduced();
        const produced = compressor.produced();
        if (produced.len == 0) return true;
        return self.writePart(produced);
    }

    /// Ends a compressed body's gzip stream, before its framing ends.
    fn endCompression(self: *Session) bool {
        const written = &self.written.?;
        if (written.compressor == null or written.state != Written.State.writing) return true;
        return self.compressPart(&.{}, true);
    }

    fn dropCompressor(written: *Written) void {
        const compressor = written.compressor orelse return;
        compressor.destroy();
        written.compressor = null;
    }

    fn writePart(self: *Session, bytes: []const u8) bool {
        const written = &self.written.?;
        if (written.remaining) |remaining| {
            // More than the head said: the body would not be what it claims.
            if (bytes.len > remaining) return self.failWritten();
            written.remaining = remaining - bytes.len;
        }
        var write_context = self.writeContext() catch return self.failWritten();
        self.guard.writing = true;
        defer self.guard.writing = false;
        bridge.writeBodyPart(@ptrCast(&write_context), writeIovecs, bytes, written.chunked) catch return self.failWritten();
        written.body_bytes += bytes.len;
        self.guard.last_write_at = net.monotonicNanoseconds() catch self.guard.last_write_at;
        return true;
    }

    fn failWritten(self: *Session) bool {
        self.written.?.state = Written.State.failed;
        if (access_log.enabled()) self.access.outcome = access_log.Outcome.client_closed;
        return false;
    }

    /// Ends a written body once the handler has returned.
    fn finishWritten(self: *Session) Outcome {
        _ = self.endCompression();
        dropCompressor(&self.written.?);
        const written = self.written.?;
        defer self.written = null;
        defer self.unguardWritten();
        defer if (written.counted) {
            _ = self.active_streams.?.fetchSub(1, std.builtin.AtomicOrder.monotonic);
        };
        if (access_log.enabled()) self.access.body_bytes = written.body_bytes;
        switch (written.state) {
            Written.State.not_started => unreachable,
            // The host's answer closes the connection.
            Written.State.answered, Written.State.failed => return Outcome.close,
            Written.State.writing => {},
        }
        // Short of its length, as a file that shrank: the client sees the
        // body cut, as the connection closes.
        if (written.remaining) |remaining| if (remaining != 0) {
            _ = self.failWritten();
            return Outcome.close;
        };
        if (written.transmit_body and written.chunked) {
            var write_context = self.writeContext() catch {
                _ = self.failWritten();
                return Outcome.close;
            };
            bridge.writeBodyEnd(@ptrCast(&write_context), writeIovecs) catch {
                _ = self.failWritten();
                return Outcome.close;
            };
        }
        self.completed_requests += 1;
        return if (written.reuse) Outcome.reuse else Outcome.close;
    }

    /// After the request's Roc code crashed: whether the head of a
    /// written body went out, so no error response can follow. Gives back
    /// the stream's place.
    pub fn abandonWritten(self: *Session) bool {
        var written = self.written orelse return false;
        dropCompressor(&written);
        self.written = null;
        // Off the fiber now; its locals are cleared when it is next used.
        raw_bytes.free(self.keep_alive_bytes);
        self.keep_alive_bytes = &.{};
        if (written.counted) _ = self.active_streams.?.fetchSub(1, std.builtin.AtomicOrder.monotonic);
        return written.state == Written.State.writing or written.state == Written.State.failed;
    }

    fn writeContext(self: *Session) error{ClockFailed}!WriteContext {
        return .{
            .socket = self.accepted.socket,
            .deadline = net.Deadline.afterMilliseconds(self.limits.response_write_timeout_milliseconds) catch return error.ClockFailed,
        };
    }

    fn noteAnswer(self: *Session, status: u16, outcome: access_log.Outcome) void {
        self.answered = true;
        if (!access_log.enabled()) return;
        self.access.status = status;
        self.access.outcome = outcome;
        if (self.access.request_id.len == 0) self.access.request_id = request_id.decide(request_id.Source.generate, &.{}, &.{});
    }

    /// Sends a host error response. With deferred writes it is written like
    /// a buffered response, so a client that does not read cannot hold the
    /// Roc thread: the send buffer may already be full of earlier responses.
    fn sendError(
        self: *Session,
        kind: error_response.Kind,
        version: persistence.HttpVersion,
    ) void {
        self.sendErrorFor(kind, version, hostOutcome(kind));
    }

    /// Like `sendError`, naming why in the access log.
    fn sendErrorFor(
        self: *Session,
        kind: error_response.Kind,
        version: persistence.HttpVersion,
        outcome: access_log.Outcome,
    ) void {
        self.noteAnswer(error_response.statusCode(kind), outcome);
        var buffer: error_response.Buffer = undefined;
        const response = error_response.renderWithDate(kind, version, &buffer, self.currentDate());
        const send_deadline = net.Deadline.afterMilliseconds(
            self.limits.response_write_timeout_milliseconds,
        ) catch return;
        if (!self.defer_buffered_writes) {
            net.sendAllUntil(self.accepted.socket, response, send_deadline) catch {};
            return;
        }
        var write_context = WriteContext{
            .socket = self.accepted.socket,
            .deadline = send_deadline,
            .session = self,
        };
        const iovecs = [_]std.posix.iovec_const{.{ .base = response.ptr, .len = response.len }};
        _ = writeIovecsDeferred(@ptrCast(&write_context), &iovecs) catch {};
    }

    /// Logs at most one stream-limit warning per second, so clients that
    /// keep asking for streams past the limit cannot flood the log.
    fn warnStreamLimit(self: *Session) void {
        const milliseconds = wall_time.nowUnixMilliseconds() orelse return;
        const second = @divFloor(milliseconds, 1000);
        if (self.stream_limit_warned_second == second) return;
        self.stream_limit_warned_second = second;
        diagnostics.requestWarning("the worker process already writes its maximum number of streams (Server.Limits.maximum_streams); answering 503 (logged at most once per second)");
    }

    /// The `Date` value for a response sent now, formatted at most once per
    /// second.
    fn currentDate(self: *Session) ?[]const u8 {
        const milliseconds = wall_time.nowUnixMilliseconds() orelse return null;
        return self.date_cache.format(@divFloor(milliseconds, 1000));
    }
};

/// Writes without waiting and keeps whatever the socket does not accept in
/// the session, reporting the bytes as written so the encoder completes.
/// Once bytes are pending, later bytes are appended to keep their order.
fn writeIovecsDeferred(
    context: *anyopaque,
    iovecs: []const std.posix.iovec_const,
) bridge.ResponseWriteError!usize {
    const write_context: *const WriteContext = @ptrCast(
        @alignCast(context),
    );
    const session = write_context.session.?;
    var total: usize = 0;
    for (iovecs) |iovec| total += iovec.len;

    var written: usize = 0;
    if (session.pending_length == 0) {
        written = net.sendIovecsAvailable(
            write_context.socket,
            iovecs,
        ) catch return bridge.ResponseWriteError.WriteFailed;
        if (written == total) return total;
    }
    session.appendPending(
        iovecs,
        written,
        write_context.deadline,
    ) catch return bridge.ResponseWriteError.WriteFailed;
    return total;
}

fn writeIovecs(
    context: *anyopaque,
    iovecs: []const std.posix.iovec_const,
) bridge.ResponseWriteError!usize {
    const write_context: *const WriteContext = @ptrCast(
        @alignCast(context),
    );
    const written = net.sendIovecsUntil(
        write_context.socket,
        iovecs,
        write_context.deadline,
    ) catch return bridge.ResponseWriteError.WriteFailed;
    return written;
}

/// Why the host answers with `kind`, for the access log, when the caller
/// does not say.
fn hostOutcome(kind: error_response.Kind) access_log.Outcome {
    return switch (kind) {
        error_response.Kind.bad_request,
        error_response.Kind.uri_too_long,
        error_response.Kind.header_fields_too_large,
        error_response.Kind.expectation_failed,
        error_response.Kind.not_implemented,
        error_response.Kind.http_version_not_supported,
        => access_log.Outcome.bad_request,
        error_response.Kind.request_timeout => access_log.Outcome.timeout,
        error_response.Kind.content_too_large => access_log.Outcome.too_large,
        error_response.Kind.internal_server_error => access_log.Outcome.encode_failed,
        error_response.Kind.service_unavailable => access_log.Outcome.overloaded,
    };
}

/// Head space for debug mode's fields. Outside debug mode nothing is
/// captured, so the response's fields are not walked.
/// A response head buffer, taken with `rawAlloc`: `Allocator.create` fills
/// its 32 KiB with 0xAA on every request in a safe build, which took over
/// 40 % of a request's CPU time.
fn createResponseBuffer() ?*bridge.ResponseBuffer {
    const memory = std.heap.smp_allocator.rawAlloc(@sizeOf(bridge.ResponseBuffer), std.mem.Alignment.of(bridge.ResponseBuffer), @returnAddress()) orelse return null;
    return @ptrCast(@alignCast(memory));
}

fn destroyResponseBuffer(buffer: *bridge.ResponseBuffer) void {
    const bytes: [*]u8 = @ptrCast(buffer);
    std.heap.smp_allocator.rawFree(bytes[0..@sizeOf(bridge.ResponseBuffer)], std.mem.Alignment.of(bridge.ResponseBuffer), @returnAddress());
}

fn debugRoom(response: bridge.HttpResponse) request_debug.Room {
    if (!request_debug.enabled) return .{ .bytes = 0, .fields = 0 };
    const room = bridge.responseExtraRoom(response);
    return .{ .bytes = room.bytes, .fields = room.fields };
}

/// The first value of a request field, by case-insensitive name.
fn findHeader(
    headers: []const http1_parser.Header,
    head_bytes: []const u8,
    name: []const u8,
) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name.slice(head_bytes), name)) {
            return header.value.slice(head_bytes);
        }
    }
    return null;
}

test "pending output hands over the whole allocation" {
    const session = try std.heap.page_allocator.create(Session);
    defer std.heap.page_allocator.destroy(session);
    session.* = Session.initWithLimits(undefined, .{});
    const deadline = net.Deadline{ .expires_at_nanoseconds = 0 };
    const iovec = std.posix.iovec_const;

    // The first append allocates exactly: length equals capacity.
    try session.appendPending(&.{iovec{ .base = "abc", .len = 3 }}, 0, deadline);
    const exact = session.takePendingOutput().?;
    defer raw_bytes.free(exact.allocation);
    try std.testing.expectEqual(@as(usize, 3), exact.allocation.len);
    try std.testing.expectEqualStrings("abc", exact.allocation[0..exact.length]);
    try std.testing.expectEqual(@as(?PendingOutput, null), session.takePendingOutput());

    // Growth doubles: length is one below capacity, and the capacity is kept.
    try session.appendPending(&.{iovec{ .base = "abc", .len = 3 }}, 0, deadline);
    try session.appendPending(&.{iovec{ .base = "xde", .len = 3 }}, 1, deadline);
    const grown = session.takePendingOutput().?;
    defer raw_bytes.free(grown.allocation);
    try std.testing.expectEqual(@as(usize, 6), grown.allocation.len);
    try std.testing.expectEqualStrings("abcde", grown.allocation[0..grown.length]);
}

test "screening answers head problems in the host's order" {
    const Case = struct { head: []const u8, expected: ?error_response.Kind, send_continue: bool = false };
    for ([_]Case{
        // An invalid target is rejected before Expect is considered, so no
        // 100 Continue precedes the 400.
        .{ .head = "POST /a/../b HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n", .expected = error_response.Kind.bad_request },
        .{ .head = "POST / HTTP/1.1\r\nHost: x\r\nExpect: custom\r\nContent-Length: 1\r\n\r\n", .expected = error_response.Kind.expectation_failed },
        .{ .head = "POST / HTTP/1.1\r\nHost: x\r\nConnection: bad value\r\n\r\n", .expected = error_response.Kind.bad_request },
        .{ .head = "POST / HTTP/1.0\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n", .expected = null },
        .{ .head = "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n", .expected = null, .send_continue = true },
        .{ .head = "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 0\r\n\r\n", .expected = null },
    }) |case| {
        var parser = http1_parser.Parser{};
        switch (parser.feed(case.head)) {
            http1_parser.FeedResult.head_complete => {},
            else => return error.TestUnexpectedResult,
        }
        const screened = screenHead(parser.requestLine().?, parser.headers(), case.head, parser.bodyFraming().?);
        switch (screened) {
            Screen.reject => |kind| try std.testing.expectEqual(case.expected, kind),
            Screen.proceed => |proceed| {
                try std.testing.expectEqual(@as(?error_response.Kind, null), case.expected);
                try std.testing.expectEqual(case.send_continue, proceed.send_continue);
            },
        }
    }
}

test "finishing a short body closes and clears the stream without a null access" {
    const session = try std.heap.page_allocator.create(Session);
    defer std.heap.page_allocator.destroy(session);
    // Remaining length is nonnegative: zero completes, one is the nearest short body.
    for ([_]u64{ 0, 1 }) |remaining| {
        session.* = Session.initWithLimits(undefined, .{});
        session.written = .{
            .version = persistence.HttpVersion.http_1_1,
            .request_semantics = undefined,
            .persistence = undefined,
            .body_stream = null,
            .state = Written.State.writing,
            .remaining = remaining,
            .reuse = true,
        };
        try std.testing.expectEqual(if (remaining == 0) Outcome.reuse else Outcome.close, session.finishWritten());
        try std.testing.expect(session.written == null);
    }
}

test "aborted gzip stream closes without a successful compression terminator" {
    const session = try std.heap.page_allocator.create(Session);
    defer std.heap.page_allocator.destroy(session);
    session.* = Session.initWithLimits(undefined, .{});
    session.written = .{
        .version = persistence.HttpVersion.http_1_1,
        .request_semantics = undefined,
        .persistence = undefined,
        .body_stream = null,
        .state = Written.State.writing,
        .chunked = true,
        .transmit_body = true,
        .reuse = true,
        .compressor = try gzip.Compressor.create(),
    };
    abortWrittenThunk(@ptrCast(session));
    try std.testing.expectEqual(Outcome.close, session.finishWritten());
    try std.testing.expect(session.written == null);
    try std.testing.expectEqual(@as(usize, 0), session.completed_requests);
}
