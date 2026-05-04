const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("./store.zig").Store;

pub const Message = union(enum) {
    start: i32,
    stop,

    pub const effects = .{
        .start = .{effect_start},
    };
};

pub const State = struct {
    replay_buffer: struct {
        video_size: u64 = 0,
        audio_size: u64 = 0,
        seconds: u64 = 0,
    } = .{},
};

pub fn update(_: Allocator, msg: Store.Message, state: *Store.State) !void {
    _ = msg;
    _ = state;
}

fn effect_start(store: *Store, _: i32) void {
    _ = store;
    std.debug.print("test1\n", .{});
}
