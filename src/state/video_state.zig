const std = @import("std");
const Actor = @import("./actor.zig").Actor;
const Actions = @import("./actor.zig").Actions;

pub const VideoActions = union(enum) {
    test123,
};

pub const VideoState = struct {
    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn handle_action(self: *Self, actor: *Actor, action: Actions) !void {
        _ = self;
        _ = actor;

        switch (action) {
            .video => |video_action| {
                switch (video_action) {
                    else => {},
                }
            },
            else => {},
        }
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};
