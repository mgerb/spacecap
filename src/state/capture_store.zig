const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("./store.zig").Store;
const Message = @import("./store.zig").Message;
const State = @import("./store.zig").State;

pub const CaptureMessage = union(enum) {
    start: i32,
    stop,

    pub const effects = .{
        .start = .{effect_start},
    };
};

pub const CaptureState = struct {
    replay_buffer: struct {
        video_size: u64 = 0,
        audio_size: u64 = 0,
        seconds: u64 = 0,
    } = .{},
};

pub fn update(_: Allocator, msg: Message, state: *State) !void {
    _ = msg;
    _ = state;
}

fn effect_start(store: *Store, _: i32) void {
    _ = store;
    std.debug.print("test1\n", .{});
}
