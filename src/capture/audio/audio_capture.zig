const std = @import("std");
const BufferedChan = @import("../../channel.zig").BufferedChan;
const ChanError = @import("../../channel.zig").ChanError;

pub const AudioCaptureData = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    pcm_data: []const f32,
    // TODO: Timestamp.

    /// pcm_data is copied into AudioCaptureData.
    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        pcm_data: []const f32,
    ) !@This() {
        return .{
            .allocator = allocator,
            .id = try allocator.dupe(u8, id),
            .pcm_data = try allocator.dupe(f32, pcm_data),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.id);
        self.allocator.free(self.pcm_data);
    }
};

// TODO: Adjust chan size.
pub const AudioCaptureBufferedChan = BufferedChan(AudioCaptureData, 1_000);

/// VideoCapture interface.
pub const AudioCapture = struct {
    const Self = @This();
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        receiveData: *const fn (*anyopaque) ChanError!AudioCaptureData,
        stop: *const fn (*anyopaque) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    /// Receive audio capture data. Caller owns the memory and must deinit.
    pub fn receiveData(self: *Self) ChanError!AudioCaptureData {
        return self.vtable.receiveData(self.ptr);
    }

    pub fn stop(self: *Self) !void {
        return self.vtable.stop(self.ptr);
    }

    pub fn deinit(self: *Self) void {
        return self.vtable.deinit(self.ptr);
    }
};
