const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const AudioReplayBuffer = @import("../audio/audio_replay_buffer.zig");
const AudioDeviceType = @import("../capture/audio/audio_capture.zig").AudioDeviceType;
const Mutex = @import("../mutex.zig").Mutex;
const AudioTimeline = @import("../audio/audio_timeline.zig").AudioTimeline;
const AudioCapture = @import("../capture/audio/audio_capture.zig").AudioCapture;
const SAMPLE_RATE = @import("../capture/audio/audio_capture.zig").SAMPLE_RATE;
const CHANNELS = @import("../capture/audio/audio_capture.zig").CHANNELS;
const SelectedAudioDevice = @import("../capture/audio/audio_capture.zig").SelectedAudioDevice;
const UserSettings = @import("./user_settings.zig").UserSettings;
const Store = @import("./store.zig").Store;
const ChanError = @import("../channel.zig").ChanError;
const deinitPacketList = @import("../audio/audio_encoder.zig").deinit_packet_list;
const CodecContextInfo = @import("../audio/audio_timeline.zig").CodecContextInfo;
const AudioCaptureData = @import("../capture/audio/audio_capture_data.zig");
const Muxer = @import("../video/muxer.zig").Muxer;

pub const AudioSession = struct {
    const Self = @This();
    const log = std.log.scoped(.audio_session);

    allocator: Allocator,
    store: *Store,
    audio_capture: *AudioCapture,
    audio_replay_buffer: Mutex(?*AudioReplayBuffer) = .init(null),
    audio_recording_timeline: Mutex(?*AudioTimeline) = .init(null),
    capture_thread: ?std.Thread = null,
    /// A lookup map to get the device gain by ID.
    device_gain_map: Mutex(std.StringHashMap(f32)),

    pub fn init(
        allocator: Allocator,
        store: *Store,
        audio_capture: *AudioCapture,
    ) !Self {
        return .{
            .allocator = allocator,
            .store = store,
            .audio_capture = audio_capture,
            .device_gain_map = .init(.init(allocator)),
        };
    }

    pub fn deinit(self: *Self) void {
        {
            const device_gain_locked = self.device_gain_map.lock();
            defer device_gain_locked.unlock();
            const device_gain = device_gain_locked.unwrap_ptr();
            var iter = device_gain.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            device_gain.deinit();
        }

        self.stop_capture_thread();
        assert(self.capture_thread == null);

        {
            var replay_buffer_locked = self.audio_replay_buffer.lock();
            defer replay_buffer_locked.unlock();
            if (replay_buffer_locked.unwrap()) |replay_buffer| {
                replay_buffer.deinit();
                replay_buffer_locked.set(null);
            }
        }
        {
            var recording_timeline_locked = self.audio_recording_timeline.lock();
            defer recording_timeline_locked.unlock();
            if (recording_timeline_locked.unwrap()) |timeline| {
                timeline.deinit();
                self.allocator.destroy(timeline);
                recording_timeline_locked.set(null);
            }
        }
    }

    pub fn start_capture_thread(self: *Self) !void {
        // This should only ever get called once, so the capture_thread must always be null.
        assert(self.capture_thread == null);
        self.capture_thread = try std.Thread.spawn(.{}, capture_thread_handler, .{self});
    }

    fn stop_capture_thread(self: *Self) void {
        if (self.capture_thread) |capture_thread| {
            self.audio_capture.stop() catch |err| {
                log.err("[stop_capture_thread] audio_capture.stop error: {}", .{err});
            };
            capture_thread.join();
            self.capture_thread = null;
        }
    }

    fn capture_thread_handler(self: *Self) !void {
        while (true) {
            const data = self.audio_capture.receive_data() catch |err| {
                if (err == ChanError.Closed) {
                    log.debug("[capture_thread_handler] chan closed", .{});
                    break;
                }
                log.err("[capture_thread_handler] data_chan error: {}", .{err});
                return err;
            };
            errdefer data.deinit();

            data.gain = blk: {
                const device_gain_locked = self.device_gain_map.lock();
                defer device_gain_locked.unlock();
                const device_gain = device_gain_locked.unwrap_ptr();

                if (device_gain.get(data.id)) |gain| {
                    break :blk gain;
                }

                log.err("[capture_thread_handler] Unable to find device ({s}) in available devices. This should never happen.", .{data.id});
                assert(false);

                // Return a default value to keep the compiler happy. We should never reach this point anyway.
                break :blk 1.0;
            };

            try self.write_audio_packets_to_disk(data);

            var replay_buffer_locked = self.audio_replay_buffer.lock();
            defer replay_buffer_locked.unlock();
            if (replay_buffer_locked.unwrap()) |replay_buffer| {
                try replay_buffer.add_data(data);
                self.store.dispatch(.{
                    .capture = .{
                        .update_replay_buffer_size = .{ .audio_size = replay_buffer.size },
                    },
                });
            } else {
                data.deinit();
            }
        }
    }

    pub fn start_replay_buffer(self: *Self, replay_seconds: u32) !void {
        const replay_buffer_locked = self.audio_replay_buffer.lock();
        defer replay_buffer_locked.unlock();
        const ptr = replay_buffer_locked.unwrap_ptr();
        if (ptr.* != null) {
            log.warn("[start_replay_buffer] start_record - previous buffer was not destroyed", .{});
            ptr.*.?.deinit();
        }
        ptr.* = try AudioReplayBuffer.init(self.allocator, replay_seconds);
    }

    pub fn stop_replay_buffer(self: *Self) !void {
        var locked = self.audio_replay_buffer.lock();
        defer locked.unlock();

        if (locked.unwrap()) |audio_replay_buffer| {
            audio_replay_buffer.deinit();
            locked.set(null);
        }
    }

    pub fn start_recording_to_disk(self: *Self) !?CodecContextInfo {
        const timeline = try self.allocator.create(AudioTimeline);
        errdefer self.allocator.destroy(timeline);
        timeline.* = try AudioTimeline.init(self.allocator, SAMPLE_RATE, CHANNELS);

        var locked = self.audio_recording_timeline.lock();
        defer locked.unlock();
        if (locked.unwrap()) |old_timeline| {
            log.warn("[start_disk_recording] previous recording timeline was not destroyed", .{});
            old_timeline.deinit();
            self.allocator.destroy(old_timeline);
        }
        locked.set(timeline);
        return timeline.get_codec_context();
    }

    pub fn stop_recording_to_disk(self: *Self, muxer: ?*Muxer) !void {
        var timeline: ?*AudioTimeline = null;
        {
            var locked = self.audio_recording_timeline.lock();
            defer locked.unlock();
            timeline = locked.unwrap();
            locked.set(null);
        }

        if (timeline) |_timeline| {
            defer {
                _timeline.deinit();
                self.allocator.destroy(_timeline);
            }

            try _timeline.finalize();
            var packets = _timeline.take_ready_packets();
            defer deinitPacketList(&packets);
            if (muxer) |_muxer| {
                try mux_audio_packets(&packets, _timeline, _muxer);
            }
        }
    }

    // If time and muxer are both valid, then write audio to disk via muxer.
    fn write_audio_packets_to_disk(self: *Self, data: *AudioCaptureData) !void {
        var locked = self.audio_recording_timeline.lock();
        defer locked.unlock();
        const timeline = locked.unwrap() orelse {
            return;
        };

        const muxer_locked = self.store.capture_store.muxer.lock();
        defer muxer_locked.unlock();
        const muxer_ptr = muxer_locked.unwrap_ptr();
        if (muxer_ptr.* == null) {
            return;
        }
        const muxer = &(muxer_ptr.*.?);

        const cloned_data = try data.clone(self.allocator);
        errdefer cloned_data.deinit();

        try timeline.add_data(cloned_data);

        var packets = timeline.take_ready_packets();
        defer deinitPacketList(&packets);
        try mux_audio_packets(&packets, timeline, muxer);
    }

    fn mux_audio_packets(
        packets: *std.DoublyLinkedList,
        timeline: *AudioTimeline,
        muxer: *Muxer,
    ) !void {
        // TODO: Move this logic to the muxer?
        if (muxer.needs_audio_start_sample()) {
            if (muxer.video_start_time_ns()) |start_ns| {
                if (timeline.get_unclamped_sample_window(start_ns, start_ns)) |window| {
                    muxer.set_audio_start_sample(window.start_sample);
                }
            }
        }

        try muxer.write_audio_packets(packets);
    }

    /// Finalize the current replay buffer, take ownership, and create a new replay buffer.
    pub fn take_and_swap_replay_buffer(self: *Self, replay_seconds: u32) !?*AudioReplayBuffer {
        var replay_buffer_locked = self.audio_replay_buffer.lock();
        defer replay_buffer_locked.unlock();

        const replay_buffer = replay_buffer_locked.unwrap();
        // Capture-time encoding can still leave one partial AAC frame buffered.
        // Finalize drains that tail before the muxer starts consuming packets.
        if (replay_buffer) |_replay_buffer| try _replay_buffer.finalize();

        replay_buffer_locked.set(try AudioReplayBuffer.init(self.allocator, replay_seconds));

        return replay_buffer;
    }

    /// Take in saved devices in user settings, scan system devices, then update
    /// them in the audio capture interface.
    pub fn load_system_devices(
        self: *Self,
        allocator: Allocator,
        user_settings_audio_devices: std.json.ArrayHashMap(UserSettings.AudioDeviceSettings),
    ) !AudioDevices {
        var available_devices = try self.audio_capture.get_available_devices(allocator);
        defer available_devices.deinit();

        var devices: AudioDevices = try .init(allocator);

        for (available_devices.devices.items) |device| {
            // Show default devices if user settings aren't saved yet.
            const persisted_settings = user_settings_audio_devices.map.get(device.id);
            const device_copy = try AudioDevice.init(allocator, .{
                .id = device.id,
                .name = device.name,
                .device_type = device.device_type,
                .is_default = device.is_default,
                .selected = if (persisted_settings) |settings| settings.selected else device.is_default,
                .gain = if (persisted_settings) |settings| settings.gain else 1.0,
            });
            errdefer device_copy.deinit();
            try devices.list.append(allocator, device_copy);
        }

        return devices;
    }

    /// Communicates with the audio capture interface and tells it which audio devices
    /// were selected.
    pub fn update_selected_devices(self: *Self, selected_devices: std.ArrayList(SelectedAudioDevice)) !void {
        try self.audio_capture.update_selected_devices(selected_devices.items);
    }

    pub fn set_replay_buffer_seconds(self: *Self, replay_seconds: u32) void {
        var replay_buffer_locked = self.audio_replay_buffer.lock();
        defer replay_buffer_locked.unlock();
        if (replay_buffer_locked.unwrap()) |replay_buffer| {
            replay_buffer.set_replay_seconds(replay_seconds);
        }
    }

    pub fn update_device_gain(self: *Self, device_id: []const u8, gain: f32) !void {
        const device_gain_locked = self.device_gain_map.lock();
        defer device_gain_locked.unlock();
        const device_gain = device_gain_locked.unwrap_ptr();

        if (device_gain.getPtr(device_id)) |val| {
            val.* = gain;
            return;
        }

        try device_gain.put(try self.allocator.dupe(u8, device_id), gain);
    }
};

pub const AudioDevices = struct {
    allocator: Allocator,
    list: std.ArrayList(AudioDevice),

    pub fn init(allocator: Allocator) !@This() {
        return .{
            .allocator = allocator,
            .list = try .initCapacity(allocator, 0),
        };
    }

    /// Frees all underlying devices.
    pub fn deinit(self: *@This()) void {
        for (self.list.items) |item| {
            item.deinit();
        }
        self.list.deinit(self.allocator);
    }

    pub fn clear(self: *@This()) void {
        for (self.list.items) |device| {
            device.deinit();
        }
        self.list.clearRetainingCapacity();
    }

    pub fn clone(self: *@This()) !@This() {
        var list: std.ArrayList(AudioDevice) = try .initCapacity(self.allocator, self.list.items.len);
        errdefer {
            for (list.items) |item| {
                item.deinit();
            }
            list.deinit(self.allocator);
        }

        for (self.list.items) |item| {
            try list.append(self.allocator, try item.clone());
        }
        return .{
            .allocator = self.allocator,
            .list = list,
        };
    }
};

pub const AudioDevice = struct {
    allocator: Allocator,
    id: []u8,
    name: []u8,
    device_type: AudioDeviceType,
    is_default: bool,
    selected: bool = false,
    gain: f32 = 1.0,

    pub fn init(allocator: Allocator, args: struct {
        id: []const u8,
        name: []const u8,
        device_type: AudioDeviceType,
        is_default: bool,
        selected: bool = false,
        gain: f32 = 1.0,
    }) !@This() {
        const id = try allocator.dupe(u8, args.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, args.name);
        errdefer allocator.free(name);
        return .{
            .allocator = allocator,
            .id = id,
            .name = name,
            .device_type = args.device_type,
            .is_default = args.is_default,
            .selected = args.selected,
            .gain = args.gain,
        };
    }

    pub fn clone(self: *const @This()) !@This() {
        return .{
            .allocator = self.allocator,
            .id = try self.allocator.dupe(u8, self.id),
            .name = try self.allocator.dupe(u8, self.name),
            .device_type = self.device_type,
            .is_default = self.is_default,
            .selected = self.selected,
            .gain = self.gain,
        };
    }

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
    }
};
