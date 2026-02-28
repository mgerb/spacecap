const std = @import("std");

const vk = @import("vulkan");

const types = @import("../../../types.zig");
const util = @import("../../../util.zig");
const TokenStorage = @import("../../../common/linux/token_storage.zig");
const Vulkan = @import("../../../vulkan/vulkan.zig").Vulkan;
const Pipewire = @import("./pipewire/pipewire.zig").Pipewire;
const Chan = @import("../../../channel.zig").Chan;
const ChanError = @import("../../../channel.zig").ChanError;
const VideoCaptureSelection = @import("../video_capture.zig").VideoCaptureSelection;
const VideoCapture = @import("../video_capture.zig").VideoCapture;
const VideoCaptureError = @import("../video_capture.zig").VideoCaptureError;
const VulkanImageBuffer = @import("../../../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;
const rc = @import("zigrc");

pub const LinuxPipewireDmaCapture = struct {
    const Self = @This();
    const log = std.log.scoped(.LinuxPipewireDmaCapture);

    allocator: std.mem.Allocator,
    vulkan: *Vulkan,
    pipewire: ?*Pipewire = null,

    pub fn init(allocator: std.mem.Allocator, vulkan: *Vulkan) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .vulkan = vulkan,
        };

        return self;
    }

    pub fn selectSource(context: *anyopaque, selection: VideoCaptureSelection, fps: u32) (VideoCaptureError || anyerror)!void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.pipewire) |pipewire| {
            // TODO: Probably don't have to destroy all of pipewire
            // to select a new source here.
            pipewire.deinit();
            self.pipewire = null;
        }

        self.pipewire = try Pipewire.init(
            self.allocator,
            self.vulkan,
        );
        errdefer {
            if (self.pipewire) |pipewire| {
                pipewire.deinit();
                self.pipewire = null;
            }
        }
        try self.pipewire.?.selectSource(selection, fps);
    }

    pub fn updateFps(context: *anyopaque, fps: u32) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.pipewire) |pipewire| {
            try pipewire.updateFps(fps);
        }
    }

    pub fn shouldRestoreCaptureSession(context: *anyopaque) !bool {
        const self: *Self = @ptrCast(@alignCast(context));
        const restore_token = TokenStorage.loadToken(self.allocator, "restore_token") catch |err| {
            log.err("failed to load restore token: {}", .{err});
            return false;
        };
        if (restore_token == null) {
            return false;
        }
        defer self.allocator.free(restore_token.?);

        return restore_token.?.len > 0;
    }

    pub fn nextFrame(context: *anyopaque) ChanError!void {
        const self: *Self = @ptrCast(@alignCast(context));
        try self.pipewire.?.rx_chan.send(true);
    }

    pub fn closeAllChannels(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.pipewire) |pipewire| {
            pipewire.tx_chan.close(.{});
            pipewire.rx_chan.close(.{});
            pipewire.vulkan_image_buffer_chan.close();
        }
    }

    pub fn waitForFrame(context: *anyopaque) ChanError!rc.Arc(*VulkanImageBuffer) {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.pipewire.?.tx_chan.recv();
    }

    pub fn size(context: *anyopaque) ?types.Size {
        const self: *Self = @ptrCast(@alignCast(context));
        const pipewire = self.pipewire orelse return null;
        return if (pipewire.info) |info|
            .{
                .width = info.size.width,
                .height = info.size.height,
            }
        else
            null;
    }

    pub fn stop(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.pipewire) |pipewire| {
            // TODO: Probably don't have to destroy all of pipewire
            // to select a new source here.
            pipewire.deinit();
            self.pipewire = null;
        }
    }

    pub fn deinit(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.pipewire) |pipewire| {
            pipewire.deinit();
            self.pipewire = null;
        }
        self.allocator.destroy(self);
    }

    pub fn videoCapture(self: *Self) VideoCapture {
        return .{
            .ptr = self,
            .vtable = &.{
                .selectSource = selectSource,
                .updateFps = updateFps,
                .shouldRestoreCaptureSession = shouldRestoreCaptureSession,
                .nextFrame = nextFrame,
                .closeAllChannels = closeAllChannels,
                .waitForFrame = waitForFrame,
                .size = size,
                .stop = stop,
                .deinit = deinit,
            },
        };
    }
};
