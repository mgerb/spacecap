const std = @import("std");
const AudioCapture = @import("../audio_capture.zig").AudioCapture;
const AudioCaptureBufferedChan = @import("../audio_capture.zig").AudioCaptureBufferedChan;

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

    pub fn closeAllChannels(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
    }

    pub fn getDataChan(context: *anyopaque) *AudioCaptureBufferedChan {
        const self: *Self = @ptrCast(@alignCast(context));
        return &self.data_chan;
    }

    pub fn stop(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
    }

    pub fn audioCapture(self: *Self) AudioCapture {
        return .{ .ptr = self, .vtable = &.{
            .deinit = deinit,
            .closeAllChannels = closeAllChannels,
            .getDataChan = getDataChan,
            .stop = stop,
        } };
    }
};
