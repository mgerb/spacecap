const std = @import("std");
const Allocator = std.mem.Allocator;
const String = @import("../string.zig").String;
const util = @import("../util.zig");

const log = std.log.scoped(.user_settings);

const SETTINGS_JSON = "settings.json";

/// NOTE: This MUST remain JSON serializable.
pub const UserSettings = struct {
    pub const AudioDeviceSettings = struct {
        id: []const u8,
        selected: bool = false,
        gain: f32 = 1.0,
    };

    /// WARN: All field must have a default value! This is required
    /// for when we parse the settings.json file.
    capture_fps: u32 = 60,
    /// In bits per second (bps).
    capture_bit_rate: u64 = 10_000_000,
    replay_seconds: u32 = 30,
    start_replay_buffer_on_startup: bool = false,
    restore_capture_source_on_startup: bool = true,
    // Doesn't have a default value because an allocator is
    // required to find the directory. It must be set before
    // settings are used anywhere.
    video_output_directory: ?String = null,
    audio_devices: std.json.ArrayHashMap(AudioDeviceSettings) = .{},

    /// Read the settings json file if it exists, otherwise use defaults.
    pub fn init(allocator: Allocator) !UserSettings {
        // Catch file read errors because we don't want to crash if
        // something goes wrong with the settings file.
        return _init(allocator) catch |err| {
            if (err != error.FileNotFound) {
                log.err("[init] error loading settings file: {}", .{err});
            }
            return try default_settings(allocator);
        };
    }

    pub fn _init(allocator: Allocator) !UserSettings {
        const app_data_dir = try util.get_app_data_dir(allocator);
        defer allocator.free(app_data_dir);

        const settings_path = try std.fs.path.join(allocator, &.{ app_data_dir, SETTINGS_JSON });
        defer allocator.free(settings_path);

        const file = std.fs.openFileAbsolute(settings_path, .{}) catch |err| {
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        var reader = file.reader(&.{});
        const file_contents = try reader.interface.readAlloc(allocator, stat.size);
        defer allocator.free(file_contents);

        const parsed = try std.json.parseFromSlice(UserSettings, allocator, file_contents, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var loaded = try parsed.value.clone(allocator);
        errdefer loaded.deinit(allocator);

        if (loaded.video_output_directory == null) {
            const video_output_directory = try util.get_default_video_output_dir(allocator);
            defer allocator.free(video_output_directory);
            loaded.video_output_directory = try String.from(allocator, video_output_directory);
        }

        return loaded;
    }

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.clear_video_output_directory();
        self.clear_audio_device_settings(allocator);
        self.audio_devices.deinit(allocator);
    }

    fn default_settings(allocator: Allocator) !UserSettings {
        const video_output_directory = try util.get_default_video_output_dir(allocator);
        defer allocator.free(video_output_directory);
        return .{
            .video_output_directory = try String.from(allocator, video_output_directory),
        };
    }

    /// directory - Is owned by this method.
    pub fn set_video_output_directory(
        self: *@This(),
        directory: ?String,
    ) !void {
        self.clear_video_output_directory();
        if (directory) |_directory| {
            self.video_output_directory = _directory;
        }
    }

    pub fn update_audio_device_settings(
        self: *@This(),
        allocator: Allocator,
        id: []const u8,
        selected: bool,
        gain: f32,
    ) !void {
        const id_copy = try allocator.dupe(u8, id);
        errdefer allocator.free(id_copy);

        const audio_device_settings = try self.audio_devices.map.getOrPut(allocator, id_copy);
        if (audio_device_settings.found_existing) {
            allocator.free(id_copy);
            const audio_device = audio_device_settings.value_ptr;
            audio_device.selected = selected;
            audio_device.gain = gain;
        } else {
            audio_device_settings.value_ptr.* = .{
                .id = audio_device_settings.key_ptr.*,
                .selected = selected,
                .gain = gain,
            };
        }
    }

    fn clear_audio_device_settings(self: *@This(), allocator: Allocator) void {
        var iter = self.audio_devices.map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.audio_devices.map.clearRetainingCapacity();
    }

    fn clear_video_output_directory(self: *@This()) void {
        if (self.video_output_directory) |*video_output_directory| {
            video_output_directory.deinit();
            self.video_output_directory = null;
        }
    }

    /// Deep copy user settings.
    pub fn clone(self: @This(), allocator: Allocator) !@This() {
        var settings_copy = self;
        settings_copy.video_output_directory = null;
        settings_copy.audio_devices = .{};
        errdefer settings_copy.deinit(allocator);

        try settings_copy.set_video_output_directory(
            if (self.video_output_directory) |directory|
                try directory.clone(allocator)
            else
                null,
        );

        var iter = self.audio_devices.map.iterator();
        while (iter.next()) |entry| {
            const audio_device = entry.value_ptr.*;
            const device_id = if (audio_device.id.len > 0) audio_device.id else entry.key_ptr.*;
            try settings_copy.update_audio_device_settings(
                allocator,
                device_id,
                audio_device.selected,
                audio_device.gain,
            );
        }

        return settings_copy;
    }

    /// Save a copy of settings to disk.
    /// NOTE: It is important to call this outside of the UI lock.
    pub fn save(self: *@This(), allocator: Allocator) !void {
        const app_data_dir = try util.get_app_data_dir(allocator);
        defer allocator.free(app_data_dir);

        const settings_path = try std.fs.path.join(allocator, &.{ app_data_dir, SETTINGS_JSON });
        defer allocator.free(settings_path);

        const file = try std.fs.createFileAbsolute(settings_path, .{});
        defer file.close();

        var writer = file.writer(&.{});
        var stringify: std.json.Stringify = .{ .writer = &writer.interface };
        try stringify.write(self.*);
    }
};
