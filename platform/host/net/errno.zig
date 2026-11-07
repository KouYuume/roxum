const std = @import("std");

/// The errno of the last failed C call on this thread.
pub fn lastError() std.c.E {
    return @enumFromInt(std.c._errno().*);
}
