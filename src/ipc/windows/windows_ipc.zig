const std = @import("std");
const Store = @import("../../store/store.zig").Store;
const Ipc = @import("../ipc.zig").Ipc;
const IpcCommand = @import("../ipc.zig").IpcCommand;

pub const WindowsIpc = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, _: std.Io, store: ?*Store) !*Self {
        _ = store;
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
