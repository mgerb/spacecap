const std = @import("std");
const AudioCapture = @import("../audio_capture.zig").AudioCapture;
const AudioCaptureBufferedChan = @import("../audio_capture.zig").AudioCaptureBufferedChan;
const AudioDeviceList = @import("../audio_capture.zig").AudioDeviceList;
const SelectedAudioDevice = @import("../audio_capture.zig").SelectedAudioDevice;
const AudioCaptureData = @import("../audio_capture_data.zig");
const ChanError = @import("../../../channel.zig").ChanError;

pub const WindowsAudioCapture = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    data_chan: AudioCaptureBufferedChan,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .data_chan = try .init(allocator),
        };

        return self;
    }

    pub fn deinit(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.data_chan.deinit();
        self.allocator.destroy(self);
    }

    pub fn receiveData(context: *anyopaque) ChanError!*AudioCaptureData {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.data_chan.recv();
    }

    pub fn stop(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
    }

    pub fn getAvailableDevices(context: *anyopaque, allocator: std.mem.Allocator) !AudioDeviceList {
        _ = context;
        return AudioDeviceList.init(allocator);
    }

    pub fn updateSelectedDevices(context: *anyopaque, selected_devices: []const SelectedAudioDevice) !void {
        _ = context;
        _ = selected_devices;
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
