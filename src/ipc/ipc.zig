const std = @import("std");

pub const IpcCommand = enum {
    save_replay,
};

/// IPC interface.
pub const Ipc = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        start: *const fn (*anyopaque) anyerror!void,
        sendCommand: *const fn (*anyopaque, IpcCommand) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    /// e.g. start an IPC server.
    pub fn start(self: *Self) !void {
        return self.vtable.start(self.ptr);
    }

    pub fn sendCommand(self: *Self, command: IpcCommand) !void {
        return self.vtable.sendCommand(self.ptr, command);
    }

    pub fn deinit(self: *Self) void {
        return self.vtable.deinit(self.ptr);
    }
};
