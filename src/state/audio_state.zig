const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const StateActor = @import("../state_actor.zig").StateActor;
const ActionPayload = @import("../state_actor.zig").ActionPayload;
const ChanError = @import("../channel.zig").ChanError;
const Mutex = @import("../mutex.zig").Mutex;
const AudioCapture = @import("../capture/audio/audio_capture.zig").AudioCapture;
const AudioDeviceType = @import("../capture/audio/audio_capture.zig").AudioDeviceType;
const SelectedAudioDevice = @import("../capture/audio/audio_capture.zig").SelectedAudioDevice;
const AudioReplayBuffer = @import("../capture/audio/audio_replay_buffer.zig");

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
    devices: std.ArrayList(AudioDeviceViewModel),
    replay_buffer: Mutex(?*AudioReplayBuffer) = .init(null),
    capture_thread: ?std.Thread = null,

    pub fn init(allocator: Allocator, audio_capture: *AudioCapture) !Self {
        return .{
            .allocator = allocator,
            .audio_capture = audio_capture,
            .devices = try .initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stopCaptureThread();
        assert(self.capture_thread == null);

        {
            var replay_buffer_locked = self.replay_buffer.lock();
            defer replay_buffer_locked.unlock();
            if (replay_buffer_locked.unwrap()) |replay_buffer| {
                replay_buffer.deinit();
                replay_buffer_locked.set(null);
            }
        }

        self.clearDevices();
        self.devices.deinit(self.allocator);
    }

    pub fn handleActions(self: *Self, state_actor: *StateActor, action: AudioActions) !void {
        switch (action) {
            .start_capture_thread => {
                // This should only ever get called once, so the capture_thread must always be null.
                assert(self.capture_thread == null);
                self.capture_thread = try std.Thread.spawn(.{}, captureThreadHandler, .{ self, state_actor });
            },
            .get_available_audio_devices => {
                var available_devices = try self.audio_capture.getAvailableDevices(self.allocator);
                defer available_devices.deinit();

                state_actor.ui_mutex.lock();
                defer state_actor.ui_mutex.unlock();
                self.clearDevices();
                errdefer self.clearDevices();

                for (available_devices.devices.items) |device| {
                    const persisted_settings = state_actor.state.user_settings.settings.audio_devices.map.get(device.id);
                    const device_copy = try AudioDeviceViewModel.init(self.allocator, .{
                        .id = device.id,
                        .name = device.name,
                        .device_type = device.device_type,
                        .is_default = device.is_default,
                        .selected = if (persisted_settings) |settings| settings.selected else device.is_default,
                        .gain = if (persisted_settings) |settings| settings.gain else 1.0,
                    });
                    errdefer device_copy.deinit();
                    try self.devices.append(self.allocator, device_copy);
                }

                try self.updateSelectedDevices();
            },
            .toggle_audio_device => |device_id| {
                defer self.allocator.free(device_id);

                {
                    state_actor.ui_mutex.lock();
                    defer state_actor.ui_mutex.unlock();

                    for (self.devices.items) |*device| {
                        if (!std.mem.eql(u8, device.id, device_id)) continue;
                        device.selected = !device.selected;
                        try self.updateSelectedDevices();

                        try state_actor.dispatch(.{
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
                    state_actor.ui_mutex.lock();
                    defer state_actor.ui_mutex.unlock();

                    for (self.devices.items) |*device| {
                        if (!std.mem.eql(u8, device.id, payload.device_id)) continue;
                        device.gain = std.math.clamp(payload.gain, AUDIO_GAIN_MIN, AUDIO_GAIN_MAX);
                        try state_actor.dispatch(.{
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
    }

    fn stopCaptureThread(self: *Self) void {
        if (self.capture_thread) |capture_thread| {
            self.audio_capture.stop() catch |err| {
                log.err("[stopCaptureThread] audio_capture.stop error: {}", .{err});
            };
            capture_thread.join();
            self.capture_thread = null;
        }
    }

    /// Return the current replay buffer to owned. Create a new replay buffer.
    pub fn swapReplayBuffer(self: *Self, allocator: Allocator, replay_seconds: u32) !?*AudioReplayBuffer {
        var replay_buffer_locked = self.replay_buffer.lock();
        defer replay_buffer_locked.unlock();

        const replay_buffer = replay_buffer_locked.unwrap();
        replay_buffer_locked.set(try AudioReplayBuffer.init(allocator, replay_seconds));
        return replay_buffer;
    }

    /// Communicates with the audio capture interface and tells it which audio devices
    /// were selected.
    fn updateSelectedDevices(self: *Self) !void {
        var selected_devices = try std.ArrayList(SelectedAudioDevice).initCapacity(self.allocator, 0);
        defer selected_devices.deinit(self.allocator);

        for (self.devices.items) |device| {
            if (!device.selected) continue;
            try selected_devices.append(self.allocator, .{
                .id = device.id,
                .device_type = device.device_type,
            });
        }

        try self.audio_capture.updateSelectedDevices(selected_devices.items);
    }

    pub fn clearDevices(self: *Self) void {
        for (self.devices.items) |device| {
            device.deinit();
        }
        self.devices.clearRetainingCapacity();
    }

    fn captureThreadHandler(self: *Self, state_actor: *StateActor) !void {
        {
            var replay_buffer_locked = self.replay_buffer.lock();
            defer replay_buffer_locked.unlock();
            const ptr = replay_buffer_locked.unwrapPtr();
            std.debug.assert(ptr.* == null);
            ptr.* = try AudioReplayBuffer.init(self.allocator, state_actor.state.replay_seconds);
        }

        while (true) {
            const data = self.audio_capture.receiveData() catch |err| {
                if (err == ChanError.Closed) {
                    log.debug("[captureThreadHandler] chan closed", .{});
                    break;
                }
                log.err("[captureThreadHandler] data_chan error: {}", .{err});
                return err;
            };

            const gain = blk: {
                state_actor.ui_mutex.lock();
                defer state_actor.ui_mutex.unlock();

                if (!state_actor.state.is_recording_video) {
                    break :blk null;
                }

                for (self.devices.items) |device| {
                    if (std.mem.eql(u8, device.id, data.id)) {
                        break :blk device.gain;
                    }
                }

                log.err("[captureThreadHandler] Unable to find device ({s}) in available devices. This should never happen.", .{data.id});
                assert(false);

                // Return a default value to keep the compiler happy. We should never reach this point anyway.
                break :blk 1.0;
            };

            if (gain) |device_gain| {
                data.gain = device_gain;
            } else {
                data.deinit();
                continue;
            }

            var replay_buffer_locked = self.replay_buffer.lock();
            defer replay_buffer_locked.unlock();
            if (replay_buffer_locked.unwrap()) |replay_buffer| {
                replay_buffer.addData(data) catch |err| {
                    data.deinit();
                    return err;
                };
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
