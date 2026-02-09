//// Implements the audio capture interface.

const std = @import("std");
const AudioCapture = @import("../audio_capture.zig").AudioCapture;
const AudioDeviceList = @import("../audio_capture.zig").AudioDeviceList;
const SelectedAudioDevice = @import("../audio_capture.zig").SelectedAudioDevice;
const AudioCaptureData = @import("../audio_capture_data.zig");
const PipewireAudio = @import("./pipewire_audio.zig").PipewireAudio;
const ChanError = @import("../../../channel.zig").ChanError;
const listAudioDevices = @import("./audio_devices.zig").listAudioDevices;

pub const LinuxAudioCapture = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    pipewire_audio: *PipewireAudio,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .pipewire_audio = try .init(allocator),
        };
        errdefer self.pipewire_audio.deinit();

        return self;
    }

    pub fn deinit(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.pipewire_audio.deinit();
        self.allocator.destroy(self);
    }

    pub fn receiveData(context: *anyopaque) ChanError!*AudioCaptureData {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.pipewire_audio.data_chan.recv();
    }

    pub fn stop(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.pipewire_audio.data_chan.close(.{ .drain = true });
    }

    pub fn getAvailableDevices(context: *anyopaque, allocator: std.mem.Allocator) !AudioDeviceList {
        _ = context;
        return listAudioDevices(allocator);
    }

    pub fn updateSelectedDevices(context: *anyopaque, selected_devices: []const SelectedAudioDevice) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        try self.pipewire_audio.updateSelectedDevices(selected_devices);
    }

    pub fn audioCapture(self: *Self) AudioCapture {
        return .{ .ptr = self, .vtable = &.{
            .deinit = deinit,
            .receiveData = receiveData,
            .getAvailableDevices = getAvailableDevices,
            .updateSelectedDevices = updateSelectedDevices,
            .stop = stop,
        } };
    }
};
