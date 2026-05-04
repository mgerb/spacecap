const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Actor = @import("./actor.zig").Actor;
const ActionPayload = @import("./action_payload.zig").ActionPayload;
const ChanError = @import("../channel.zig").ChanError;
const Mutex = @import("../mutex.zig").Mutex;
const audio_capture_mod = @import("../capture/audio/audio_capture.zig");
const AudioCapture = audio_capture_mod.AudioCapture;
const SAMPLE_RATE = audio_capture_mod.SAMPLE_RATE;
const CHANNELS = audio_capture_mod.CHANNELS;
const AudioCaptureData = @import("../capture/audio/audio_capture_data.zig");
const AudioDeviceType = @import("../capture/audio/audio_capture.zig").AudioDeviceType;
const SelectedAudioDevice = @import("../capture/audio/audio_capture.zig").SelectedAudioDevice;
const AudioReplayBuffer = @import("../audio/audio_replay_buffer.zig");
const AudioTimeline = @import("../audio/audio_timeline.zig").AudioTimeline;
const CodecContextInfo = @import("../audio/audio_timeline.zig").CodecContextInfo;
const deinitPacketList = @import("../audio/audio_encoder.zig").deinit_packet_list;
const Actions = @import("./actor.zig").Actions;

const log = std.log.scoped(.audio_state);

pub const AUDIO_GAIN_MIN: f32 = 0.0;
pub const AUDIO_GAIN_MAX: f32 = 2.0;

pub const AudioActions = union(enum) {
    start_capture_thread,
    /// Use the capture interface to get all available audio devices on the system.
    get_available_audio_devices,
    /// Toggle recording on an audio device by device ID.
    toggle_audio_device: []u8,
    set_audio_device_gain: *ActionPayload(struct {
        device_id: []u8,
        gain: f32,

        pub fn init(arena: *ArenaAllocator, args: struct {
            device_id: []u8,
            gain: f32,
        }) !@This() {
            return .{
                .device_id = try arena.allocator().dupe(u8, args.device_id),
                .gain = args.gain,
            };
        }
    }),
};

pub const AudioState = struct {
    const Self = @This();
    allocator: Allocator,
    audio_capture: *AudioCapture,
    // TODO: Convert devices to a ArrayHashMap.
    /// This is a list of all currently available audio devices.
    devices: Mutex(std.ArrayList(AudioDeviceViewModel)),
    audio_replay_buffer: Mutex(?*AudioReplayBuffer) = .init(null),
    audio_recording_timeline: Mutex(?*AudioTimeline) = .init(null),
    capture_thread: ?std.Thread = null,

    pub fn init(allocator: Allocator, audio_capture: *AudioCapture) !Self {
        return .{
            .allocator = allocator,
            .audio_capture = audio_capture,
            .devices = .init(try .initCapacity(allocator, 0)),
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

        var locked_devices = self.devices.lock();
        defer locked_devices.unlock();
        const devices = locked_devices.unwrap_ptr();
        clear_devices(devices);
        devices.deinit(self.allocator);
    }

    pub fn handle_action(self: *Self, actor: *Actor, action: Actions) !void {
        switch (action) {
            .audio => |audio_action| {
                switch (audio_action) {
                    .start_capture_thread => {
                        // This should only ever get called once, so the capture_thread must always be null.
                        assert(self.capture_thread == null);
                        self.capture_thread = try std.Thread.spawn(.{}, capture_thread_handler, .{ self, actor });
                    },
                    .get_available_audio_devices => {
                        var available_devices = try self.audio_capture.get_available_devices(self.allocator);
                        defer available_devices.deinit();

                        var user_settings = blk: {
                            const state_locked = actor.store.state.lock();
                            defer state_locked.unlock();
                            const state = state_locked.unwrap_ptr();
                            const settings = state.user_settings.user_settings;
                            break :blk try settings.clone(self.allocator);
                        };
                        defer user_settings.deinit(self.allocator);

                        var locked_devices = self.devices.lock();
                        defer locked_devices.unlock();
                        const devices = locked_devices.unwrap_ptr();
                        clear_devices(devices);
                        errdefer clear_devices(devices);

                        for (available_devices.devices.items) |device| {
                            // Show default devices if user settings aren't saved yet.
                            const persisted_settings = user_settings.audio_devices.map.get(device.id);
                            const device_copy = try AudioDeviceViewModel.init(self.allocator, .{
                                .id = device.id,
                                .name = device.name,
                                .device_type = device.device_type,
                                .is_default = device.is_default,
                                .selected = if (persisted_settings) |settings| settings.selected else device.is_default,
                                .gain = if (persisted_settings) |settings| settings.gain else 1.0,
                            });
                            errdefer device_copy.deinit();
                            try devices.append(self.allocator, device_copy);
                        }

                        try self.update_selected_devices(devices);
                    },
                    .toggle_audio_device => |device_id| {
                        defer self.allocator.free(device_id);

                        {
                            var locked_devices = self.devices.lock();
                            defer locked_devices.unlock();
                            const devices = locked_devices.unwrap_ptr();

                            for (devices.items) |*device| {
                                if (!std.mem.eql(u8, device.id, device_id)) continue;
                                device.selected = !device.selected;
                                try self.update_selected_devices(devices);

                                actor.store.dispatch(.{
                                    .user_settings = .{
                                        .set_audio_device_settings = try .init(self.allocator, .{
                                            .device_id = device.id,
                                            .selected = device.selected,
                                            .gain = device.gain,
                                        }),
                                    },
                                });
                                break;
                            }
                        }
                    },
                    .set_audio_device_gain => |_action| {
                        const payload = _action.payload;
                        defer _action.deinit();
                        {
                            var locked_devices = self.devices.lock();
                            defer locked_devices.unlock();
                            const devices = locked_devices.unwrap_ptr();

                            for (devices.items) |*device| {
                                if (!std.mem.eql(u8, device.id, payload.device_id)) continue;
                                device.gain = std.math.clamp(payload.gain, AUDIO_GAIN_MIN, AUDIO_GAIN_MAX);
                                actor.store.dispatch(.{
                                    .user_settings = .{
                                        .set_audio_device_settings = try .init(self.allocator, .{
                                            .device_id = device.id,
                                            .selected = device.selected,
                                            .gain = device.gain,
                                        }),
                                    },
                                });
                                break;
                            }
                        }
                    },
                }
            },
            // TODO:
            // .user_settings => |user_settings_action| {
            //     _ = user_settings_action;
            //     // switch (user_settings_action) {
            //     //     .set_replay_seconds => |replay_seconds| {
            //     //         var replay_buffer_locked = self.audio_replay_buffer.lock();
            //     //         defer replay_buffer_locked.unlock();
            //     //         if (replay_buffer_locked.unwrap()) |replay_buffer| {
            //     //             replay_buffer.set_replay_seconds(replay_seconds);
            //     //         }
            //     //     },
            //     //     else => {},
            //     // }
            // },
            .start_record => {
                const replay_seconds = blk: {
                    const state_locked = actor.store.state.lock();
                    defer state_locked.unlock();
                    const state = state_locked.unwrap_ptr();
                    const settings = state.user_settings.user_settings;
                    break :blk settings.replay_seconds;
                };
                var replay_buffer_locked = self.audio_replay_buffer.lock();
                defer replay_buffer_locked.unlock();
                const ptr = replay_buffer_locked.unwrap_ptr();
                if (ptr.* != null) {
                    log.warn("[handle_action] start_record - previous buffer was not destroyed", .{});
                    ptr.*.?.deinit();
                }
                ptr.* = try AudioReplayBuffer.init(self.allocator, replay_seconds);
            },
            .stop_record => {
                var locked = self.audio_replay_buffer.lock();
                defer locked.unlock();

                if (locked.unwrap()) |audio_replay_buffer| {
                    audio_replay_buffer.deinit();
                    locked.set(null);
                }
            },
            else => {},
        }
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

    pub fn stop_disk_recording(self: *Self, actor: *Actor) !void {
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
            try self.write_recording_audio_packets(actor, &packets, _timeline);
        }
    }

    /// Communicates with the audio capture interface and tells it which audio devices
    /// were selected.
    fn update_selected_devices(self: *Self, devices: *std.ArrayList(AudioDeviceViewModel)) !void {
        var selected_devices = try std.ArrayList(SelectedAudioDevice).initCapacity(self.allocator, 0);
        defer selected_devices.deinit(self.allocator);

        for (devices.items) |device| {
            if (!device.selected) continue;
            try selected_devices.append(self.allocator, .{
                .id = device.id,
                .device_type = device.device_type,
            });
        }

        try self.audio_capture.update_selected_devices(selected_devices.items);
    }

    /// Takes ownership of data.
    fn add_recording_data(self: *Self, actor: *Actor, data: *AudioCaptureData) !void {
        var locked = self.audio_recording_timeline.lock();
        defer locked.unlock();
        const timeline = locked.unwrap() orelse {
            data.deinit();
            return;
        };

        timeline.add_data(data) catch |err| {
            data.deinit();
            return err;
        };

        var packets = timeline.take_ready_packets();
        defer deinitPacketList(&packets);
        try self.write_recording_audio_packets(actor, &packets, timeline);
    }

    fn write_recording_audio_packets(self: *Self, actor: *Actor, packets: *std.DoublyLinkedList, timeline: *AudioTimeline) !void {
        _ = self;
        var locked = actor.recording_muxer.lock();
        defer locked.unlock();
        const muxer = locked.unwrap() orelse return;

        if (muxer.needs_audio_start_sample()) {
            if (muxer.video_start_time_ns()) |start_ns| {
                if (timeline.get_unclamped_sample_window(start_ns, start_ns)) |window| {
                    muxer.set_audio_start_sample(window.start_sample);
                }
            }
        }

        try muxer.write_audio_packets(packets);
    }

    pub fn clear_devices(devices: *std.ArrayList(AudioDeviceViewModel)) void {
        for (devices.items) |device| {
            device.deinit();
        }
        devices.clearRetainingCapacity();
    }

    fn capture_thread_handler(self: *Self, actor: *Actor) !void {
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
                var locked_devices = self.devices.lock();
                defer locked_devices.unlock();
                const devices = locked_devices.unwrap_ptr();

                for (devices.items) |device| {
                    if (std.mem.eql(u8, device.id, data.id)) {
                        break :blk device.gain;
                    }
                }

                log.err("[capture_thread_handler] Unable to find device ({s}) in available devices. This should never happen.", .{data.id});
                assert(false);

                // Return a default value to keep the compiler happy. We should never reach this point anyway.
                break :blk 1.0;
            };

            if (actor.is_recording_to_disk()) {
                try self.add_recording_data(actor, try data.clone(self.allocator));
            }

            var replay_buffer_locked = self.audio_replay_buffer.lock();
            defer replay_buffer_locked.unlock();
            if (replay_buffer_locked.unwrap()) |replay_buffer| {
                try replay_buffer.add_data(data);
                actor.ui_mutex.lock();
                defer actor.ui_mutex.unlock();
                actor.state.replay_buffer.audio_size = replay_buffer.size;
            } else {
                data.deinit();
            }
        }
    }
};

pub const AudioDeviceViewModel = struct {
    arena: *ArenaAllocator,
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
        const arena = try allocator.create(ArenaAllocator);
        arena.* = .init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }

        const arena_allocator = arena.allocator();
        const id = try arena_allocator.dupe(u8, args.id);
        const name = try arena_allocator.dupe(u8, args.name);
        return .{
            .arena = arena,
            .id = id,
            .name = name,
            .device_type = args.device_type,
            .is_default = args.is_default,
            .selected = args.selected,
            .gain = args.gain,
        };
    }

    pub fn deinit(self: @This()) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};
