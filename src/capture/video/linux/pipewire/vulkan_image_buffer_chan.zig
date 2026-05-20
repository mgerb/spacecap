const std = @import("std");
const Arc = @import("../../../../arc.zig").Arc;

const ChanError = @import("../../../../channel.zig").ChanError;
const BufferedChan = @import("../../../../channel.zig").BufferedChan;
const VulkanImageBuffer = @import("../../../../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;

/// Buffered channel wrapper that drains and releases queued VulkanImageBuffer refs on shutdown.
pub const VulkanImageBufferChan = struct {
    const Self = @This();
    chan: BufferedChan(Arc(VulkanImageBuffer), 1),

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .chan = try .init(allocator),
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

    /// Increment the buffer ref count, set to in use, then send on the channel.
    /// On send error, release the buffer and return the error.
    pub fn send(self: *Self, vulkan_image_buffer: Arc(VulkanImageBuffer)) ChanError!void {
        defer vulkan_image_buffer.deinit();
        errdefer vulkan_image_buffer.as_ptr().in_use.store(false, .release);

        vulkan_image_buffer.as_ptr().in_use.store(true, .release);
        try self.chan.send(vulkan_image_buffer.clone());
    }

    pub fn recv(self: *Self) ChanError!Arc(VulkanImageBuffer) {
        return self.chan.recv();
    }

    pub fn try_recv(self: *Self) ChanError!?Arc(VulkanImageBuffer) {
        return self.chan.tryRecv();
    }

    /// Drain and release all queued buffers.
    pub fn drain(self: *Self) void {
        while (self.chan.try_recv() catch null) |old_vulkan_image_buffer| {
            old_vulkan_image_buffer.as_ptr().in_use.store(false, .release);
            old_vulkan_image_buffer.deinit();
        }
    }
};
