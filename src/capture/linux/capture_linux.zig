const std = @import("std");

const vk = @import("vulkan");

const types = @import("../../types.zig");
const util = @import("../../util.zig");
const Vulkan = @import("../../vulkan/vulkan.zig").Vulkan;
const CaptureError = @import("../capture_error.zig").CaptureError;
const Pipewire = @import("./pipewire/pipewire.zig").Pipewire;
const Chan = @import("../../channel.zig").Chan;
const CaptureSourceType = @import("../capture.zig").CaptureSourceType;

pub const Capture = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    vulkan: *Vulkan,
    pipewire: ?*Pipewire = null,

    pub fn init(allocator: std.mem.Allocator, vulkan: *Vulkan) (CaptureError || anyerror)!*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .vulkan = vulkan,
        };

        return self;
    }

    pub fn selectSource(self: *Self, source_type: CaptureSourceType) !void {
        if (self.pipewire) |pipewire| {
            // TODO: Probably don't have to destroy all of pipewire
            // to select a new source here.
            try pipewire.stop();
            pipewire.deinit();
            self.pipewire = null;
        }

        self.pipewire = try Pipewire.init(
            self.allocator,
            self.vulkan,
        );
        errdefer {
            self.pipewire.?.deinit();
            self.pipewire = null;
        }
        try self.pipewire.?.selectSource(source_type);
    }

    pub fn nextFrame(self: *Self) !void {
        try self.pipewire.?.rx_chan.send(true);
    }

    pub fn closeNextFrameChan(self: *Self) !void {
        if (self.pipewire) |pipewire| {
            pipewire.rx_chan.close();
        }
    }

    pub fn waitForFrame(self: *const Self) !types.VkImages {
        return self.pipewire.?.tx_chan.recv();
    }

    pub fn waitForReady(self: *const Self) !void {
        _ = self;
        // pipewire needs to call next frame to prepare for ready
        // self.pipewire.?.nextFrame();
        // _ = try self.pipewire.?.frame_chan.recv();
    }

    pub fn size(self: *const Self) ?types.Size {
        return if (self.pipewire.?.info) |info|
            .{
                .width = info.size.width,
                .height = info.size.height,
            }
        else
            null;
    }

    pub fn vkImage(self: *const Self) ?vk.Image {
        return self.pipewire.vk_image;
    }

    pub fn vkImageView(self: *const Self) ?vk.ImageView {
        return self.pipewire.vk_image_view;
    }

    pub fn externalWaitSemaphore(self: *const Self) ?vk.Semaphore {
        return self.pipewire.?.vk_foreign_semaphore;
    }

    pub fn stop(self: *Self) !void {
        if (self.pipewire) |pipewire| {
            // TODO: Probably don't have to destroy all of pipewire
            // to select a new source here.
            try pipewire.stop();
            pipewire.deinit();
            self.pipewire = null;
        }
    }

    pub fn selectedScreenCastIdentifier(self: *Self) ?[]const u8 {
        if (self.pipewire) |pw| {
            return pw.portal.selected_screen_name;
        }
        return null;
    }

    pub fn deinit(self: *Self) void {
        if (self.pipewire) |pipewire| {
            pipewire.deinit();
        }
        self.allocator.destroy(self);
    }
};
