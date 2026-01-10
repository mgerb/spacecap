const BufferedChan = @import("../../channel.zig").BufferedChan;

pub const AudioCaptureBufferedChan = BufferedChan(u8, 1);

/// VideoCapture interface.
pub const AudioCapture = struct {
    const Self = @This();
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        closeAllChannels: *const fn (*anyopaque) void,
        getDataChan: *const fn (*anyopaque) *AudioCaptureBufferedChan,
        stop: *const fn (*anyopaque) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    /// Close all channels in the capture implementation. This is
    /// done so that we don't have any unexpected deadlocks. Any
    /// implementation of this interface must gracefully handle
    /// all channels being closed.
    pub fn closeAllChannels(self: *Self) void {
        return self.vtable.closeAllChannels(self.ptr);
    }

    pub fn getDataChan(self: *Self) *AudioCaptureBufferedChan {
        return self.vtable.getDataChan(self.ptr);
    }

    pub fn stop(self: *Self) !void {
        return self.vtable.stop(self.ptr);
    }

    pub fn deinit(self: *Self) void {
        return self.vtable.deinit(self.ptr);
    }
};
