const std = @import("std");

// Thin pthread wrappers. The host avoids std.Io synchronization so that the
// Zig std rework (R10) does not reach the connection hand-off path.

pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.inner) == std.c.E.SUCCESS);
    }

    pub fn unlock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.inner) == std.c.E.SUCCESS);
    }

    /// Takes the lock when no one holds it; false otherwise.
    pub fn tryLock(self: *Mutex) bool {
        return std.c.pthread_mutex_trylock(&self.inner) == std.c.E.SUCCESS;
    }
};

pub const Condition = struct {
    inner: std.c.pthread_cond_t = .{},

    /// Waits with `mutex` held; spurious wakeups are possible.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        std.debug.assert(std.c.pthread_cond_wait(&self.inner, &mutex.inner) == std.c.E.SUCCESS);
    }

    pub fn signal(self: *Condition) void {
        std.debug.assert(std.c.pthread_cond_signal(&self.inner) == std.c.E.SUCCESS);
    }
};

test "condition hands a value to another thread" {
    const Shared = struct {
        mutex: Mutex = .{},
        condition: Condition = .{},
        value: ?u32 = null,

        fn produce(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.value = 42;
            self.condition.signal();
        }
    };

    var shared = Shared{};
    const thread = try std.Thread.spawn(.{}, Shared.produce, .{&shared});
    defer thread.join();

    shared.mutex.lock();
    defer shared.mutex.unlock();
    while (shared.value == null) shared.condition.wait(&shared.mutex);
    try std.testing.expectEqual(@as(?u32, 42), shared.value);
}
