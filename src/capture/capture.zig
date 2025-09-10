const util = @import("../util.zig");
const std = @import("std");
const types = @import("../types.zig");
const vk = @import("vulkan");

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
        nextFrame: *const fn (*anyopaque) anyerror!void,
        closeNextFrameChan: *const fn (*anyopaque) anyerror!void,
        waitForFrame: *const fn (*anyopaque) anyerror!types.VkImages,
        size: *const fn (*anyopaque) ?types.Size,
        externalWaitSemaphore: *const fn (*anyopaque) ?vk.Semaphore,
        stop: *const fn (*anyopaque) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn selectSource(self: *Self, source_type: CaptureSourceType) (CaptureError || anyerror)!void {
        return self.vtable.selectSource(self.ptr, source_type);
    }

    pub fn nextFrame(self: *Self) !void {
        return self.vtable.nextFrame(self.ptr);
    }

    pub fn closeNextFrameChan(self: *Self) !void {
        return self.vtable.closeNextFrameChan(self.ptr);
    }

    pub fn waitForFrame(self: *Self) !types.VkImages {
        return self.vtable.waitForFrame(self.ptr);
    }

    pub fn size(self: *Self) ?types.Size {
        return self.vtable.size(self.ptr);
    }

    pub fn externalWaitSemaphore(self: *Self) ?vk.Semaphore {
        return self.vtable.externalWaitSemaphore(self.ptr);
    }

    pub fn stop(self: *Self) !void {
        return self.vtable.stop(self.ptr);
    }

    pub fn deinit(self: *Self) void {
        return self.vtable.deinit(self.ptr);
    }
};
