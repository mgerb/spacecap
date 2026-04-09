const std = @import("std");
const FilePicker = @import("../file_picker.zig").FilePicker;

pub const WindowsFilePicker = struct {
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

    pub fn open_directory_picker(context: *anyopaque, initial_directory: ?[]const u8) ![]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        _ = initial_directory;
        return error.NotImplemented;
    }

    pub fn deinit(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.allocator.destroy(self);
    }

    pub fn file_picker(self: *Self) FilePicker {
        return .{
            .ptr = self,
            .vtable = &.{
                .open_directory_picker = open_directory_picker,
                .deinit = deinit,
            },
        };
    }
};
