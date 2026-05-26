const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const AudioSession = @import("./audio_session.zig").AudioSession;
const VideoSession = @import("./video_session.zig").VideoSession;
const AudioCapture = @import("../capture/audio/audio_capture.zig").AudioCapture;
const VideoCapture = @import("../capture/video/video_capture.zig").VideoCapture;
const Store = @import("./store.zig").Store;
const AudioDevices = @import("./audio_session.zig").AudioDevices;
const String = @import("../string.zig").String;
const SelectedAudioDevice = @import("../capture/audio/audio_capture.zig").SelectedAudioDevice;
const ActionPayload = @import("./action_payload.zig").ActionPayload;
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const Muxer = @import("../video/muxer.zig").Muxer;
const Mutex = @import("../mutex.zig").Mutex;
const VideoCaptureSelection = @import("../capture/video/video_capture.zig").VideoCaptureSelection;
const VideoReplayBuffer = @import("../video/video_replay_buffer.zig").VideoReplayBuffer;
const exporter = @import("../exporter.zig");
const AudioCaptureData = @import("../capture/audio/audio_capture_data.zig");
const Arc = @import("../arc.zig").Arc;

pub const AUDIO_GAIN_MIN: f32 = 0.0;
pub const AUDIO_GAIN_MAX: f32 = 2.0;

pub const CaptureStore = struct {
    const Self = @This();
    const log = std.log.scoped(.capture_store);

    vulkan: *Vulkan,
    audio_session: AudioSession,
    video_session: VideoSession,
    muxer: Mutex(?Muxer),

    pub const Message = union(enum) {
        const SetAudioDeviceGainPayload = *ActionPayload(struct {
            device_id: []const u8,
            gain: f32,

            pub fn init(arena: *ArenaAllocator, args: struct {
                device_id: []const u8,
                gain: f32,
            }) !@This() {
                return .{
                    .device_id = try arena.allocator().dupe(u8, args.device_id),
                    .gain = args.gain,
                };
            }
        });

        load_system_audio_devices,
        load_system_audio_devices_success: AudioDevices,
        /// When audio devices become ready on app startup.
        audio_devices_ready,
        /// Toggle recording on an audio device by device ID.
        toggle_audio_device: String,
        set_audio_device_gain: SetAudioDeviceGainPayload,
        start_audio_capture_thread,

        update_replay_buffer_size: union(enum) {
            audio_size: u64,
            video: struct { size: u64, seconds: u32 },
        },

        start_replay_buffer,
        start_replay_buffer_success,
        start_replay_buffer_fail,
        stop_replay_buffer,
        stop_replay_buffer_success,
        stop_replay_buffer_fail,

        save_replay,
        save_replay_success,
        save_replay_fail,

        start_recording_to_disk,
        start_recording_to_disk_success,
        start_recording_to_disk_fail,
        stop_recording_to_disk,
        stop_recording_to_disk_success,
        stop_recording_to_disk_fail,

        // Video
        select_video_source: VideoCaptureSelection,
        select_video_source_fail: VideoCaptureSelection,
        // We need to do some prep work when select_video_source is called. When it's
        // done with prep it will call this message.
        select_video_source_prepared: VideoCaptureSelection,
        select_video_source_prepared_success: VideoCaptureSelection,
        select_video_source_prepared_fail: VideoCaptureSelection,

        is_video_capture_supported: bool,

        start_video_capture,
        start_video_capture_success,
        start_video_capture_fail,

        stop_video_capture,
        stop_video_capture_success,
        stop_video_capture_fail,

        pub const effects = .{
            .load_system_audio_devices = .{effect_load_system_audio_devices},
            .load_system_audio_devices_success = .{
                effect_update_selected_audio_devices,
                effect_update_audio_session_device_gain,
            },
            .audio_devices_ready = .{effect_maybe_start_replay_buffer},
            .start_audio_capture_thread = .{effect_start_audio_capture_thread},
            .toggle_audio_device = .{ effect_toggle_audio_device, effect_update_selected_audio_devices },
            .set_audio_device_gain = .{ effect_set_audio_device_gain, effect_update_audio_session_device_gain },
            .start_replay_buffer = .{effect_start_replay_buffer},
            .stop_replay_buffer = .{effect_stop_replay_buffer},
            .start_recording_to_disk = .{effect_start_recording_to_disk},
            .stop_recording_to_disk = .{effect_stop_recording_to_disk},
            .start_video_capture = .{effect_start_video_capture},
            .start_video_capture_success = .{effect_maybe_start_replay_buffer},
            .stop_video_capture = .{effect_stop_video_capture},
            .select_video_source = .{effect_select_video_source},
            .select_video_source_prepared = .{effect_select_video_source_prepared},
            .save_replay = .{effect_save_replay},
        };
    };

    pub const State = struct {
        allocator: Allocator,
        audio_devices: AudioDevices,

        is_video_capture_supprted: bool = false,
        replay_buffer_active: bool = false,
        recording_to_disk: bool = false,
        video_capture_active: bool = false,

        startup: struct {
            audio_devices_ready: bool = false,
            video_capture_ready: bool = false,

            pub fn can_start_replay_buffer(self: @This()) bool {
                return self.audio_devices_ready and
                    self.video_capture_ready;
            }
        } = .{},

        replay_buffer: struct {
            video_size: u64 = 0,
            audio_size: u64 = 0,
            seconds: u64 = 0,

            pub fn size_in_mb(self: *const @This(), size_type: enum { total, audio, video }) f64 {
                return switch (size_type) {
                    .total => _size_in_mb(self.audio_size + self.video_size),
                    .audio => _size_in_mb(self.audio_size),
                    .video => _size_in_mb(self.video_size),
                };
            }

            fn _size_in_mb(size: u64) f64 {
                const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
                return mb;
            }
        },

        pub fn init(allocator: Allocator) !@This() {
            return .{
                .allocator = allocator,
                .audio_devices = try .init(allocator),
                .replay_buffer = .{},
            };
        }

        pub fn deinit(self: *@This()) void {
            self.audio_devices.deinit();
        }
    };

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        vulkan: *Vulkan,
        store: *Store,
        audio_capture: AudioCapture,
        video_capture: VideoCapture,
    ) !Self {
        return .{
            .vulkan = vulkan,
            .audio_session = try .init(allocator, io, store, audio_capture),
            .video_session = try .init(allocator, io, vulkan, store, video_capture),
            .muxer = .init(io, null),
        };
    }

    pub fn deinit(self: *Self) void {
        self.video_session.deinit();
        self.audio_session.deinit();
        var muxer_locked = self.muxer.lock();
        defer muxer_locked.unlock();
        const muxer_ptr = muxer_locked.unwrap_ptr();
        if (muxer_ptr.*) |*muxer| {
            muxer.deinit();
            muxer_locked.set(null);
        }
    }

    pub fn exit(self: *Self) void {
        self.stop_recording_to_disk() catch |err| {
            log.err("[exit] stop recording to disk error: {}", .{err});
        };
        self.audio_session.stop_replay_buffer() catch |err| {
            log.err("[exit] stop audio replay buffer error: {}", .{err});
        };
        self.video_session.stop_replay_buffer() catch |err| {
            log.err("[exit] stop video replay buffer error: {}", .{err});
        };
        self.video_session.stop_capture() catch |err| {
            log.err("[exit] stop capture error: {}", .{err});
        };
    }

    pub fn update(allocator: Allocator, msg: Store.Message, state: *Store.State) !void {
        switch (msg) {
            .capture => |capture_msg| {
                switch (capture_msg) {
                    .is_video_capture_supported => |is_video_capture_supprted| {
                        state.capture.is_video_capture_supprted = is_video_capture_supprted;
                    },
                    .start_replay_buffer_success => {
                        state.capture.replay_buffer_active = true;
                    },
                    .stop_replay_buffer_success, .start_replay_buffer_fail => {
                        state.capture.replay_buffer_active = false;
                        state.capture.replay_buffer = .{};
                    },
                    .start_recording_to_disk_success => {
                        state.capture.recording_to_disk = true;
                    },
                    .stop_recording_to_disk_success, .start_recording_to_disk_fail => {
                        state.capture.recording_to_disk = false;
                    },
                    .start_video_capture_success => {
                        state.capture.video_capture_active = true;
                        state.capture.startup.video_capture_ready = true;
                    },
                    .stop_video_capture_success, .start_video_capture_fail => {
                        state.capture.video_capture_active = false;
                    },
                    .select_video_source_prepared => {
                        // Selecting a new video source always stops the current video capture.
                        state.capture.video_capture_active = false;
                        state.capture.replay_buffer = .{};
                        state.capture.replay_buffer_active = false;
                        state.capture.recording_to_disk = false;
                    },
                    .load_system_audio_devices_success => |*audio_devices| {
                        defer @constCast(audio_devices).deinit();
                        state.capture.audio_devices.clear();
                        for (audio_devices.list.items) |device| {
                            try state.capture.audio_devices.list.append(allocator, try device.clone());
                        }
                    },
                    .audio_devices_ready => {
                        state.capture.startup.audio_devices_ready = true;
                    },
                    .toggle_audio_device => |*device_id| {
                        for (state.capture.audio_devices.list.items) |*device| {
                            if (!std.mem.eql(u8, device.id, device_id.bytes)) {
                                continue;
                            }
                            device.selected = !device.selected;
                            break;
                        }
                    },
                    .set_audio_device_gain => |payload| {
                        for (state.capture.audio_devices.list.items) |*device| {
                            if (!std.mem.eql(u8, device.id, payload.payload.device_id)) continue;
                            device.gain = std.math.clamp(payload.payload.gain, AUDIO_GAIN_MIN, AUDIO_GAIN_MAX);
                            break;
                        }
                    },
                    .update_replay_buffer_size => |payload| {
                        switch (payload) {
                            .audio_size => |audio_size| {
                                state.capture.replay_buffer.audio_size = audio_size;
                            },
                            .video => |video| {
                                state.capture.replay_buffer.video_size = video.size;
                                state.capture.replay_buffer.seconds = video.seconds;
                            },
                        }
                    },

                    else => {},
                }
            },
            else => {},
        }
    }

    // ----------------------------------------------------------------------------
    // Public effects.
    // ----------------------------------------------------------------------------
    pub fn effect_update_video_capture_fps(store: *Store, fps: u32) !void {
        var self = &store.capture_store;
        try self.video_session.video_capture.update_fps(fps);
    }

    pub fn effect_sync_replay_buffer_with_user_settings(store: *Store, replay_seconds: u32) void {
        store.capture_store.audio_session.set_replay_buffer_seconds(replay_seconds);
        store.capture_store.video_session.set_replay_buffer_seconds(replay_seconds);
    }
    // ----------------------------------------------------------------------------

    fn effect_load_system_audio_devices(store: *Store, _: anytype) !void {
        var user_settings = blk: {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            const state = state_locked.unwrap_ptr();
            break :blk try state.user_settings.user_settings.clone(store.allocator);
        };
        defer user_settings.deinit(store.allocator);

        const audio_devices = try store.capture_store.audio_session.load_system_devices(store.allocator, user_settings.audio_devices);
        store.dispatch(.{ .capture = .{ .load_system_audio_devices_success = audio_devices } });
    }

    fn effect_update_selected_audio_devices(store: *Store, _: anytype) !void {
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
        store.dispatch(.{ .capture = .audio_devices_ready });
    }

    fn effect_start_audio_capture_thread(store: *Store, _: anytype) !void {
        try store.capture_store.audio_session.start_capture_thread();
    }

    /// Sync user settings.
    fn effect_toggle_audio_device(store: *Store, device_id: String) !void {
        defer @constCast(&device_id).deinit();
        const state_locked = store.state.lock();
        defer state_locked.unlock();
        const state = state_locked.unwrap_ptr();
        for (state.capture.audio_devices.list.items) |*device| {
            if (!std.mem.eql(u8, device.id, device_id.bytes)) {
                continue;
            }
            store.dispatch(.{
                .user_settings = .{
                    .set_audio_device_settings = try .init(store.allocator, .{
                        .device_id = device.id,
                        .selected = device.selected,
                        .gain = device.gain,
                    }),
                },
            });
            break;
        }
    }

    fn effect_set_audio_device_gain(store: *Store, _payload: Message.SetAudioDeviceGainPayload) !void {
        defer _payload.deinit();
        const payload = _payload.payload;
        const state_locked = store.state.lock();
        defer state_locked.unlock();
        const state = state_locked.unwrap_ptr();

        for (state.capture.audio_devices.list.items) |*device| {
            if (!std.mem.eql(u8, device.id, payload.device_id)) continue;
            device.gain = std.math.clamp(payload.gain, AUDIO_GAIN_MIN, AUDIO_GAIN_MAX);
            store.dispatch(.{
                .user_settings = .{
                    .set_audio_device_settings = try .init(store.allocator, .{
                        .device_id = device.id,
                        .selected = device.selected,
                        .gain = device.gain,
                    }),
                },
            });
            break;
        }
    }

    // Sync audio device gain state with the audio session.
    fn effect_update_audio_session_device_gain(store: *Store, _: anytype) !void {
        const state_locked = store.state.lock();
        defer state_locked.unlock();
        const state = state_locked.unwrap_ptr();

        for (state.capture.audio_devices.list.items) |audio_device| {
            try store.capture_store.audio_session.update_device_gain(audio_device.id, audio_device.gain);
        }
    }

    fn effect_start_video_capture(store: *Store, _: anytype) !void {
        var self = &store.capture_store;
        errdefer store.dispatch(.{ .capture = .start_video_capture_fail });
        try self.video_session.start_capture();
        store.dispatch(.{ .capture = .start_video_capture_success });
    }

    fn effect_stop_video_capture(store: *Store, _: anytype) !void {
        var self = &store.capture_store;
        errdefer store.dispatch(.{ .capture = .stop_video_capture_fail });
        try self.video_session.stop_capture();
        store.dispatch(.{ .capture = .stop_video_capture_success });
    }

    /// This effect is used to start the replay buffer if the user
    /// setting is enabled, audio devices are ready, and video capture
    /// has started.
    fn effect_maybe_start_replay_buffer(store: *Store, _: anytype) !void {
        const should_start = blk: {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            const state = state_locked.unwrap_ptr();

            break :blk state.user_settings.user_settings.start_replay_buffer_on_startup and
                state.capture.startup.can_start_replay_buffer();
        };

        if (should_start) {
            store.dispatch(.{ .capture = .start_replay_buffer });
        }
    }

    fn effect_start_replay_buffer(store: *Store, _: anytype) !void {
        var self = &store.capture_store;
        errdefer store.dispatch(.{ .capture = .start_replay_buffer_fail });

        const state_local = blk: {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            const state = state_locked.unwrap_ptr();

            if (!state.capture.video_capture_active or state.capture.replay_buffer_active) {
                log.warn("[effect_start_replay_buffer] replay buffer already active", .{});
                return;
            }

            break :blk .{
                .fps = state.user_settings.user_settings.capture_fps,
                .bit_rate = state.user_settings.user_settings.capture_bit_rate,
                .replay_seconds = state.user_settings.user_settings.replay_seconds,
            };
        };

        try self.audio_session.start_replay_buffer(state_local.replay_seconds);
        errdefer self.audio_session.stop_replay_buffer() catch |err| {
            log.err("[effect_start_replay_buffer] stop_replay_buffer error: {}", .{err});
        };
        try self.video_session.start_replay_buffer(
            state_local.fps,
            state_local.bit_rate,
            state_local.replay_seconds,
        );
        store.dispatch(.{ .capture = .start_replay_buffer_success });
    }

    fn effect_stop_replay_buffer(store: *Store, _: anytype) !void {
        var self = &store.capture_store;
        errdefer store.dispatch(.{ .capture = .stop_replay_buffer_fail });
        try self.audio_session.stop_replay_buffer();
        try self.video_session.stop_replay_buffer();
        store.dispatch(.{ .capture = .stop_replay_buffer_success });
    }

    fn effect_start_recording_to_disk(store: *Store, _: anytype) !void {
        var self = &store.capture_store;
        errdefer store.dispatch(.{ .capture = .start_recording_to_disk_fail });

        var local_state = blk: {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            const state = state_locked.unwrap_ptr();
            break :blk .{
                .fps = state.user_settings.user_settings.capture_fps,
                .video_output_directory = try state.user_settings.user_settings.video_output_directory.?.clone(store.allocator),
                .capture_bit_rate = state.user_settings.user_settings.capture_bit_rate,
                .recording_to_disk = state.capture.recording_to_disk,
            };
        };
        defer local_state.video_output_directory.deinit();

        if (local_state.recording_to_disk) {
            return;
        }

        const audio_codec_context = try self.audio_session.start_recording_to_disk();
        errdefer self.audio_session.stop_recording_to_disk(null) catch |err| {
            log.err("[effect_start_recording_to_disk] audio_session.stop_recording_to_disk error: {}", .{err});
        };

        try self.video_session.start_recording_to_disk(local_state.fps, local_state.capture_bit_rate);
        errdefer self.video_session.stop_recording_to_disk();

        const size = self.video_session.video_capture.size() orelse {
            return error.VideoCaptureSizeNotFound;
        };

        var muxer_locked = self.muxer.lock();
        defer muxer_locked.unlock();
        const muxer_ptr = muxer_locked.unwrap_ptr();
        if (muxer_ptr.*) |*_muxer| {
            _muxer.deinit();
        }
        muxer_locked.set(try .init(
            store.allocator,
            store.io,
            "recording",
            self.vulkan.video_encoder.?.bit_stream_header.items,
            audio_codec_context,
            size.width,
            size.height,
            local_state.fps,
            local_state.video_output_directory.bytes,
        ));

        store.dispatch(.{ .capture = .start_recording_to_disk_success });
    }

    fn stop_recording_to_disk(self: *Self) !void {
        // Keep this before locking muxer. The capture thread can hold video_record_mutex
        // and then lock muxer while writing packets, so taking muxer first can deadlock.
        self.video_session.stop_recording_to_disk();

        var muxer_locked = self.muxer.lock();
        defer muxer_locked.unlock();
        const muxer_ptr = muxer_locked.unwrap_ptr();

        if (muxer_ptr.*) |*muxer| {
            defer {
                muxer.deinit();
                muxer_locked.set(null);
            }

            try self.audio_session.stop_recording_to_disk(muxer);
            try muxer.finish();
            return;
        }

        try self.audio_session.stop_recording_to_disk(null);
    }

    fn effect_stop_recording_to_disk(store: *Store, _: anytype) !void {
        var self = &store.capture_store;
        errdefer store.dispatch(.{ .capture = .stop_recording_to_disk_fail });

        try self.stop_recording_to_disk();

        store.dispatch(.{ .capture = .stop_recording_to_disk_success });
    }

    fn effect_save_replay(store: *Store, _: anytype) !void {
        const self = &store.capture_store;
        errdefer store.dispatch(.{ .capture = .save_replay_fail });

        var fps: u32 = 0;
        var replay_seconds: u32 = 0;
        var video_output_directory: ?String = null;
        defer {
            if (video_output_directory) |*_video_output_directory| _video_output_directory.deinit();
        }

        {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            const state = state_locked.unwrap_ptr();
            if (!state.capture.replay_buffer_active) {
                log.debug("[handle_action] save_replay - not recording, skipping capture", .{});
                return;
            }

            const settings = state.user_settings.user_settings;
            fps = settings.capture_fps;
            replay_seconds = settings.replay_seconds;
            // video_output_directory should never be null at this point. If so, there is
            // something seriously wrong.
            assert(settings.video_output_directory != null);
            video_output_directory = try settings.video_output_directory.?.clone(store.allocator);
        }

        // We should always have a size if the state is recording.
        assert(self.video_session.video_capture.size() != null);
        const size = self.video_session.video_capture.size().?;

        const audio_replay_buffer = (try self.audio_session.take_and_swap_replay_buffer(
            replay_seconds,
        ));
        defer if (audio_replay_buffer) |_audio_replay_buffer| _audio_replay_buffer.deinit();

        const video_replay_buffer: ?*VideoReplayBuffer = (try self.video_session.take_and_swap_replay_buffer(
            replay_seconds,
        ));
        defer if (video_replay_buffer) |_video_replay_buffer| _video_replay_buffer.deinit();

        try exporter.export_replay_buffers(
            store.allocator,
            store.io,
            size.width,
            size.height,
            fps,
            video_replay_buffer.?,
            audio_replay_buffer,
            video_output_directory.?.bytes,
        );

        store.dispatch(.{ .capture = .save_replay_success });
    }

    fn effect_select_video_source(store: *Store, video_capture_selection: VideoCaptureSelection) !void {
        var self = &store.capture_store;
        errdefer store.dispatch(.{ .capture = .{ .select_video_source_fail = video_capture_selection } });

        if (video_capture_selection == .restore_session and
            !try self.video_session.video_capture.should_restore_capture_session())
        {
            return;
        }

        // Stop all capturing.
        try self.stop_recording_to_disk();
        try self.audio_session.stop_replay_buffer();
        try self.video_session.stop_replay_buffer();
        try self.video_session.stop_capture();

        store.dispatch(.{ .capture = .{ .select_video_source_prepared = video_capture_selection } });
    }

    fn effect_select_video_source_prepared(store: *Store, video_capture_selection: VideoCaptureSelection) !void {
        var self = &store.capture_store;
        errdefer store.dispatch(.{ .capture = .{ .select_video_source_prepared_fail = video_capture_selection } });

        const fps = blk: {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            const state = state_locked.unwrap_ptr();
            break :blk state.user_settings.user_settings.capture_fps;
        };

        if (try self.video_session.select_video_source(video_capture_selection, fps)) {
            store.dispatch(.{ .capture = .{ .select_video_source_prepared_success = video_capture_selection } });
            store.dispatch(.{ .capture = .start_video_capture });
        }
    }
};

test "CaptureStore - init/exit" {
    const TestStore = @import("./store.zig").TestStore;
    const test_store = try TestStore.init(std.testing.allocator);
    defer test_store.deinit();
    const store = test_store.store;

    // We can just grab the state directly. We are mostly doing things
    // synchronously in tests so we don't have to worry about locking.
    const state = &store.state.private.value;

    store.dispatch(.show_demo);
    store.run(.{ .once = true });

    try std.testing.expectEqual(state.show_demo, true);

    store.dispatch(.exit);
    store.run(.{ .once = true });
}

test "CaptureStore - load_system_audio_devices" {
    const TestStore = @import("./store.zig").TestStore;
    const test_store = try TestStore.init(std.testing.allocator);
    defer test_store.deinit();
    const store = test_store.store;
    const state = &store.state.private.value;

    store.dispatch(.{ .capture = .load_system_audio_devices });
    store.run(.{ .once = true, .wait_for_effects = true });

    try std.testing.expect(state.capture.audio_devices.list.items.len == 0);

    // .load_system_audio_devices_success
    store.run(.{ .once = true, .wait_for_effects = true });

    const audio_device1 = state.capture.audio_devices.list.items[0];
    const audio_device2 = state.capture.audio_devices.list.items[1];
    try std.testing.expectEqualStrings(audio_device1.id, "test1");
    try std.testing.expectEqualStrings(audio_device1.name, "test_device_1");
    try std.testing.expectEqual(audio_device1.device_type, .sink);
    try std.testing.expectEqual(audio_device1.gain, 1.0);
    try std.testing.expect(audio_device1.is_default);
    try std.testing.expect(audio_device1.selected);
    try std.testing.expect(!audio_device2.is_default);
    try std.testing.expect(!audio_device2.selected);

    // .audio_devices_ready
    store.run(.{ .once = true, .wait_for_effects = true });

    try std.testing.expect(state.capture.startup.audio_devices_ready);

    // Should update the device gain audio map on the audio session.
    try std.testing.expect(store.capture_store.audio_session.device_gain_map.private.value.get("test1").? == 1.0);
}

test "CaptureStore - toggle_audio_device" {
    const TestStore = @import("./store.zig").TestStore;
    const test_store = try TestStore.init(std.testing.allocator);
    defer test_store.deinit();
    const store = test_store.store;
    const state = &store.state.private.value;

    store.dispatch(.{ .capture = .load_system_audio_devices });
    store.run(.{ .once = true, .wait_for_effects = true });
    store.run(.{ .once = true, .wait_for_effects = true });
    store.run(.{ .once = true, .wait_for_effects = true });

    try std.testing.expect(state.capture.audio_devices.list.items[0].selected);

    store.dispatch(.{ .capture = .{ .toggle_audio_device = try .from(std.testing.allocator, "test1") } });
    store.run(.{ .once = true, .wait_for_effects = true });
    store.run(.{ .once = true, .wait_for_effects = true });

    try std.testing.expect(!state.capture.audio_devices.list.items[0].selected);
}

test "CaptureStore - set_audio_device_gain" {
    const TestStore = @import("./store.zig").TestStore;
    const test_store = try TestStore.init(std.testing.allocator);
    defer test_store.deinit();
    const store = test_store.store;
    const state = &store.state.private.value;

    store.dispatch(.{ .capture = .load_system_audio_devices });
    store.run(.{ .once = true, .wait_for_effects = true });
    store.run(.{ .once = true, .wait_for_effects = true });
    store.run(.{ .once = true, .wait_for_effects = true });

    store.dispatch(.{ .capture = .{
        .set_audio_device_gain = try .init(std.testing.allocator, .{
            .device_id = "test1",
            .gain = 0.84,
        }),
    } });
    store.run(.{ .once = true, .wait_for_effects = true });
    store.run(.{ .once = true, .wait_for_effects = true });

    try std.testing.expect(state.capture.audio_devices.list.items[0].gain == 0.84);
    try std.testing.expect(store.capture_store.audio_session.device_gain_map.private.value.get("test1").? == 0.84);

    // Should clamp to 2.0
    store.dispatch(.{ .capture = .{
        .set_audio_device_gain = try .init(std.testing.allocator, .{
            .device_id = "test1",
            .gain = 2.5,
        }),
    } });
    store.run(.{ .once = true, .wait_for_effects = true });
    store.run(.{ .once = true, .wait_for_effects = true });

    try std.testing.expect(state.capture.audio_devices.list.items[0].gain == 2.00);
    try std.testing.expect(store.capture_store.audio_session.device_gain_map.private.value.get("test1").? == 2.00);

    // Should clamp to 0
    store.dispatch(.{ .capture = .{
        .set_audio_device_gain = try .init(std.testing.allocator, .{
            .device_id = "test1",
            .gain = -1.5,
        }),
    } });
    store.run(.{ .once = true, .wait_for_effects = true });
    store.run(.{ .once = true, .wait_for_effects = true });

    try std.testing.expect(state.capture.audio_devices.list.items[0].gain == 0);
    try std.testing.expect(store.capture_store.audio_session.device_gain_map.private.value.get("test1").? == 0);
}

test "CaptureStore - start_audio_capture_thread" {
    // Start the capture thread with no audio devices loaded. It should
    // deinit data and continue until exit.
    const TestStore = @import("./store.zig").TestStore;
    const test_store = try TestStore.init(std.testing.allocator);
    defer test_store.deinit();
    const store = test_store.store;

    // Load devices otherwise the capture thread won't be able to
    // lookup device gain.
    store.dispatch(.{ .capture = .load_system_audio_devices });
    store.run(.{ .once = true, .wait_for_effects = true });
    store.run(.{ .once = true, .wait_for_effects = true });
    store.run(.{ .once = true, .wait_for_effects = true });

    store.dispatch(.{ .capture = .start_audio_capture_thread });
    store.run(.{ .once = true, .wait_for_effects = true });

    var audio_capture_data = try AudioCaptureData.init(
        std.testing.allocator,
        "test1",
        &.{},
        0,
        48_000,
        2,
    );
    errdefer audio_capture_data.deinit();

    var data = try Arc(AudioCaptureData).init(std.testing.allocator, audio_capture_data);
    errdefer data.deinit();

    try test_store.test_audio_capture.data.send(data);

    // Sleep so that the thread has a half second to run before store
    // deinit cleans it up.
    std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_s / 2), .awake) catch unreachable;
}

test "CaptureStore - update_replay_buffer_size" {
    const TestStore = @import("./store.zig").TestStore;
    const test_store = try TestStore.init(std.testing.allocator);
    defer test_store.deinit();
    const store = test_store.store;
    const state = &store.state.private.value;

    const size = 1024 * 1024 * 10; // 10MB

    store.dispatch(.{ .capture = .{ .update_replay_buffer_size = .{ .audio_size = size } } });
    store.run(.{ .once = true, .wait_for_effects = true });
    store.dispatch(.{
        .capture = .{
            .update_replay_buffer_size = .{
                .video = .{
                    .seconds = 1,
                    .size = size,
                },
            },
        },
    });
    store.run(.{ .once = true, .wait_for_effects = true });

    try std.testing.expectEqual(1, state.capture.replay_buffer.seconds);
    try std.testing.expectEqual(10, state.capture.replay_buffer.size_in_mb(.audio));
    try std.testing.expectEqual(10, state.capture.replay_buffer.size_in_mb(.video));
    try std.testing.expectEqual(20, state.capture.replay_buffer.size_in_mb(.total));
}

// ----------------------------------------------------------------------------
// TODO: Still need to write tests for the rest of the message types.
// ----------------------------------------------------------------------------
test "CaptureStore - start_replay_buffer" {}
