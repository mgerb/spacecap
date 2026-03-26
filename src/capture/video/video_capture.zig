const util = @import("../../util.zig");
const std = @import("std");
const types = @import("../../types.zig");
const vk = @import("vulkan");
const ChanError = @import("../../channel.zig").ChanError;
const VulkanImageBuffer = @import("../../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;
const rc = @import("zigrc");

pub const VideoCaptureSourceType = enum { window, desktop };

pub const VideoCaptureSelection = union(enum) {
    source_type: VideoCaptureSourceType,
    restore_session,
};

pub const VideoCaptureError = error{
    portal_service_not_found,
    source_picker_cancelled,
};

/// VideoCapture interface.
pub const VideoCapture = struct {
    const Self = @This();
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        select_source: *const fn (*anyopaque, VideoCaptureSelection, u32) anyerror!void,
        update_fps: *const fn (*anyopaque, u32) anyerror!void,
        should_restore_capture_session: *const fn (*anyopaque) anyerror!bool,
        next_frame: *const fn (*anyopaque) ChanError!void,
        close_all_channels: *const fn (*anyopaque) void,
        wait_for_frame: *const fn (*anyopaque) ChanError!rc.Arc(*VulkanImageBuffer),
        size: *const fn (*anyopaque) ?types.Size,
        stop: *const fn (*anyopaque) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn select_source(self: *Self, selection: VideoCaptureSelection, fps: u32) (VideoCaptureError || anyerror)!void {
        return self.vtable.select_source(self.ptr, selection, fps);
    }

    pub fn update_fps(self: *Self, fps: u32) !void {
        return self.vtable.update_fps(self.ptr, fps);
    }

    pub fn should_restore_capture_session(self: *Self) !bool {
        return self.vtable.should_restore_capture_session(self.ptr);
    }

    pub fn next_frame(self: *Self) ChanError!void {
        return self.vtable.next_frame(self.ptr);
    }

    /// Close all channels in the capture implementation. This is
    /// done so that we don't have any unexpected deadlocks. Any
    /// implementation of this interface must gracefully handle
    /// all channels being closed.
    pub fn close_all_channels(self: *Self) void {
        return self.vtable.close_all_channels(self.ptr);
    }

    pub fn wait_for_frame(self: *Self) ChanError!rc.Arc(*VulkanImageBuffer) {
        return self.vtable.wait_for_frame(self.ptr);
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
