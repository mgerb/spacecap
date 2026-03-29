const std = @import("std");
const Allocator = std.mem.Allocator;
const Actor = @import("./actor.zig").Actor;
const ActionPayload = @import("./action_payload.zig").ActionPayload;
const util = @import("../util.zig");
const Actions = @import("./actor.zig").Actions;

const log = std.log.scoped(.user_settings_state);

pub const UserSettingsActions = union(enum) {
    set_capture_fps: u32,
    set_capture_bit_rate: u64,
    set_replay_seconds: u32,
    set_gui_foreground_fps: u32,
    set_gui_background_fps: u32,
    set_audio_device_settings: *ActionPayload(struct {
        device_id: []u8,
        selected: bool,
        gain: f32,

        pub fn init(
            arena: *std.heap.ArenaAllocator,
            args: struct { device_id: []u8, selected: bool, gain: f32 },
        ) !@This() {
            return .{
                .device_id = try arena.allocator().dupe(u8, args.device_id),
                .selected = args.selected,
                .gain = args.gain,
            };
        }
    }),
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

    pub fn handle_action(self: *Self, actor: *Actor, action: Actions) !void {
        switch (action) {
            .user_settings => |user_settings_action| {
                switch (user_settings_action) {
                    .set_capture_fps => |capture_fps| {
                        try self.set_state(actor, "capture_fps", capture_fps);
                        try actor.video_capture.update_fps(capture_fps);
                    },
                    .set_capture_bit_rate => |capture_bit_rate| {
                        try self.set_state(actor, "capture_bit_rate", capture_bit_rate);
                    },
                    .set_replay_seconds => |replay_seconds| {
                        try self.set_state(actor, "replay_seconds", replay_seconds);
                    },
                    .set_gui_foreground_fps => |gui_foreground_fps| {
                        try self.set_state(actor, "gui_foreground_fps", gui_foreground_fps);
                    },
                    .set_gui_background_fps => |gui_background_fps| {
                        try self.set_state(actor, "gui_background_fps", gui_background_fps);
                    },
                    .set_audio_device_settings => |_action| {
                        defer _action.deinit();
                        const payload = _action.payload;
                        var settings_snapshot: UserSettings = undefined;
                        {
                            actor.ui_mutex.lock();
                            defer actor.ui_mutex.unlock();
                            try self.settings.update_audio_device_settings(
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
            },
            else => {},
        }
    }

    /// Helper function to set a value on the state.
    ///
    /// Locks the UI mutex.
    /// Updates the field.
    /// Deep copy the settings.
    /// Then save (write to disk).
    ///
    /// `field_name` a field on the UserSettings type.
    fn set_state(
        self: *Self,
        actor: *Actor,
        comptime field_name: []const u8,
        value: anytype,
    ) !void {
        var settings_snapshot: UserSettings = blk: {
            actor.ui_mutex.lock();
            defer actor.ui_mutex.unlock();
            @field(self.settings, field_name) = value;
            break :blk try self.settings.clone(self.allocator);
        };
        defer settings_snapshot.deinit(self.allocator);
        try self.save(&settings_snapshot);
    }

    /// Read the settings json file if it exists, otherwise use defaults.
    fn load(self: *Self) !void {
        const app_data_dir = try util.get_app_data_dir(self.allocator);
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
            .capture_fps = parsed.value.capture_fps,
            .capture_bit_rate = parsed.value.capture_bit_rate,
            .replay_seconds = parsed.value.replay_seconds,
            .gui_foreground_fps = parsed.value.gui_foreground_fps,
            .gui_background_fps = parsed.value.gui_background_fps,
        };
        errdefer loaded.deinit(self.allocator);

        var iter = parsed.value.audio_devices.map.iterator();
        while (iter.next()) |entry| {
            const audio_device = entry.value_ptr.*;
            const device_id = if (audio_device.id.len > 0) audio_device.id else entry.key_ptr.*;
            try loaded.update_audio_device_settings(
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
        const app_data_dir = try util.get_app_data_dir(self.allocator);
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
        id: []const u8,
        selected: bool = false,
        gain: f32 = 1.0,
    };

    gui_foreground_fps: u32 = 120,
    gui_background_fps: u32 = 30,
    capture_fps: u32 = 60,
    /// In bits per second (bps).
    capture_bit_rate: u64 = 10_000_000,
    replay_seconds: u32 = 30,
    audio_devices: std.json.ArrayHashMap(AudioDeviceSettings) = .{},

    fn deinit(self: *@This(), allocator: Allocator) void {
        self.clear_audio_device_settings(allocator);
        self.audio_devices.deinit(allocator);
    }

    fn update_audio_device_settings(
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

    /// Deep copy user settings.
    fn clone(self: @This(), allocator: Allocator) !@This() {
        var settings_copy: @This() = .{
            .capture_fps = self.capture_fps,
            .capture_bit_rate = self.capture_bit_rate,
            .replay_seconds = self.replay_seconds,
            .gui_foreground_fps = self.gui_foreground_fps,
            .gui_background_fps = self.gui_background_fps,
        };
        errdefer settings_copy.deinit(allocator);

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
};
