const std = @import("std");
const Allocator = std.mem.Allocator;

/// Atomically reference counted pointer. See tests for examples.
pub fn Arc(comptime T: type) type {

    // The underlying data type must implement the 'deinit' method, otherwise
    // Arc has now way of knowing how to clean up.
    if (!@hasDecl(T, "deinit")) {
        @compileError(@typeName(T) ++ " must contain a 'deinit' method.");
    }

    const Internal = struct {
        ref_count: std.atomic.Value(u32) = .init(1),
        value: T,
    };

    return struct {
        const Self = @This();

        allocator: Allocator,
        internal: *Internal,

        /// Allocate T on the heap and keep a reference counted pointer to it.
        pub fn init(allocator: Allocator, value: T) !Self {
            const internal = try allocator.create(Internal);
            internal.* = .{
                .value = value,
            };
            return .{
                .allocator = allocator,
                .internal = internal,
            };
        }

        /// Check if there is only one reference and if so, then call 'deinit'
        /// on the underlying data. Taken from the example in zig std docs
        /// here: https://ziglang.org/documentation/master/std/#std.atomic.Value
        pub fn deinit(self: *const Self) void {
            if (self.internal.ref_count.fetchSub(1, .release) == 1) {
                defer self.allocator.destroy(self.internal);
                _ = self.internal.ref_count.load(.acquire);
                self.internal.value.deinit();
            }
        }

        /// Increases the ref count and returns a new Arc.
        pub fn clone(self: *const Self) Self {
            _ = self.internal.ref_count.fetchAdd(1, .monotonic);
            return self.*;
        }

        /// Get a pointer to the underlying data.
        pub fn as_ptr(self: *const Self) *T {
            return &self.internal.value;
        }
    };
}

const TestUtil = struct {
    const Data = struct {
        allocator: Allocator,
        value: u32 = 0,
        allocated_string: []const u8,

        pub fn init(allocator: Allocator, str: []const u8) !@This() {
            return .{
                .allocator = allocator,
                .allocated_string = try allocator.dupe(u8, str),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.allocated_string);
        }
    };
};

test "Arc - clone" {
    const allocator = std.testing.allocator;
    var data: Arc(TestUtil.Data) = try .init(allocator, try .init(allocator, "test1"));
    defer data.deinit();

    var cloned_data = data.clone();

    try std.testing.expectEqual(data.as_ptr(), cloned_data.as_ptr());

    cloned_data.deinit();

    try std.testing.expectEqual(data.as_ptr(), cloned_data.as_ptr());
}

test "Arc - clone on multiple threads (with Mutex)" {
    const Mutex = @import("./mutex.zig").Mutex;
    const allocator = std.testing.allocator;
    var data: Arc(Mutex(TestUtil.Data)) = try .init(allocator, .init(std.testing.io, try .init(allocator, "test1")));
    defer data.deinit();

    const thread = struct {
        fn run(d: Arc(Mutex(TestUtil.Data))) void {
            var _data = d;
            defer _data.deinit();

            var data_locked = _data.as_ptr().lock();
            defer data_locked.unlock();
            data_locked.unwrap_ptr().value += 1;
        }
    };

    const th1 = try std.Thread.spawn(.{}, thread.run, .{data.clone()});
    const th2 = try std.Thread.spawn(.{}, thread.run, .{data.clone()});

    th1.join();
    th2.join();

    {
        var data_locked = data.as_ptr().lock();
        defer data_locked.unlock();
        try std.testing.expectEqual(data_locked.unwrap_ptr().value, 2);
    }
}
