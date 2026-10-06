//! Testing utils.

const std = @import("std");

/// If this is set, util.get_app_data_dir will return this. If any unit
/// tests rely on the user settings, then they must init/destroy this dir.
pub var TEST_APP_DATA_DIR: ?[]u8 = null;

pub fn init_temp_app_data_dir() !void {
    var tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    var app_data_dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const app_data_dir_len = try tmp_dir.dir.realPathFile(std.testing.io, ".", &app_data_dir_buffer);
    const app_data_dir = try std.testing.allocator.dupe(u8, app_data_dir_buffer[0..app_data_dir_len]);
    TEST_APP_DATA_DIR = app_data_dir;
}

pub fn destroy_temp_app_data_dir() void {
    if (TEST_APP_DATA_DIR) |t| {
        std.testing.allocator.free(t);
    }
}
