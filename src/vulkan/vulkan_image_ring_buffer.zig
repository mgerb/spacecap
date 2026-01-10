const std = @import("std");
const vk = @import("vulkan");
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const imguiz = @import("imguiz").imguiz;
const util = @import("../util.zig");
const VulkanImageBuffer = @import("./vulkan_image_buffer.zig").VulkanImageBuffer;
const BufferedChan = @import("../channel.zig").BufferedChan;
const rc = @import("zigrc");

pub const VulkanImageRingBuffer = struct {
    const Self = @This();
    // TODO: Make ring buffer size variable at comptime.
    // TODO: Wrap in mutex.
    buffers: [3]rc.Arc(*VulkanImageBuffer),
    vulkan: *Vulkan,
    most_recent_index: ?u32 = null,
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    pub fn init(
        args: VulkanImageBuffer.InitArgs,
    ) !*Self {
        // TODO: add errdefer to clean up allocations.
        const self = try args.allocator.create(Self);

        self.* = .{
            .allocator = args.allocator,
            .buffers = .{
                try VulkanImageBuffer.init(args),
                try VulkanImageBuffer.init(args),
                try VulkanImageBuffer.init(args),
            },
            .vulkan = args.vulkan,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.buffers) |buffer| {
            if (buffer.releaseUnwrap()) |val| val.deinit();
        }
        self.allocator.destroy(self);
    }

    /// Find a buffer that currently isn't locked, lock it,
    /// then copy the source image into the buffer. Will return
    /// a new semaphore, but if a buffer is not available, the
    /// wait semaphore provided will be returned.
    pub fn copyImageToRingBuffer(self: *Self, args: struct {
        src_image: vk.Image,
        src_width: u32,
        src_height: u32,
        wait_semaphore: ?vk.Semaphore,
        use_signal_semaphore: bool,
        timestamp_ns: i128,
    }) !struct {
        vulkan_image_buffer: ?rc.Arc(*VulkanImageBuffer) = null,
        semaphore: ?vk.Semaphore = null,
        fence: ?vk.Fence = null,
    } {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..3) |i| {
            // most_recent_index will only be null after the ring buffer has been initialized.
            if (self.most_recent_index != null and i == @as(usize, @intCast(self.most_recent_index.?))) {
                continue;
            }
            const vulkan_image_buffer = self.buffers[i];
            var buffer = vulkan_image_buffer.value.*;
            if (buffer.in_use.load(.acquire)) {
                continue;
            }
            const did_lock = buffer.mutex.tryLock();

            if (did_lock) {
                defer buffer.mutex.unlock();
                self.most_recent_index = @intCast(i);
                try buffer.copyImage(.{
                    .src_image = args.src_image,
                    .src_width = args.src_width,
                    .src_height = args.src_height,
                    .wait_semaphore = args.wait_semaphore,
                    .use_signal_semaphore = args.use_signal_semaphore,
                    .timestamp_ns = args.timestamp_ns,
                });
                return .{
                    .vulkan_image_buffer = vulkan_image_buffer,
                    .semaphore = buffer.signal_semaphore,
                    .fence = buffer.fence,
                };
            }
        }
        return .{ .semaphore = args.wait_semaphore };
    }

    // Get the most recent buffer and lock the mutex. The caller
    // MUST unlock the mutex.
    pub fn getMostRecentBuffer(self: *Self) ?*VulkanImageBuffer {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.most_recent_index) |most_recent_index| {
            const buffer = self.buffers[most_recent_index].value.*;
            buffer.mutex.lock();
            return buffer;
        }

        return null;
    }
};
