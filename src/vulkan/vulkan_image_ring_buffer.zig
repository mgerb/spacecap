const std = @import("std");
const vk = @import("vulkan");
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const VulkanImageBuffer = @import("./vulkan_image_buffer.zig").VulkanImageBuffer;
const Arc = @import("../arc.zig").Arc;

const BUFFER_SIZE = 3;

pub const VulkanImageRingBuffer = struct {
    const Self = @This();
    const log = std.log.scoped(.vulkan_image_ring_buffer);

    allocator: std.mem.Allocator,
    io: std.Io,
    // TODO: We may want to wrap this in a Mutex.
    buffers: [BUFFER_SIZE]Arc(VulkanImageBuffer) = undefined,
    vulkan: *Vulkan,
    most_recent_index: ?u32 = null,
    mutex: std.Io.Mutex = .init,

    pub fn init(
        args: VulkanImageBuffer.InitArgs,
    ) !*Self {
        const self = try args.allocator.create(Self);
        errdefer args.allocator.destroy(self);

        self.* = .{
            .allocator = args.allocator,
            .io = args.io,
            .vulkan = args.vulkan,
        };

        self.buffers[0] = try VulkanImageBuffer.init(args);
        errdefer self.buffers[0].deinit();
        self.buffers[1] = try VulkanImageBuffer.init(args);
        errdefer self.buffers[1].deinit();
        self.buffers[2] = try VulkanImageBuffer.init(args);
        errdefer self.buffers[2].deinit();

        return self;
    }

    pub fn deinit(self: *Self) void {
        defer self.allocator.destroy(self);
        for (self.buffers) |buffer| {
            buffer.deinit();
        }
    }

    pub fn wait_for_fences(self: *Self) void {
        var wait_fences: [BUFFER_SIZE]vk.Fence = undefined;
        for (self.buffers, 0..) |buffer, i| {
            wait_fences[i] = buffer.as_ptr().fence;
        }

        const result = self.vulkan.device.waitForFences(
            wait_fences[0..],
            .true,
            std.math.maxInt(u64),
        ) catch |err| {
            log.err("[wait_for_fences] wait for capture ring buffer fences error: {}", .{err});
            return;
        };
        if (result != .success) {
            log.err("[wait_for_fences] wait for capture ring buffer fences result: {}", .{result});
        }
    }

    /// Find a buffer that currently isn't locked, lock it,
    /// then copy the source image into the buffer. Will return
    /// a new semaphore, but if a buffer is not available, the
    /// wait semaphore provided will be returned.
    pub fn copy_image_to_ring_buffer(self: *Self, args: struct {
        src_image: vk.Image,
        src_width: u32,
        src_height: u32,
        wait_semaphore: ?vk.Semaphore,
        use_signal_semaphore: bool,
        timestamp_ns: i128,
    }) !struct {
        vulkan_image_buffer: ?Arc(VulkanImageBuffer) = null,
        semaphore: ?vk.Semaphore = null,
        fence: ?vk.Fence = null,
    } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (0..3) |i| {
            // most_recent_index will only be null after the ring buffer has been initialized.
            if (self.most_recent_index != null and i == @as(usize, @intCast(self.most_recent_index.?))) {
                continue;
            }
            const vulkan_image_buffer = self.buffers[i];
            var buffer = vulkan_image_buffer.as_ptr();
            if (buffer.in_use.load(.acquire)) {
                continue;
            }
            self.most_recent_index = @intCast(i);
            try buffer.copy_image(.{
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
        return .{ .semaphore = args.wait_semaphore };
    }

    /// - Get the most recent buffer
    /// - Increment ref count
    /// - set in_use to true
    pub fn get_most_recent_buffer(self: *Self) ?Arc(VulkanImageBuffer) {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.most_recent_index) |most_recent_index| {
            const buffer = self.buffers[most_recent_index].clone();
            buffer.as_ptr().in_use.store(true, .release);
            return buffer;
        }

        return null;
    }
};
