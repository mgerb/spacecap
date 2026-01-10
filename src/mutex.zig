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
