//! Test-only Roc FFI ownership and allocator contract environment.

const std = @import("std");
const bridge = @import("bridge");
const host_allocator_module = bridge.host_allocator;
const tracking_allocator_module = @import("tracking_allocator");

pub const Domain = host_allocator_module.Domain;
pub const max_generation = host_allocator_module.max_generation;

const HostAllocator = host_allocator_module.HostAllocator;
const TrackingAllocator = tracking_allocator_module.TrackingAllocator;

pub const ContractError = error{
    BaselineAlreadyCaptured,
    BaselineMissing,
    RequestLeak,
    PersistentBaselineMismatch,
    CanaryViolation,
    InvalidFree,
    GenerationMismatch,
    GenerationExhausted,
};

pub const ContractEnvironment = struct {
    persistent: TrackingAllocator,
    request: TrackingAllocator,

    current_domain: Domain = Domain.persistent,
    generation: usize = 0,
    persistent_baseline: ?usize = null,
    generation_mismatches: usize = 0,

    pub fn init(
        backing_allocator: std.mem.Allocator,
    ) ContractEnvironment {
        return .{
            .persistent = TrackingAllocator.init(backing_allocator),
            .request = TrackingAllocator.init(backing_allocator),
        };
    }

    pub fn deinit(self: *ContractEnvironment) void {
        self.request.deinit();
        self.persistent.deinit();
    }

    pub fn rocHost(self: *ContractEnvironment) bridge.RocHost {
        return .{
            .env = @ptrCast(self),
            .roc_alloc = allocate,
            .roc_dealloc = deallocate,
            .roc_realloc = reallocate,
            .roc_dbg = ignoreDiagnostic,
            .roc_expect_failed = ignoreDiagnostic,
            .roc_crashed = ignoreDiagnostic,
        };
    }

    pub fn setDomain(
        self: *ContractEnvironment,
        domain: Domain,
    ) void {
        self.current_domain = domain;
    }

    pub fn capturePersistentBaseline(
        self: *ContractEnvironment,
    ) ContractError!void {
        if (self.persistent_baseline != null) {
            return ContractError.BaselineAlreadyCaptured;
        }
        try self.checkInstrumentation();
        if (self.request.live_count != 0) return ContractError.RequestLeak;
        self.persistent_baseline = self.persistent.live_count;
    }

    pub fn finishRequest(
        self: *ContractEnvironment,
    ) ContractError!void {
        const baseline = self.persistent_baseline orelse
            return ContractError.BaselineMissing;

        try self.checkInstrumentation();
        if (self.generation_mismatches != 0) {
            return ContractError.GenerationMismatch;
        }
        if (self.request.live_count != 0) return ContractError.RequestLeak;
        if (self.persistent.live_count != baseline) {
            return ContractError.PersistentBaselineMismatch;
        }
        if (self.generation >= max_generation) {
            return ContractError.GenerationExhausted;
        }

        self.generation += 1;
    }

    fn checkInstrumentation(
        self: *const ContractEnvironment,
    ) ContractError!void {
        if (self.request.canary_violations != 0 or
            self.persistent.canary_violations != 0)
        {
            return ContractError.CanaryViolation;
        }
        if (self.request.invalid_frees != 0 or
            self.persistent.invalid_frees != 0)
        {
            return ContractError.InvalidFree;
        }
    }

    fn hostAllocator(self: *ContractEnvironment) HostAllocator {
        return .{
            .persistent_allocator = self.persistent.allocator(),
            .request_allocator = self.request.allocator(),
        };
    }

    fn noteGenerationMismatch(
        self: *ContractEnvironment,
        pointer: *const anyopaque,
    ) void {
        const metadata = host_allocator_module.allocationMetadata(
            pointer,
        );
        if (metadata.domain == Domain.request and
            metadata.generation != self.generation)
        {
            self.generation_mismatches += 1;
        }
    }

    fn allocate(
        roc_host: *bridge.RocHost,
        length: usize,
        alignment: usize,
    ) callconv(std.builtin.CallingConvention.c) *anyopaque {
        const self: *ContractEnvironment = @ptrCast(
            @alignCast(roc_host.env),
        );
        var host_allocator = self.hostAllocator();
        return host_allocator.alloc(
            self.current_domain,
            self.generation,
            length,
            alignment,
        ) orelse @panic("out of memory");
    }

    fn deallocate(
        roc_host: *bridge.RocHost,
        pointer: *anyopaque,
        alignment: usize,
    ) callconv(std.builtin.CallingConvention.c) void {
        const self: *ContractEnvironment = @ptrCast(
            @alignCast(roc_host.env),
        );
        self.noteGenerationMismatch(pointer);
        var host_allocator = self.hostAllocator();
        host_allocator.dealloc(pointer, alignment);
    }

    fn reallocate(
        roc_host: *bridge.RocHost,
        pointer: *anyopaque,
        new_length: usize,
        alignment: usize,
    ) callconv(std.builtin.CallingConvention.c) *anyopaque {
        const self: *ContractEnvironment = @ptrCast(
            @alignCast(roc_host.env),
        );
        self.noteGenerationMismatch(pointer);
        var host_allocator = self.hostAllocator();
        return host_allocator.realloc(
            pointer,
            new_length,
            alignment,
        ) orelse @panic("out of memory");
    }

    fn ignoreDiagnostic(
        roc_host: *bridge.RocHost,
        bytes: [*]const u8,
        length: usize,
    ) callconv(std.builtin.CallingConvention.c) void {
        _ = roc_host;
        _ = bytes;
        _ = length;
    }
};
