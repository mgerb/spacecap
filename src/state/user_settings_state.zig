const std = @import("std");
const Allocator = std.mem.Allocator;
const StateActor = @import("../state_actor.zig").StateActor;
const util = @import("../util.zig");

const log = std.log.scoped(.user_settings_state);

pub const UserSettingsActions = union(enum) {
    set_gui_foreground_fps: u32,
    set_gui_background_fps: u32,
    set_audio_device_settings: struct {
        device_id: []u8,
        selected: bool,
        gain: f32,
    },
};

pub const UserSettingsState = struct {
    const Self = @This();

    allocator: Allocator,
    settings: UserSettings = .{},

    pub fn init(allocator: Allocator) !Self {
        var self: Self = .{
            .allocator = allocator,
        };
        self.load() catch |err| {
            log.err("unable to load user settings: {}\n", .{err});
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.settings.deinit(self.allocator);
    }

    pub fn handleActions(self: *Self, state_actor: *StateActor, action: UserSettingsActions) !void {
        switch (action) {
            .set_gui_foreground_fps => |fps| {
                var settings_snapshot: UserSettings = undefined;
                {
                    state_actor.ui_mutex.lock();
                    defer state_actor.ui_mutex.unlock();
                    self.settings.gui_foreground_fps = fps;
                    settings_snapshot = try self.settings.clone(self.allocator);
                }
                defer settings_snapshot.deinit(self.allocator);
                try self.save(&settings_snapshot);
            },
            .set_gui_background_fps => |fps| {
                var settings_snapshot: UserSettings = undefined;
                {
                    state_actor.ui_mutex.lock();
                    defer state_actor.ui_mutex.unlock();
                    self.settings.gui_background_fps = fps;
                    settings_snapshot = try self.settings.clone(self.allocator);
                }
                defer settings_snapshot.deinit(self.allocator);
                try self.save(&settings_snapshot);
            },
            .set_audio_device_settings => |payload| {
                defer self.allocator.free(payload.device_id);
                var settings_snapshot: UserSettings = undefined;
                {
                    state_actor.ui_mutex.lock();
                    defer state_actor.ui_mutex.unlock();
                    try self.settings.updateAudioDeviceSettings(
                        self.allocator,
                        payload.device_id,
                        payload.selected,
                        payload.gain,
                    );
                    settings_snapshot = try self.settings.clone(self.allocator);
                }
                defer settings_snapshot.deinit(self.allocator);
                try self.save(&settings_snapshot);
            },
        }
    }

    /// Read the settings json file if it exists, otherwise use defaults.
    fn load(self: *Self) !void {
        const app_data_dir = try util.getAppDataDir(self.allocator);
        defer self.allocator.free(app_data_dir);

        const settings_path = try std.fs.path.join(self.allocator, &.{ app_data_dir, "settings.json" });
        defer self.allocator.free(settings_path);

        const file = std.fs.openFileAbsolute(settings_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return;
            }
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        var reader = file.reader(&.{});
        const file_contents = try reader.interface.readAlloc(self.allocator, stat.size);
        defer self.allocator.free(file_contents);

        const parsed = try std.json.parseFromSlice(UserSettings, self.allocator, file_contents, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var loaded: UserSettings = .{
            .gui_foreground_fps = parsed.value.gui_foreground_fps,
            .gui_background_fps = parsed.value.gui_background_fps,
        };
        errdefer loaded.deinit(self.allocator);

        var iter = parsed.value.audio_devices.map.iterator();
        while (iter.next()) |entry| {
            const audio_device = entry.value_ptr.*;
            const device_id = if (audio_device.id.len > 0) audio_device.id else entry.key_ptr.*;
            try loaded.updateAudioDeviceSettings(
                self.allocator,
                device_id,
                audio_device.selected,
                audio_device.gain,
            );
        }

        self.settings.deinit(self.allocator);
        self.settings = loaded;
    }

    /// Save a copy of settings to disk.
    /// NOTE: It is important to call this outside of the UI lock.
    fn save(self: *const Self, settings: *const UserSettings) !void {
        const app_data_dir = try util.getAppDataDir(self.allocator);
        defer self.allocator.free(app_data_dir);

        const settings_path = try std.fs.path.join(self.allocator, &.{ app_data_dir, "settings.json" });
        defer self.allocator.free(settings_path);

        const file = try std.fs.createFileAbsolute(settings_path, .{});
        defer file.close();

        var writer = file.writer(&.{});
        var stringify: std.json.Stringify = .{ .writer = &writer.interface };
        try stringify.write(settings.*);
    }
};

/// NOTE: This MUST remain serializable.
const UserSettings = struct {
    const AudioDeviceSettings = struct {
        id: []const u8 = "",
        selected: bool = false,
        gain: f32 = 1.0,
    };

    gui_foreground_fps: u32 = 120,
    gui_background_fps: u32 = 30,
    audio_devices: std.json.ArrayHashMap(AudioDeviceSettings) = .{},

    fn deinit(self: *@This(), allocator: Allocator) void {
        self.clearAudioDeviceSettings(allocator);
        self.audio_devices.deinit(allocator);
    }

    fn updateAudioDeviceSettings(
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

    fn clearAudioDeviceSettings(self: *@This(), allocator: Allocator) void {
        var iter = self.audio_devices.map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.audio_devices.map.clearRetainingCapacity();
    }

    /// Deep copy user settings.
    fn clone(self: @This(), allocator: Allocator) !@This() {
        var settings_copy: @This() = .{
            .gui_foreground_fps = self.gui_foreground_fps,
            .gui_background_fps = self.gui_background_fps,
        };
        errdefer settings_copy.deinit(allocator);

        var iter = self.audio_devices.map.iterator();
        while (iter.next()) |entry| {
            const audio_device = entry.value_ptr.*;
            const device_id = if (audio_device.id.len > 0) audio_device.id else entry.key_ptr.*;
            try settings_copy.updateAudioDeviceSettings(
                allocator,
                device_id,
                audio_device.selected,
                audio_device.gain,
            );
        }

        return settings_copy;
    }
};
