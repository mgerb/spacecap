const std = @import("std");
const Actor = @import("../../actor.zig").Actor;
const Ipc = @import("../ipc.zig").Ipc;
const IpcCommand = @import("../ipc.zig").IpcCommand;
const IpcServer = @import("./linux_ipc_server.zig").IpcServer;

const log = std.log.scoped(.linux_ipc);

pub const LinuxIpc = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    actor: ?*Actor,
    server: ?IpcServer = null,

    pub fn init(allocator: std.mem.Allocator, actor: ?*Actor) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .actor = actor,
            .server = null,
        };
        return self;
    }

    pub fn deinit(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }
        self.allocator.destroy(self);
    }

    pub fn start(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.server != null) {
            return;
        }

        const actor = self.actor orelse return error.ActorRequired;
        self.server = try IpcServer.init(self.allocator, actor);
        errdefer {
            if (self.server) |*server| {
                server.deinit();
                self.server = null;
            }
        }
        try self.server.?.start();
    }

    pub fn sendCommand(context: *anyopaque, command: IpcCommand) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        try IpcServer.sendIpcCommand(self.allocator, command);
    }

    pub fn ipc(self: *Self) Ipc {
        return .{
            .ptr = self,
            .vtable = &.{
                .start = start,
                .sendCommand = sendCommand,
                .deinit = deinit,
            },
        };
    }
};
