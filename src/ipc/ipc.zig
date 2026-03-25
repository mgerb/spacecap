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
        send_command: *const fn (*anyopaque, IpcCommand) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    /// e.g. start an IPC server.
    pub fn start(self: *Self) !void {
        return self.vtable.start(self.ptr);
    }

    pub fn send_command(self: *Self, command: IpcCommand) !void {
        return self.vtable.send_command(self.ptr, command);
    }

    pub fn deinit(self: *Self) void {
        return self.vtable.deinit(self.ptr);
    }
};
