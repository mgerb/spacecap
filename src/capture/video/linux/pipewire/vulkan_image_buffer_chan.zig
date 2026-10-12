const std = @import("std");
const Arc = @import("../../../../arc.zig").Arc;

const ChanError = @import("../../../../channel.zig").ChanError;
const BufferedChan = @import("../../../../channel.zig").BufferedChan;
const VulkanImageBuffer = @import("../../../../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;

/// Buffered channel wrapper that drains and releases queued VulkanImageBuffer
/// refs on shutdown. It is size of one so that we can always drain, and then
/// do a non-blocking send.
pub const VulkanImageBufferChan = struct {
    const Self = @This();
    chan: BufferedChan(Arc(VulkanImageBuffer), 1),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        return .{
            .chan = try .init(allocator, io),
        };
    }

    /// Drain any queued buffers and deinit.
    pub fn deinit(self: *Self) void {
        self.drain();
        self.chan.deinit();
    }

    /// Drain any queued buffers and close the channel.
    pub fn close(self: *Self) void {
        self.drain();
        self.chan.close(.{});
    }

    /// NOTE: Increment the Arc ref count with `clone` before calling. Errors
    /// must be handled by the caller.
    /// NOTE: The Vulkan image must not be pending any fence/semaphore.
    pub fn send(self: *Self, vulkan_image_buffer: Arc(VulkanImageBuffer)) ChanError!void {
        return self.chan.send(vulkan_image_buffer);
    }

    pub fn recv(self: *Self) ChanError!Arc(VulkanImageBuffer) {
        return self.chan.recv();
    }

    pub fn try_recv(self: *Self) ChanError!?Arc(VulkanImageBuffer) {
        return self.chan.try_recv();
    }

    /// Drain and release all queued buffers.
    pub fn drain(self: *Self) void {
        while (self.chan.try_recv() catch null) |old_vulkan_image_buffer| {
            old_vulkan_image_buffer.deinit();
        }
    }
};
