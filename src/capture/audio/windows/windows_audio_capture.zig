const std = @import("std");
const AudioCapture = @import("../audio_capture.zig").AudioCapture;
const AudioCaptureBufferedChan = @import("../audio_capture.zig").AudioCaptureBufferedChan;
const AudioCaptureData = @import("../audio_capture.zig").AudioCaptureData;
const ChanError = @import("../../../channel.zig").ChanError;

pub const WindowsAudioCapture = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    data_chan: AudioCaptureBufferedChan,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);

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

    pub fn receiveData(context: *anyopaque) ChanError!AudioCaptureData {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.data_chan.recv();
    }

    pub fn stop(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
    }

    pub fn audioCapture(self: *Self) AudioCapture {
        return .{ .ptr = self, .vtable = &.{
            .deinit = deinit,
            .receiveData = receiveData,
            .stop = stop,
        } };
    }
};
