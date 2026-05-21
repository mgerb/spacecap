//// Implements the audio capture interface.

const std = @import("std");
const AudioCapture = @import("../audio_capture.zig").AudioCapture;
const AudioDeviceList = @import("../audio_capture.zig").AudioDeviceList;
const SelectedAudioDevice = @import("../audio_capture.zig").SelectedAudioDevice;
const AudioCaptureData = @import("../audio_capture_data.zig");
const PipewireAudio = @import("./pipewire_audio.zig").PipewireAudio;
const ChanError = @import("../../../channel.zig").ChanError;
const list_audio_devices = @import("./audio_devices.zig").list_audio_devices;
const Arc = @import("../../../arc.zig").Arc;

pub const LinuxAudioCapture = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    pipewire_audio: *PipewireAudio,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .pipewire_audio = try .init(allocator, io),
        };
        errdefer self.pipewire_audio.deinit();

        return self;
    }

    pub fn deinit(self: *Self) void {
        defer self.allocator.destroy(self);
        self.pipewire_audio.deinit();
    }

    pub fn receive_data(context: *anyopaque) ChanError!Arc(AudioCaptureData) {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.pipewire_audio.data_chan.recv();
    }

    pub fn stop(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.pipewire_audio.data_chan.close(.{ .drain = true });
    }

    pub fn get_available_devices(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) !AudioDeviceList {
        _ = context;
        return list_audio_devices(allocator, io);
    }

    pub fn update_selected_devices(context: *anyopaque, selected_devices: []const SelectedAudioDevice) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        try self.pipewire_audio.update_selected_devices(selected_devices);
    }

    pub fn audio_capture(self: *Self) AudioCapture {
        return .{ .ptr = self, .vtable = &.{
            .receive_data = receive_data,
            .get_available_devices = get_available_devices,
            .update_selected_devices = update_selected_devices,
            .stop = stop,
        } };
    }
};
