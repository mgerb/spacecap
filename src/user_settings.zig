const std = @import("std");

pub const UserSettings = struct {
    const Self = @This();
    gui_foreground_fps: u32 = 120,
    gui_background_fps: u32 = 30,

    /// Returns copy of user settings. No need to free.
    pub fn load(allocator: std.mem.Allocator) !Self {
        const app_data_dir = try getAppDataDir(allocator);
        defer allocator.free(app_data_dir);

        const settings_path = try std.fs.path.join(allocator, &.{ app_data_dir, "settings.json" });
        defer allocator.free(settings_path);

        const file = std.fs.openFileAbsolute(settings_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // Return default settings if the file doesn't exist
                return .{};
            }
            return err;
        };
        defer file.close();

        const stat = try file.stat();

        var reader = file.reader(&.{});
        const file_contents = try reader.interface.readAlloc(allocator, stat.size);
        defer allocator.free(file_contents);
        const res = try std.json.parseFromSlice(Self, allocator, file_contents, .{ .ignore_unknown_fields = true });
        defer res.deinit();
        return res.value;
    }

    pub fn save(self: Self, allocator: std.mem.Allocator) !void {
        const app_data_dir = try getAppDataDir(allocator);
        defer allocator.free(app_data_dir);

        const settings_path = try std.fs.path.join(allocator, &.{ app_data_dir, "settings.json" });
        defer allocator.free(settings_path);

        const file = try std.fs.createFileAbsolute(settings_path, .{});
        defer file.close();

        var writer = file.writer(&.{});
        var stringify: std.json.Stringify = .{ .writer = &writer.interface };
        try stringify.write(self);
    }
};

pub const UserSettingsError = error{
    HomeDirNotFound,
    ConfigDirNotFound,
    OutOfMemory,
};

/// Returns the platform-specific application data directory.
/// For example:
/// - Windows: %APPDATA%\spacecap
/// - Linux: $XDG_CONFIG_HOME/spacecap or $HOME/.config/spacecap
/// The returned path is owned by the caller and must be freed.
/// This function will create the directory if it does not exist.
pub fn getAppDataDir(allocator: std.mem.Allocator) ![]u8 {
    // TODO: test on windows
    const base_dir: []u8 = if (@import("builtin").os.tag == .windows) blk: {
        // On Windows, use %APPDATA%
        break :blk try std.process.getEnvVarOwned(allocator, "APPDATA");
    } else if (@import("builtin").os.tag == .linux) blk: {
        // On Linux, use $XDG_CONFIG_HOME or $HOME/.config
        if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg_config_home| {
            break :blk xdg_config_home;
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                const home = try std.process.getEnvVarOwned(allocator, "HOME");
                defer allocator.free(home);
                break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
            },
            else => return err,
        }
    } else {
        @compileError("Unsupported OS");
    };
    defer allocator.free(base_dir);

    const app_config_dir = try std.fs.path.join(allocator, &.{ base_dir, "spacecap" });

    // Ensure the directory exists
    std.fs.makeDirAbsolute(app_config_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    return app_config_dir;
}
