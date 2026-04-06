const std = @import("std");
const Allocator = std.mem.Allocator;

/// NOTE: This MUST remain serializable.
pub const UserSettings = struct {
    const AudioDeviceSettings = struct {
        id: []const u8,
        selected: bool = false,
        gain: f32 = 1.0,
    };

    // NOTE: Default values here are default user settings.
    gui_foreground_fps: u32 = 120,
    gui_background_fps: u32 = 30,
    capture_fps: u32 = 60,
    /// In bits per second (bps).
    capture_bit_rate: u64 = 10_000_000,
    replay_seconds: u32 = 30,
    start_replay_buffer_on_startup: bool = false,
    restore_capture_source_on_startup: bool = true,
    audio_devices: std.json.ArrayHashMap(AudioDeviceSettings) = .{},

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.clear_audio_device_settings(allocator);
        self.audio_devices.deinit(allocator);
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

    /// Deep copy user settings.
    pub fn clone(self: @This(), allocator: Allocator) !@This() {
        var settings_copy = self;
        settings_copy.audio_devices = .{};
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
