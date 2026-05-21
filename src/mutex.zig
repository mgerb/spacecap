const std = @import("std");

/// Wraps an object in a mutex, requiring locking to gain
/// access to the underlying object.
pub fn Mutex(T: type) type {
    return struct {
        const Self = @This();

        const Locked = struct {
            private: struct {
                io: std.Io,
                value: *T,
                mutex: *std.Io.Mutex,
            },

            pub fn unwrap(self: @This()) T {
                return self.private.value.*;
            }

            pub fn unwrap_ptr(self: @This()) *T {
                return self.private.value;
            }

            pub fn unlock(self: @This()) void {
                self.private.mutex.unlock(self.private.io);
            }

            /// Helper function for setting the value.
            pub fn set(self: *@This(), value: T) void {
                self.private.value.* = value;
            }
        };

        private: struct {
            io: std.Io,
            mutex: std.Io.Mutex = .init,
            value: T,
        },

        pub fn init(io: std.Io, value: T) Self {
            return .{
                .private = .{
                    .io = io,
                    .value = value,
                },
            };
        }

        /// If the underlying data type has a deinit method, then call it. This
        /// is not thread safe. The lock should be acquired from the caller.
        /// Generally this should not be used directly. It was implemented so
        /// that Arc could work with Mutex [e.g. Arc(Mutex(T))]. Arc does not
        /// lock when it calls this deinit, but in practice Arc is only ever
        /// going to call deinit when there is a single reference so the
        /// object.
        pub fn deinit(self: *Self) void {
            if (@hasDecl(T, "deinit")) {
                self.private.value.deinit();
            }
        }

        pub fn lock(self: *Self) Locked {
            self.private.mutex.lockUncancelable(self.private.io);
            return .{
                .private = .{
                    .io = self.private.io,
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

test "Mutex - lock unwrap and unlock" {
    var mutex: Mutex(i32) = .init(std.testing.io, 41);

    var locked = mutex.lock();
    defer locked.unlock();

    try std.testing.expectEqual(41, locked.unwrap());
    locked.set(42);
    try std.testing.expectEqual(42, locked.unwrap());
}

test "Mutex - set updates value" {
    var mutex: Mutex(i32) = .init(std.testing.io, 1);

    mutex.set(5);

    var locked = mutex.lock();
    defer locked.unlock();
    try std.testing.expectEqual(5, locked.unwrap());
}

test "Mutex - serializes concurrent mutation" {
    var mutex: Mutex(u32) = .init(std.testing.io, 0);

    const thread_count = 4;
    const iterations = 10_000;

    const Worker = struct {
        fn run(m: *Mutex(u32), n: usize) void {
            for (0..n) |_| {
                var locked = m.lock();
                defer locked.unlock();
                locked.unwrap_ptr().* += 1;
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
