const std = @import("std");

pub const FilePickerError = error{
    PickerCancelled,
};

/// FilePicker interface.
pub const FilePicker = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        open_directory_picker: *const fn (*anyopaque, ?[]const u8) anyerror![]u8,
        deinit: *const fn (*anyopaque) void,
    };

    /// Open a directory picker and return the selected directory path.
    /// The returned path is owned by the caller.
    /// initial_directory - Open in this directory if provided.
    pub fn open_directory_picker(self: *Self, initial_directory: ?[]const u8) (FilePickerError || anyerror)![]u8 {
        return self.vtable.open_directory_picker(self.ptr, initial_directory);
    }

    pub fn deinit(self: *Self) void {
        return self.vtable.deinit(self.ptr);
    }
};
