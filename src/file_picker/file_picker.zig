const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FilePickerError = error{
    PickerCancelled,
};

/// FilePicker interface.
pub const FilePicker = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        open_directory_picker: *const fn (*anyopaque, Allocator, ?[]const u8) anyerror![]u8,
    };

    /// Open a directory picker and return the selected directory path.
    /// The returned path is owned by the caller.
    /// initial_directory - Open in this directory if provided.
    pub fn open_directory_picker(
        self: *Self,
        allocator: Allocator,
        initial_directory: ?[]const u8,
    ) (FilePickerError || anyerror)![]u8 {
        return self.vtable.open_directory_picker(self.ptr, allocator, initial_directory);
    }
};
