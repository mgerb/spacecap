const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const StateActor = @import("../state_actor.zig").StateActor;
const AudioDeviceType = @import("../capture/audio/audio_capture.zig").AudioDeviceType;
const SelectedAudioDevice = @import("../capture/audio/audio_capture.zig").SelectedAudioDevice;

pub const AUDIO_GAIN_MIN: f32 = 0.0;
pub const AUDIO_GAIN_MAX: f32 = 2.0;

pub const AudioActions = union(enum) {
    get_available_audio_devices,
    toggle_audio_device: []u8,
    set_audio_device_gain: struct {
        device_id: []u8,
        gain: f32,
    },
};

pub const AudioState = struct {
    const Self = @This();
    allocator: Allocator,
    /// This is a list of all currently available audio devices.
    devices: std.ArrayList(AudioDeviceViewModel),

    pub fn init(allocator: Allocator) !Self {
        return .{
            .allocator = allocator,
            .devices = try .initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *Self) void {
        self.clearDevices();
        self.devices.deinit(self.allocator);
    }

    pub fn handleActions(self: *Self, state_actor: *StateActor, action: AudioActions) !void {
        switch (action) {
            .get_available_audio_devices => {
                var available_devices = try state_actor.audio_capture.getAvailableDevices(state_actor.allocator);
                defer available_devices.deinit();

                state_actor.ui_mutex.lock();
                defer state_actor.ui_mutex.unlock();
                self.clearDevices();
                errdefer self.clearDevices();

                for (available_devices.devices.items) |device| {
                    const persisted_settings = state_actor.state.user_settings.settings.audio_devices.map.get(device.id);
                    const device_copy = try AudioDeviceViewModel.init(state_actor.allocator, .{
                        .id = device.id,
                        .name = device.name,
                        .device_type = device.device_type,
                        .is_default = device.is_default,
                        .selected = if (persisted_settings) |settings| settings.selected else device.is_default,
                        .gain = if (persisted_settings) |settings| settings.gain else 1.0,
                    });
                    errdefer device_copy.deinit();
                    try self.devices.append(state_actor.allocator, device_copy);
                }

                try self.updateSelectedDevices(state_actor);
            },
            .toggle_audio_device => |device_id| {
                defer state_actor.allocator.free(device_id);

                {
                    state_actor.ui_mutex.lock();
                    defer state_actor.ui_mutex.unlock();

                    for (self.devices.items) |*device| {
                        if (!std.mem.eql(u8, device.id, device_id)) continue;
                        device.selected = !device.selected;
                        try self.updateSelectedDevices(state_actor);
                        const device_id_duped = try state_actor.allocator.dupe(u8, device.id);
                        errdefer state_actor.allocator.free(device_id_duped);
                        try state_actor.dispatch(.{
                            .user_settings = .{
                                .set_audio_device_settings = .{
                                    .device_id = device_id_duped,
                                    .selected = device.selected,
                                    .gain = device.gain,
                                },
                            },
                        });
                        break;
                    }
                }
            },
            .set_audio_device_gain => |payload| {
                defer state_actor.allocator.free(payload.device_id);

                {
                    state_actor.ui_mutex.lock();
                    defer state_actor.ui_mutex.unlock();

                    for (self.devices.items) |*device| {
                        if (!std.mem.eql(u8, device.id, payload.device_id)) continue;
                        device.gain = std.math.clamp(payload.gain, AUDIO_GAIN_MIN, AUDIO_GAIN_MAX);
                        const device_id_duped = try state_actor.allocator.dupe(u8, device.id);
                        errdefer state_actor.allocator.free(device_id_duped);
                        try state_actor.dispatch(.{
                            .user_settings = .{
                                .set_audio_device_settings = .{
                                    .device_id = device_id_duped,
                                    .selected = device.selected,
                                    .gain = device.gain,
                                },
                            },
                        });
                        break;
                    }
                }
            },
        }
    }

    /// Communicates with the audio capture interface and tells it which audio devices
    /// were selected.
    fn updateSelectedDevices(self: *Self, state_actor: *StateActor) !void {
        var selected_devices = try std.ArrayList(SelectedAudioDevice).initCapacity(self.allocator, 0);
        defer selected_devices.deinit(self.allocator);

        for (self.devices.items) |device| {
            if (!device.selected) continue;
            try selected_devices.append(self.allocator, .{
                .id = device.id,
                .device_type = device.device_type,
            });
        }

        try state_actor.audio_capture.updateSelectedDevices(selected_devices.items);
    }

    pub fn clearDevices(self: *Self) void {
        for (self.devices.items) |device| {
            device.deinit();
        }
        self.devices.clearRetainingCapacity();
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
