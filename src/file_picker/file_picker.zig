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
        open_directory_picker: *const fn (*anyopaque, Allocator, std.Io, ?[]const u8) anyerror![]u8,
        show_in_file_explorer: *const fn (*anyopaque, Allocator, std.Io, []const u8) anyerror!void,
        open_file_with_default_app: *const fn (*anyopaque, Allocator, std.Io, []const u8) anyerror!void,
    };

    /// Open a directory picker and return the selected directory path.
    /// The returned path is owned by the caller.
    /// initial_directory - Open in this directory if provided.
    pub fn open_directory_picker(
        self: *Self,
        allocator: Allocator,
        io: std.Io,
        initial_directory: ?[]const u8,
    ) (FilePickerError || anyerror)![]u8 {
        return self.vtable.open_directory_picker(self.ptr, allocator, io, initial_directory);
    }

    /// Open the system file explorer at the given file, selecting it when supported.
    pub fn show_in_file_explorer(
        self: *Self,
        allocator: Allocator,
        io: std.Io,
        file_path: []const u8,
    ) anyerror!void {
        return self.vtable.show_in_file_explorer(self.ptr, allocator, io, file_path);
    }

    /// Open a file with the system's default application.
    pub fn open_file_with_default_app(
        self: *Self,
        allocator: Allocator,
        io: std.Io,
        file_path: []const u8,
    ) anyerror!void {
        return self.vtable.open_file_with_default_app(self.ptr, allocator, io, file_path);
    }
};
