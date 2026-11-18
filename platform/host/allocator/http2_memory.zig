//! The transport and decoder heaps draw from one ceiling per worker process.
pub const Budget = @import("budget.zig").Budget;
pub var shared = Budget{ .backing = @import("std").heap.smp_allocator, .limit = 128 * 1024 * 1024 };
