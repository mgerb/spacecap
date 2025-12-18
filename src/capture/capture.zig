const util = @import("../util.zig");
const std = @import("std");
const types = @import("../types.zig");
const vk = @import("vulkan");
const ChanError = @import("../channel.zig").ChanError;
const VulkanImageBuffer = @import("../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;
const rc = @import("zigrc");

pub const CaptureSourceType = enum { window, desktop };

pub const CaptureError = error{
    portal_service_not_found,
    source_picker_cancelled,
};

/// Capture interface.
pub const Capture = struct {
    const Self = @This();
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        selectSource: *const fn (*anyopaque, CaptureSourceType) anyerror!void,
        nextFrame: *const fn (*anyopaque) ChanError!void,
        closeAllChannels: *const fn (*anyopaque) void,
        waitForFrame: *const fn (*anyopaque) ChanError!rc.Arc(*VulkanImageBuffer),
        size: *const fn (*anyopaque) ?types.Size,
        stop: *const fn (*anyopaque) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn selectSource(self: *Self, source_type: CaptureSourceType) (CaptureError || anyerror)!void {
        return self.vtable.selectSource(self.ptr, source_type);
    }

    pub fn nextFrame(self: *Self) ChanError!void {
        return self.vtable.nextFrame(self.ptr);
    }

    /// Close all channels in the capture implementation. This is
    /// done so that we don't have any unexpected deadlocks. Any
    /// implementation of this interface must gracefully handle
    /// all channels being closed.
    pub fn closeAllChannels(self: *Self) void {
        return self.vtable.closeAllChannels(self.ptr);
    }

    pub fn waitForFrame(self: *Self) ChanError!rc.Arc(*VulkanImageBuffer) {
        return self.vtable.waitForFrame(self.ptr);
    }

    pub fn size(self: *Self) ?types.Size {
        return self.vtable.size(self.ptr);
    }

    pub fn stop(self: *Self) !void {
        return self.vtable.stop(self.ptr);
    }

    pub fn deinit(self: *Self) void {
        return self.vtable.deinit(self.ptr);
    }
};
