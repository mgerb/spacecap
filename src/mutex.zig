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

        /// Thread safe set.
        pub fn set(self: *Self, value: T) void {
            const locked = self.lock();
            defer locked.unlock();
            locked.unwrapPtr().* = value;
        }
    };
}
