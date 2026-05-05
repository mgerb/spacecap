const std = @import("std");
const Allocator = std.mem.Allocator;
const AudioSession = @import("./audio_session.zig").AudioSession;
const VideoSession = @import("./video_session.zig").VideoSession;
const AudioCapture = @import("../capture/audio/audio_capture.zig").AudioCapture;
const Store = @import("./store.zig").Store;
const AudioDevices = @import("./audio_session.zig").AudioDevices;
const String = @import("../string.zig").String;
const SelectedAudioDevice = @import("../capture/audio/audio_capture.zig").SelectedAudioDevice;

pub const CaptureStore = struct {
    const Self = @This();

    audio_session: AudioSession,
    video_session: ?VideoSession = null,

    pub const Message = union(enum) {
        // ----- Audio -----
        load_system_audio_devices,
        load_system_audio_devices_success: AudioDevices,
        start_audio_capture_thread,
        /// Toggle recording on an audio device by device ID.
        toggle_audio_device: String,

        pub const effects = .{
            .load_system_audio_devices = .{effect_load_system_audio_devices},
            .load_system_audio_devices_success = .{effect_update_selected_devices},
            .start_audio_capture_thread = .{effect_start_audio_capture_thread},
        };
    };

    pub const State = struct {
        allocator: Allocator,
        audio_devices: AudioDevices,

        pub fn init(allocator: Allocator) !@This() {
            return .{
                .allocator = allocator,
                .audio_devices = try .init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.audio_devices.deinit();
        }
    };

    pub fn init(
        allocator: Allocator,
        store: *Store,
        audio_capture: *AudioCapture,
    ) !Self {
        return .{
            .audio_session = try .init(allocator, store, audio_capture),
        };
    }

    pub fn deinit(self: *Self) void {
        self.audio_session.deinit();
    }

    pub fn update(allocator: Allocator, msg: Store.Message, state: *Store.State) !void {
        switch (msg) {
            .capture => |capture_msg| {
                switch (capture_msg) {
                    .load_system_audio_devices_success => |*audio_devices| {
                        defer @constCast(audio_devices).deinit();
                        state.capture.audio_devices.clear();
                        try state.capture.audio_devices.list.appendSlice(allocator, audio_devices.list.items);
                    },

                    .toggle_audio_device => |*device_id| {
                        defer @constCast(device_id).deinit();
                        // TODO: start here
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn effect_load_system_audio_devices(store: *Store, _: anytype) !void {
        const user_settings = blk: {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            const state = state_locked.unwrap_ptr();
            break :blk try state.user_settings.user_settings.clone(store.allocator);
        };

        const audio_devices = try store.capture_store.audio_session.load_system_devices(store.allocator, user_settings.audio_devices);
        store.dispatch(.{ .capture = .{ .load_system_audio_devices_success = audio_devices } });
    }

    fn effect_update_selected_devices(store: *Store, _: anytype) !void {
        var selected_audio_devices = blk: {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            const audio_devices = state_locked.unwrap_ptr().capture.audio_devices;

            var selected_devices = try std.ArrayList(SelectedAudioDevice).initCapacity(store.allocator, 0);
            errdefer {
                for (selected_devices.items) |d| {
                    store.allocator.free(d.id);
                }
                selected_devices.deinit(store.allocator);
            }

            for (audio_devices.list.items) |device| {
                if (!device.selected) continue;
                try selected_devices.append(store.allocator, .{
                    .id = try store.allocator.dupe(u8, device.id),
                    .device_type = device.device_type,
                });
            }

            break :blk selected_devices;
        };
        defer {
            for (selected_audio_devices.items) |d| {
                store.allocator.free(d.id);
            }

            selected_audio_devices.deinit(store.allocator);
        }

        // Audio devices are cloned so that we can execute this outside the lock.
        try store.capture_store.audio_session.update_selected_devices(selected_audio_devices);
    }

    fn effect_start_audio_capture_thread(store: *Store, _: anytype) !void {
        try store.capture_store.audio_session.start_capture_thread();
    }
};
