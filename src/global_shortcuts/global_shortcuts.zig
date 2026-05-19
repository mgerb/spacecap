const std = @import("std");

/// GlobalShortcuts interface
pub const GlobalShortcuts = struct {
    const Self = @This();

    pub const Shortcut = enum {
        save_replay,
        start_replay_buffer,
        stop_replay_buffer,
        toggle_replay_buffer,
        start_recording,
        stop_recording,
        toggle_recording,

        pub const all = std.enums.values(Shortcut);

        pub fn id(self: Shortcut) []const u8 {
            return @tagName(self);
        }

        pub fn display_name(self: Shortcut) []const u8 {
            return switch (self) {
                .save_replay => "Save Replay",
                .start_replay_buffer => "Start Replay Buffer",
                .stop_replay_buffer => "Stop Replay Buffer",
                .toggle_replay_buffer => "Toggle Replay Buffer",
                .start_recording => "Start Recording",
                .stop_recording => "Stop Recording",
                .toggle_recording => "Toggle Recording",
            };
        }

        pub fn ids() [all.len][]const u8 {
            var result: [all.len][]const u8 = undefined;
            for (all, 0..) |shortcut, index| {
                result[index] = shortcut.id();
            }
            return result;
        }
    };

    pub const ShortcutHandler = struct {
        ptr: *anyopaque,
        handler: *const fn (ptr: *anyopaque, shortcut: Shortcut) void,

        pub fn invoke(self: *@This(), shortcut: Shortcut) void {
            self.handler(self.ptr, shortcut);
        }
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        run: *const fn (*anyopaque) anyerror!void,
        stop: *const fn (*anyopaque) void,
        open: *const fn (*anyopaque) anyerror!void,
        register_shortcut_handler: *const fn (*anyopaque, handler: ShortcutHandler) void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn run(self: *Self) !void {
        return self.vtable.run(self.ptr);
    }

    pub fn stop(self: *Self) void {
        return self.vtable.stop(self.ptr);
    }

    pub fn open(self: *Self) !void {
        return self.vtable.open(self.ptr);
    }

    pub fn register_shortcut_handler(self: *Self, handler: ShortcutHandler) void {
        return self.vtable.register_shortcut_handler(self.ptr, handler);
    }

    pub fn deinit(self: *Self) void {
        return self.vtable.deinit(self.ptr);
    }
};
