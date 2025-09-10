const std = @import("std");

/// GlobalShortcuts interface
pub const GlobalShortcuts = struct {
    const Self = @This();

    pub const Shortcut = enum {
        save_replay,

        // TODO: Add some comptime stuff and replace the string literals in xdg desktop shortcuts...
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
        registerShortcutHandler: *const fn (*anyopaque, handler: ShortcutHandler) void,
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

    pub fn registerShortcutHandler(self: *Self, handler: ShortcutHandler) void {
        return self.vtable.registerShortcutHandler(self.ptr, handler);
    }

    pub fn deinit(self: *Self) void {
        return self.vtable.deinit(self.ptr);
    }
};
