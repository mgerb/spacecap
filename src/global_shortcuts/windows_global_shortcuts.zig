const std = @import("std");
const GlobalShortcuts = @import("./global_shortcuts.zig").GlobalShortcuts;

pub const WindowsGlobalShortcuts = struct {
    const Self = @This();
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
        };

        return self;
    }

    pub fn run(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        // TODO:
    }

    pub fn stop(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        // TODO:
    }

    pub fn open(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        // TODO:
    }

    pub fn deinit(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        // TODO:
    }

    fn registerShortcutHandler(context: *anyopaque, handler: GlobalShortcuts.ShortcutHandler) void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        _ = handler;
    }

    /// Return the GlobalShortcuts interface
    pub fn global_shortcuts(self: *Self) GlobalShortcuts {
        return .{
            .ptr = self,
            .vtable = &.{
                .run = run,
                .stop = stop,
                .open = open,
                .registerShortcutHandler = registerShortcutHandler,
                .deinit = deinit,
            },
        };
    }
};
