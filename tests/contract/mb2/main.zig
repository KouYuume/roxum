//! Exercise domain isolation and injected leak, double-free, and stale-generation failures.
//! Check persistent values before freeing them: tracking poisons released memory.
//!   MB2_MODE=arena|tracking|general
//!   MB2_INJECT=uaf|leak|double-free|domain-mix

const std = @import("std");
const alloc_mod = @import("alloc");

const HostAllocator = alloc_mod.HostAllocator;
const Domain = alloc_mod.Domain;
const Mode = alloc_mod.Mode;

fn envStr(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

pub fn main() !void {
    const mode: Mode = blk: {
        const s = envStr("MB2_MODE") orelse break :blk .arena;
        if (std.mem.eql(u8, s, "tracking")) break :blk .tracking;
        if (std.mem.eql(u8, s, "general")) break :blk .general;
        break :blk .arena;
    };
    const inject = envStr("MB2_INJECT");

    const gpa = std.heap.c_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var host = HostAllocator{
        .mode = mode,
        .persistent = gpa,
        .arena = arena_state.allocator(),
    };

    std.debug.print("MB-2 alloc-domain spike\n", .{});
    std.debug.print("  mode   : {s}\n", .{@tagName(mode)});
    std.debug.print("  inject : {s}\n\n", .{inject orelse "none"});

    // -----------------------------------------------------------------
    // -----------------------------------------------------------------
    host.enterDomain(.persistent);

    const model = host.alloc(64, 16) orelse return error.OutOfMemory;
    const model_bytes: [*]u8 = @ptrCast(model);
    @memcpy(model_bytes[0..5], "MODEL");

    const model2 = host.alloc(32, 8) orelse return error.OutOfMemory;
    const model2_bytes: [*]u8 = @ptrCast(model2);
    @memcpy(model2_bytes[0..4], "CFG!");

    std.debug.print("after init:\n", .{});
    std.debug.print("  Model = \"{s}\" (align=16)\n", .{model_bytes[0..5]});
    std.debug.print("  Cfg   = \"{s}\" (align=8)\n", .{model2_bytes[0..4]});
    std.debug.print("  persistent_live = {d}\n\n", .{host.persistent_live});

    // -----------------------------------------------------------------
    // -----------------------------------------------------------------
    var leaked_ptr: ?*anyopaque = null;

    var req: usize = 0;
    while (req < 3) : (req += 1) {
        host.enterDomain(.request);

        const buf = host.alloc(128, 8) orelse return error.OutOfMemory;
        const buf_bytes: [*]u8 = @ptrCast(buf);
        @memcpy(buf_bytes[0..7], "REQUEST");

        if (!std.mem.eql(u8, model_bytes[0..5], "MODEL")) {
            std.debug.print("🔴 Model broke during request {d}\n", .{req});
            std.process.exit(1);
        }

        if (inject) |kind| {
            if (std.mem.eql(u8, kind, "leak")) {
                _ = host.alloc(64, 8);
            } else if (std.mem.eql(u8, kind, "double-free") and req == 0) {
                host.dealloc(buf, 8);
                host.dealloc(buf, 8);
                host.enterDomain(.persistent);
                host.resetRequestArena();
                continue;
            } else if (std.mem.eql(u8, kind, "uaf") and req == 0) {
                leaked_ptr = buf;
            } else if (std.mem.eql(u8, kind, "domain-mix")) {
                if (req == 2) {
                    host.dealloc(model2, 8);
                    std.debug.print("  domain-mix: freed the persistent Cfg during the request phase\n", .{});
                }
            }
        }

        if (!(inject != null and std.mem.eql(u8, inject.?, "leak"))) {
            host.dealloc(buf, 8);
        }

        host.enterDomain(.persistent);
        host.resetRequestArena();

        if (!std.mem.eql(u8, model_bytes[0..5], "MODEL")) {
            std.debug.print("🔴 Model broke after the arena reset (the R13 use-after-free)\n", .{});
            std.process.exit(1);
        }

        if (leaked_ptr) |stale| {
            if (req == 1) {
                std.debug.print("  uaf: deallocating a request pointer after its reset\n", .{});
                host.dealloc(stale, 8);
                leaked_ptr = null;
            }
        }
    }

    std.debug.print("\nafter 3 requests:\n", .{});
    std.debug.print("  Model = \"{s}\"  <- still readable across 3 resets\n", .{model_bytes[0..5]});
    std.debug.print("  Cfg   = {x}\n\n", .{model2_bytes[0..4]});

    // -----------------------------------------------------------------
    // -----------------------------------------------------------------
    const model_intact = std.mem.eql(u8, model_bytes[0..5], "MODEL");

    host.enterDomain(.persistent);
    host.dealloc(model, 16);
    if (!(inject != null and std.mem.eql(u8, inject.?, "domain-mix"))) {
        host.dealloc(model2, 8);
    }

    std.debug.print("result:\n", .{});
    host.report();

    const detected = host.errorCount();
    const leaked = host.persistent_live != 0;

    if (inject) |kind| {
        if (std.mem.eql(u8, kind, "domain-mix")) {
            const ok = detected == 0 and host.domain_mismatch > 0 and model_intact;
            std.debug.print("\n  domain-mix: {d} frees that disagree with the phase -> {s}\n", .{
                host.domain_mismatch,
                if (ok) "✅ returned to the prefix's domain" else "⚠️ not as expected",
            });
            if (!ok) std.process.exit(1);
            return;
        }

        const caught = detected > 0 or leaked;
        std.debug.print("\n  injected \"{s}\" -> {s}\n", .{ kind, if (caught) "✅ detected" else "⚠️ missed" });
        if (!caught) std.process.exit(1);
    } else {
        const ok = detected == 0 and !leaked;
        std.debug.print("\n  {s}\n", .{if (ok) "PASS" else "FAIL"});
        if (!ok) std.process.exit(1);
    }
}
