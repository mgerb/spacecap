const std = @import("std");

/// Wraps an object in a mutex, requiring locking to gain
/// access to the underlying object.
pub fn Mutex(T: type) type {
    return struct {
        const Self = @This();

        const Locked = struct {
            private: struct {
                value: *T,
                mutex: *std.Thread.Mutex,
            },

            pub fn unwrap(self: @This()) T {
                return self.private.value.*;
            }

            pub fn unwrapPtr(self: @This()) *T {
                return self.private.value;
            }

            pub fn unlock(self: @This()) void {
                self.private.mutex.unlock();
            }

            /// Helper function for setting the value.
            pub fn set(self: *@This(), value: T) void {
                self.private.value.* = value;
            }
        };

        private: struct {
            mutex: std.Thread.Mutex = .{},
            value: T,
        },

        pub fn init(value: T) Self {
            return .{
                .private = .{
                    .value = value,
                },
            };
        }

        pub fn lock(self: *Self) Locked {
            self.private.mutex.lock();
            return .{
                .private = .{
                    .mutex = &self.private.mutex,
                    .value = &self.private.value,
                },
            };
        }

        /// Thread safe set. This differs than the `set` in the locked type
        /// in that it will lock/unlock the mutex. This cannot be used while
        /// the mutex is already locked.
        pub fn set(self: *Self, value: T) void {
            var locked = self.lock();
            defer locked.unlock();
            locked.set(value);
        }
    };
}

test "Mutex lock unwrap and unlock" {
    var mutex: Mutex(i32) = .init(41);

    var locked = mutex.lock();
    defer locked.unlock();

    try std.testing.expectEqual(41, locked.unwrap());
    locked.set(42);
    try std.testing.expectEqual(42, locked.unwrap());
}

test "Mutex set updates value" {
    var mutex: Mutex(i32) = .init(1);

    mutex.set(5);

    var locked = mutex.lock();
    defer locked.unlock();
    try std.testing.expectEqual(5, locked.unwrap());
}

test "Mutex serializes concurrent mutation" {
    var mutex: Mutex(u32) = .init(0);

    const thread_count = 4;
    const iterations = 10_000;

    const Worker = struct {
        fn run(m: *Mutex(u32), n: usize) void {
            for (0..n) |_| {
                var locked = m.lock();
                defer locked.unlock();
                locked.unwrapPtr().* += 1;
            }
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &mutex, iterations });
    }
    for (threads) |thread| {
        thread.join();
    }

    var locked = mutex.lock();
    defer locked.unlock();
    try std.testing.expectEqual(thread_count * iterations, locked.unwrap());
}
