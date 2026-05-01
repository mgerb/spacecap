const std = @import("std");
const Allocator = std.mem.Allocator;
const FilePicker = @import("../file_picker.zig").FilePicker;

pub const WindowsFilePicker = struct {
    const Self = @This();

    pub fn init() !Self {
        return .{};
    }

    // TODO: Take an allocator for the returned owned memory.
    pub fn open_directory_picker(context: *anyopaque, _: Allocator, initial_directory: ?[]const u8) ![]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        _ = initial_directory;
        return error.NotImplemented;
    }

    pub fn deinit(_: *Self) void {}

    pub fn file_picker(self: *Self) FilePicker {
        return .{
            .ptr = self,
            .vtable = &.{
                .open_directory_picker = open_directory_picker,
            },
        };
    }
};
