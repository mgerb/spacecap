const std = @import("std");
const Actor = @import("../../state/actor.zig").Actor;
const Ipc = @import("../ipc.zig").Ipc;
const IpcCommand = @import("../ipc.zig").IpcCommand;

pub const WindowsIpc = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, actor: ?*Actor) !*Self {
        _ = actor;
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }

    pub fn start(context: *anyopaque) !void {
        _ = context;
    }

    pub fn deinit(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.allocator.destroy(self);
    }

    pub fn send_command(context: *anyopaque, command: IpcCommand) !void {
        _ = context;
        _ = command;
        return error.UnsupportedPlatform;
    }

    pub fn ipc(self: *Self) Ipc {
        return .{
            .ptr = self,
            .vtable = &.{
                .start = start,
                .send_command = send_command,
                .deinit = deinit,
            },
        };
    }
};
