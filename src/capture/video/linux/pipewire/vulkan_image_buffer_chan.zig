const std = @import("std");
const rc = @import("zigrc");

const ChanError = @import("../../../../channel.zig").ChanError;
const BufferedChan = @import("../../../../channel.zig").BufferedChan;
const VulkanImageBuffer = @import("../../../../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;

/// Buffered channel wrapper that drains and releases queued VulkanImageBuffer refs on shutdown.
pub const VulkanImageBufferChan = struct {
    const Self = @This();
    chan: BufferedChan(rc.Arc(*VulkanImageBuffer), 1),

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
    pub fn send(self: *Self, vulkan_image_buffer: rc.Arc(*VulkanImageBuffer)) ChanError!void {
        _ = vulkan_image_buffer.retain();
        vulkan_image_buffer.value.*.in_use.store(true, .release);
        self.chan.send(vulkan_image_buffer) catch |err| {
            vulkan_image_buffer.value.*.in_use.store(false, .release);
            if (vulkan_image_buffer.releaseUnwrap()) |val| val.deinit();
            return err;
        };
    }

    pub fn recv(self: *Self) ChanError!rc.Arc(*VulkanImageBuffer) {
        return self.chan.recv();
    }

    pub fn tryRecv(self: *Self) ChanError!?rc.Arc(*VulkanImageBuffer) {
        return self.chan.tryRecv();
    }

    /// Drain and release all queued buffers.
    pub fn drain(self: *Self) void {
        while (self.chan.tryRecv() catch null) |old_vulkan_image_buffer| {
            old_vulkan_image_buffer.value.*.in_use.store(false, .release);
            if (old_vulkan_image_buffer.releaseUnwrap()) |val| val.deinit();
        }
    }
};
