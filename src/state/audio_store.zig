const std = @import("std");
const Allocator = std.mem.Allocator;
const AudioSession = @import("./audio_session.zig").AudioSession;
const Store = @import("./store.zig").Store;

pub const AudioStore = struct {
    const Self = @This();

    audio_session: ?AudioSession = null,

    pub const Message = union(enum) {
        thing,

        pub const effects = .{};
    };

    pub const State = struct {};

    pub fn init() Self {
        return .{};
    }

    pub fn update(allocator: Allocator, msg: Store.Message, state: *Store.State) !void {
        _ = allocator;
        _ = msg;
        _ = state;
    }
};
