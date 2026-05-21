const std = @import("std");
const AudioCapture = @import("../audio_capture.zig").AudioCapture;
const AudioCaptureBufferedChan = @import("../audio_capture.zig").AudioCaptureBufferedChan;
const AudioDeviceList = @import("../audio_capture.zig").AudioDeviceList;
const SelectedAudioDevice = @import("../audio_capture.zig").SelectedAudioDevice;
const AudioCaptureData = @import("../audio_capture_data.zig");
const ChanError = @import("../../../channel.zig").ChanError;
const Arc = @import("../../../arc.zig").Arc;

pub const WindowsAudioCapture = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    io: std.Io,
    data_chan: AudioCaptureBufferedChan,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .data_chan = try .init(allocator, io),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        defer self.allocator.destroy(self);
        self.data_chan.deinit();
    }

    pub fn receive_data(context: *anyopaque) ChanError!Arc(AudioCaptureData) {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.data_chan.recv();
    }

    pub fn stop(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.data_chan.close(.{ .drain = true });
    }

    pub fn get_available_devices(context: *anyopaque, allocator: std.mem.Allocator, _: std.Io) !AudioDeviceList {
        _ = context;
        return AudioDeviceList.init(allocator);
    }

    pub fn update_selected_devices(context: *anyopaque, selected_devices: []const SelectedAudioDevice) !void {
        _ = context;
        _ = selected_devices;
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
