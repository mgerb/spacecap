const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
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

pub const AudioSession = struct {
    const Self = @This();
    const log = std.log.scoped(.audio_session);

    allocator: Allocator,
    store: *Store,
    audio_capture: *AudioCapture,
    audio_replay_buffer: Mutex(?*AudioReplayBuffer) = .init(null),
    audio_recording_timeline: Mutex(?*AudioTimeline) = .init(null),
    capture_thread: ?std.Thread = null,

    pub fn init(
        allocator: Allocator,
        store: *Store,
        audio_capture: *AudioCapture,
    ) !Self {
        return .{
            .allocator = allocator,
            .store = store,
            .audio_capture = audio_capture,
        };
    }

    pub fn deinit(self: *Self) void {
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
        self.capture_thread = try std.Thread.spawn(.{}, capture_thread_handler, .{ self, self.store });
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

    fn capture_thread_handler(self: *Self, store: *Store) !void {
        _ = store;
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

            data.gain = 1.0;

            // TODO: Keep a device gain lookup map on the audio session
            // and sync it from the store?

            // data.gain = blk: {
            //     var locked_devices = self.devices.lock();
            //     defer locked_devices.unlock();
            //     const devices = locked_devices.unwrap_ptr();
            //
            //     for (devices.items) |device| {
            //         if (std.mem.eql(u8, device.id, data.id)) {
            //             break :blk device.gain;
            //         }
            //     }
            //
            //     log.err("[capture_thread_handler] Unable to find device ({s}) in available devices. This should never happen.", .{data.id});
            //     assert(false);
            //
            //     // Return a default value to keep the compiler happy. We should never reach this point anyway.
            //     break :blk 1.0;
            // };

            // TODO: is recording..
            // if (actor.is_recording_to_disk()) {
            //     try self.add_recording_data(actor, try data.clone(self.allocator));
            // }

            var replay_buffer_locked = self.audio_replay_buffer.lock();
            defer replay_buffer_locked.unlock();
            if (replay_buffer_locked.unwrap()) |replay_buffer| {
                try replay_buffer.add_data(data);
                // TODO: dispatch message to update replay buffer state
                // actor.ui_mutex.lock();
                // defer actor.ui_mutex.unlock();
                // actor.state.replay_buffer.audio_size = replay_buffer.size;
            } else {
                data.deinit();
            }
        }
    }

    pub fn start_disk_recording(self: *Self) !?CodecContextInfo {
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

    pub fn stop_disk_recording(self: *Self, store: *Store) !void {
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
            try self.write_recording_audio_packets(store, &packets, _timeline);
        }
    }

    fn write_recording_audio_packets(self: *Self, store: *Store, packets: *std.DoublyLinkedList, timeline: *AudioTimeline) !void {
        _ = self;
        _ = store;
        _ = packets;
        _ = timeline;
        // TODO:
        // var locked = actor.recording_muxer.lock();
        // defer locked.unlock();
        // const muxer = locked.unwrap() orelse return;
        //
        // if (muxer.needs_audio_start_sample()) {
        //     if (muxer.video_start_time_ns()) |start_ns| {
        //         if (timeline.get_unclamped_sample_window(start_ns, start_ns)) |window| {
        //             muxer.set_audio_start_sample(window.start_sample);
        //         }
        //     }
        // }
        //
        // try muxer.write_audio_packets(packets);
    }

    /// Finalize the current replay buffer, take ownership, and create a new replay buffer.
    pub fn take_and_swap_replay_buffer(self: *Self, allocator: Allocator, replay_seconds: u32) !?*AudioReplayBuffer {
        var replay_buffer_locked = self.audio_replay_buffer.lock();
        defer replay_buffer_locked.unlock();

        const replay_buffer = replay_buffer_locked.unwrap();
        // Capture-time encoding can still leave one partial AAC frame buffered.
        // Finalize drains that tail before the muxer starts consuming packets.
        if (replay_buffer) |_replay_buffer| try _replay_buffer.finalize();

        replay_buffer_locked.set(try AudioReplayBuffer.init(allocator, replay_seconds));

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

    pub fn deinit(self: *@This()) void {
        self.list.deinit(self.allocator);
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
