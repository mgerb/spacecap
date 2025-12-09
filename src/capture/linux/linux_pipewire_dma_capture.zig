const std = @import("std");

const vk = @import("vulkan");

const types = @import("../../types.zig");
const util = @import("../../util.zig");
const Vulkan = @import("../../vulkan/vulkan.zig").Vulkan;
const Pipewire = @import("./pipewire/pipewire.zig").Pipewire;
const Chan = @import("../../channel.zig").Chan;
const ChanError = @import("../../channel.zig").ChanError;
const CaptureSourceType = @import("../capture.zig").CaptureSourceType;
const Capture = @import("../capture.zig").Capture;
const CaptureError = @import("../capture.zig").CaptureError;

pub const LinuxPipewireDmaCapture = struct {
    const Self = @This();

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

    pub fn selectSource(context: *anyopaque, source_type: CaptureSourceType) (CaptureError || anyerror)!void {
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
            self.pipewire.?.deinit();
            self.pipewire = null;
        }
        try self.pipewire.?.selectSource(source_type);
    }

    pub fn nextFrame(context: *anyopaque) ChanError!void {
        const self: *Self = @ptrCast(@alignCast(context));
        try self.pipewire.?.rx_chan.send(true);
    }

    pub fn closeAllChannels(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.pipewire) |pipewire| {
            pipewire.tx_chan.close();
            pipewire.rx_chan.close();
            pipewire.buffer_queue.close();
        }
    }

    pub fn waitForFrame(context: *anyopaque) ChanError!types.VkImages {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.pipewire.?.tx_chan.recv();
    }

    pub fn size(context: *anyopaque) ?types.Size {
        const self: *Self = @ptrCast(@alignCast(context));
        return if (self.pipewire.?.info) |info|
            .{
                .width = info.size.width,
                .height = info.size.height,
            }
        else
            null;
    }

    pub fn externalWaitSemaphore(context: *anyopaque) ?vk.Semaphore {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.pipewire.?.vk_foreign_semaphore;
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

    // pub fn selectedScreenCastIdentifier(self: *Self) ?[]const u8 {
    //     if (self.pipewire) |pw| {
    //         return pw.portal.selected_screen_name;
    //     }
    //     return null;
    // }

    pub fn deinit(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.pipewire) |pipewire| {
            pipewire.deinit();
        }
        self.allocator.destroy(self);
    }

    pub fn capture(self: *Self) Capture {
        return .{
            .ptr = self,
            .vtable = &.{
                .selectSource = selectSource,
                .nextFrame = nextFrame,
                .closeAllChannels = closeAllChannels,
                .waitForFrame = waitForFrame,
                .size = size,
                .externalWaitSemaphore = externalWaitSemaphore,
                .stop = stop,
                .deinit = deinit,
            },
        };
    }
};
