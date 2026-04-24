const args = @import("../args.zig");

pub const IpcCommand = enum {
    save_replay,
    start_replay_buffer,
    stop_replay_buffer,
    toggle_replay_buffer,
    start_recording,
    stop_recording,
    toggle_recording,

    pub fn from_send_command(send_cmd: args.SendCommand) @This() {
        return switch (send_cmd) {
            .@"save-replay" => .save_replay,
            .@"start-replay-buffer" => .start_replay_buffer,
            .@"stop-replay-buffer" => .stop_replay_buffer,
            .@"toggle-replay-buffer" => .toggle_replay_buffer,
            .@"start-recording" => .start_recording,
            .@"stop-recording" => .stop_recording,
            .@"toggle-recording" => .toggle_recording,
        };
    }
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
    /// WARNING: Must not block.
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
