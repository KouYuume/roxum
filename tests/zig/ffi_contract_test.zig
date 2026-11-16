const std = @import("std");
const bridge = @import("bridge");
const contract = @import("contract_environment");

const ContractEnvironment = contract.ContractEnvironment;
const Domain = contract.Domain;

test "generated RocStr crosses the inline capacity boundary" {
    var environment = ContractEnvironment.init(std.testing.allocator);
    defer environment.deinit();
    var roc_host = environment.rocHost();
    try environment.capturePersistentBaseline();
    environment.setDomain(Domain.request);

    const source = @as([25]u8, @splat('x'));
    const cases = [_]struct {
        length: usize,
        is_small: bool,
        live_count: usize,
    }{
        .{ .length = 23, .is_small = true, .live_count = 0 },
        .{ .length = 24, .is_small = false, .live_count = 1 },
        .{ .length = 25, .is_small = false, .live_count = 1 },
    };

    for (cases) |case| {
        const value = bridge.GeneratedRocStr.fromSlice(
            source[0..case.length],
            &roc_host,
        );

        try std.testing.expectEqual(
            case.is_small,
            value.isSmallStr(),
        );
        try std.testing.expectEqual(
            case.length,
            value.len(),
        );
        try std.testing.expectEqualSlices(
            u8,
            source[0..case.length],
            value.asSlice(),
        );
        try std.testing.expectEqual(
            case.live_count,
            environment.request.live_count,
        );

        value.decref(&roc_host);
        try environment.finishRequest();
    }
}

// The persistent root owns a callable plus a separately allocated capture.
// Dropping the last reference must free both; request references must free neither.
const HandlerCapture = struct {
    value: bridge.GeneratedRocStr,

    fn unused(_: *bridge.RocHost, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(std.builtin.CallingConvention.c) void {
        unreachable;
    }

    fn drop(pointer: ?[*]u8, roc_host: *bridge.RocHost) callconv(std.builtin.CallingConvention.c) void {
        const capture: *HandlerCapture = @ptrCast(@alignCast(pointer.?));
        capture.value.decref(roc_host);
    }

    fn create(roc_host: *bridge.RocHost) bridge.RocErasedCallable {
        const handler = bridge.allocateErasedCallable(roc_host, unused, drop, @sizeOf(HandlerCapture));
        const capture: *HandlerCapture = @ptrCast(@alignCast(bridge.erasedCallableCapturePtr(handler).?));
        capture.* = .{ .value = bridge.GeneratedRocStr.fromSlice("persistent handler capture exceeds inline storage", roc_host) };
        return handler;
    }
};

test "ModelRoot retains the boxed model across request and final-release boundaries" {
    // No call, first call, and repeated call cover the lifetime boundaries.
    for ([_]usize{ 0, 1, 2 }) |requests| {
        var environment = ContractEnvironment.init(std.testing.allocator);
        defer environment.deinit();
        var roc_host = environment.rocHost();
        // The host does not know the app's model type, so the box it owns has
        // a payload without refcounted values here, as `decrefBox` assumes.
        const model = bridge.allocateBox(@sizeOf(u64), @alignOf(u64), false, &roc_host);
        var root = bridge.ModelRoot.initOwned(model, &roc_host);
        try environment.capturePersistentBaseline();
        try std.testing.expectEqual(@as(usize, 1), environment.persistent.live_count);

        environment.setDomain(Domain.request);
        for (0..requests) |_| {
            const handle_argument = root.retainForHandle();
            try std.testing.expect(!bridge.isUniqueBox(model));
            // Simulates the reference `handle_for_host!` consumes.
            bridge.decrefBox(handle_argument, &roc_host);
            try std.testing.expect(bridge.isUniqueBox(model));
            try environment.finishRequest();
            try std.testing.expectEqual(@as(usize, 1), environment.persistent.live_count);
        }
        environment.setDomain(Domain.persistent);
        root.deinit();
        try std.testing.expectEqual(@as(usize, 0), environment.persistent.live_count);
    }
}

test "contract environment detects a missing handler retain" {
    var environment = ContractEnvironment.init(std.testing.allocator);
    defer environment.deinit();
    var roc_host = environment.rocHost();
    const handler = HandlerCapture.create(&roc_host);
    try environment.capturePersistentBaseline();
    environment.setDomain(Domain.request);
    bridge.decrefErasedCallable(handler, &roc_host);
    try std.testing.expectError(error.PersistentBaselineMismatch, environment.finishRequest());
}

test "contract environment detects request leaks and then recovers" {
    var environment = ContractEnvironment.init(std.testing.allocator);
    defer environment.deinit();
    var roc_host = environment.rocHost();
    try environment.capturePersistentBaseline();
    environment.setDomain(Domain.request);

    const pointer = roc_host.roc_alloc(
        &roc_host,
        8,
        8,
    );
    try std.testing.expectError(
        error.RequestLeak,
        environment.finishRequest(),
    );

    roc_host.roc_dealloc(&roc_host, pointer, 8);
    try environment.finishRequest();
    try std.testing.expectEqual(
        @as(usize, 1),
        environment.generation,
    );
}

test "contract environment detects persistent baseline growth" {
    var environment = ContractEnvironment.init(std.testing.allocator);
    defer environment.deinit();
    var roc_host = environment.rocHost();
    try environment.capturePersistentBaseline();

    const pointer = roc_host.roc_alloc(
        &roc_host,
        8,
        8,
    );
    try std.testing.expectError(
        error.PersistentBaselineMismatch,
        environment.finishRequest(),
    );

    roc_host.roc_dealloc(&roc_host, pointer, 8);
}

test "contract environment detects request generation mismatch" {
    var environment = ContractEnvironment.init(std.testing.allocator);
    defer environment.deinit();
    var roc_host = environment.rocHost();
    try environment.capturePersistentBaseline();
    environment.setDomain(Domain.request);

    const pointer = roc_host.roc_alloc(
        &roc_host,
        8,
        8,
    );
    environment.generation = 1;
    roc_host.roc_dealloc(&roc_host, pointer, 8);

    try std.testing.expectError(
        error.GenerationMismatch,
        environment.finishRequest(),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        environment.generation_mismatches,
    );
}

test "contract environment detects canary corruption" {
    var environment = ContractEnvironment.init(std.testing.allocator);
    defer environment.deinit();
    var roc_host = environment.rocHost();
    try environment.capturePersistentBaseline();
    environment.setDomain(Domain.request);

    const length: usize = 8;
    const alignment: usize = 8;
    const pointer = roc_host.roc_alloc(
        &roc_host,
        length,
        alignment,
    );
    const bytes: [*]u8 = @ptrCast(pointer);
    bytes[length] = 0;
    roc_host.roc_dealloc(&roc_host, pointer, alignment);

    try std.testing.expectError(
        error.CanaryViolation,
        environment.finishRequest(),
    );
}

test "contract environment detects invalid allocation alignment on free" {
    var environment = ContractEnvironment.init(std.testing.allocator);
    defer environment.deinit();
    var roc_host = environment.rocHost();
    try environment.capturePersistentBaseline();
    environment.setDomain(Domain.request);

    const alignment = 2 * @sizeOf(usize);
    const wrong_alignment = @sizeOf(usize);
    const pointer = roc_host.roc_alloc(
        &roc_host,
        8,
        alignment,
    );
    roc_host.roc_dealloc(
        &roc_host,
        pointer,
        wrong_alignment,
    );

    try std.testing.expectError(
        error.InvalidFree,
        environment.finishRequest(),
    );
}

test "contract environment enforces generation boundaries" {
    var environment = ContractEnvironment.init(std.testing.allocator);
    defer environment.deinit();
    try environment.capturePersistentBaseline();

    environment.generation = contract.max_generation - 1;
    try environment.finishRequest();
    try std.testing.expectEqual(
        contract.max_generation,
        environment.generation,
    );

    try std.testing.expectError(
        error.GenerationExhausted,
        environment.finishRequest(),
    );

    environment.generation = contract.max_generation + 1;
    try std.testing.expectError(
        error.GenerationExhausted,
        environment.finishRequest(),
    );
}

test "persistent baseline lifecycle rejects missing and duplicate capture" {
    var environment = ContractEnvironment.init(std.testing.allocator);
    defer environment.deinit();

    try std.testing.expectError(
        error.BaselineMissing,
        environment.finishRequest(),
    );
    try environment.capturePersistentBaseline();
    try std.testing.expectError(
        error.BaselineAlreadyCaptured,
        environment.capturePersistentBaseline(),
    );
}
