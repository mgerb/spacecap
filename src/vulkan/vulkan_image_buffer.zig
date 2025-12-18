const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const std = @import("std");
const assert = std.debug.assert;
const vk = @import("vulkan");
const rc = @import("zigrc");

/// An image buffer that goes in the vulkan image ring buffer.
pub const VulkanImageBuffer = struct {
    const log = std.log.scoped(.VulkanImageBuffer);
    const Self = @This();

    allocator: std.mem.Allocator,
    vulkan: *Vulkan,
    image: vk.Image,
    image_view: vk.ImageView,
    image_memory: vk.DeviceMemory,
    image_layout: vk.ImageLayout,
    dst_stage_mask: vk.PipelineStageFlags2,
    dst_access_mask: vk.AccessFlags2,
    command_buffer: vk.CommandBuffer,
    command_pool: vk.CommandPool,
    signal_semaphore: vk.Semaphore,
    fence: vk.Fence,
    /// Time when the image was last copied.
    copy_image_timestamp: i128 = 0,
    src_queue_family_index: u32,

    width: u32,
    height: u32,
    in_use: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},

    pub const InitArgs = struct {
        allocator: std.mem.Allocator,
        vulkan: *Vulkan,
        width: u32,
        height: u32,
        image_layout: vk.ImageLayout,
        dst_stage_mask: vk.PipelineStageFlags2,
        dst_access_mask: vk.AccessFlags2,
        usage: vk.ImageUsageFlags,
        image_component_mapping: vk.ComponentMapping,
        src_queue_family_index: u32,
    };

    pub fn init(
        args: InitArgs,
    ) !rc.Arc(*Self) {
        const base_image_usage: vk.ImageUsageFlags = .{
            .transfer_dst_bit = true,
        };

        const image_create_info = vk.ImageCreateInfo{
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = .{ .width = args.width, .height = args.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = @bitCast(@as(vk.Flags, @bitCast(base_image_usage)) | @as(vk.Flags, @bitCast(args.usage))),
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        };

        const image = try args.vulkan.device.createImage(&image_create_info, null);
        const mem_req = args.vulkan.device.getImageMemoryRequirements(image);
        const image_memory = try args.vulkan.allocate(mem_req, .{ .device_local_bit = true }, null);
        try args.vulkan.device.bindImageMemory(image, image_memory, 0);

        const image_view_create_info = vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .components = args.image_component_mapping,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const image_view = try args.vulkan.device.createImageView(&image_view_create_info, null);

        const command_pool = try args.vulkan.device.createCommandPool(&.{
            .queue_family_index = args.vulkan.graphics_queue.family,
            .flags = .{ .reset_command_buffer_bit = true },
        }, null);

        const cmd_alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };

        var command_buffer: vk.CommandBuffer = undefined;
        try args.vulkan.device.allocateCommandBuffers(&cmd_alloc_info, @ptrCast(&command_buffer));
        const signal_semaphore = try args.vulkan.device.createSemaphore(&.{}, null);
        const fence = try args.vulkan.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);

        const self = try args.allocator.create(Self);

        self.* = .{
            .allocator = args.allocator,
            .vulkan = args.vulkan,
            .image = image,
            .image_view = image_view,
            .image_memory = image_memory,
            .command_buffer = command_buffer,
            .command_pool = command_pool,
            .signal_semaphore = signal_semaphore,
            .fence = fence,
            .image_layout = args.image_layout,
            .dst_stage_mask = args.dst_stage_mask,
            .dst_access_mask = args.dst_access_mask,
            .width = args.width,
            .height = args.height,
            .src_queue_family_index = args.src_queue_family_index,
            .in_use = std.atomic.Value(bool).init(false),
        };

        return .init(args.allocator, self);
    }

    pub fn deinit(self: *Self) void {
        _ = self.mutex.tryLock();
        _ = self.vulkan.device.waitForFences(1, @ptrCast(&self.fence), .true, std.math.maxInt(u64)) catch |err| {
            log.err("[deinit] error waiting for fences: {}", .{err});
        };
        self.vulkan.device.destroyImage(self.image, null);
        self.vulkan.device.destroyImageView(self.image_view, null);
        self.vulkan.device.freeMemory(self.image_memory, null);
        self.vulkan.device.freeCommandBuffers(self.command_pool, 1, @ptrCast(&self.command_buffer));
        self.vulkan.device.destroyCommandPool(self.command_pool, null);
        self.vulkan.device.destroyFence(self.fence, null);
        self.vulkan.device.destroySemaphore(self.signal_semaphore, null);
        self.allocator.destroy(self);
    }

    /// Copy an external vulkan image into the local image buffer.
    pub fn copyImage(
        self: *Self,
        args: struct {
            src_image: vk.Image,
            src_width: u32,
            src_height: u32,
            wait_semaphore: ?vk.Semaphore,
            use_signal_semaphore: bool = false,
        },
    ) !void {
        self.copy_image_timestamp = std.time.nanoTimestamp();
        const result = try self.vulkan.device.waitForFences(1, @ptrCast(&self.fence), .true, std.math.maxInt(u64));

        if (result != .success) {
            return error.waitForFences;
        }

        var signal_semaphores = if (args.use_signal_semaphore) [_]vk.Semaphore{self.signal_semaphore} else null;
        var wait_semaphores = if (args.wait_semaphore != null) [_]vk.Semaphore{args.wait_semaphore.?} else null;

        try self.vulkan.copyImage(
            self.command_buffer,
            args.src_image,
            self.image,
            args.src_width,
            args.src_height,
            self.width,
            self.height,
            .{
                .new_layout = self.image_layout,
                .dst_stage_mask = self.dst_stage_mask,
                .dst_access_mask = self.dst_access_mask,
                .src_queue_family_index = self.src_queue_family_index,
                .wait_semaphores = if (wait_semaphores != null) wait_semaphores.?[0..] else &.{},
                .signal_semaphores = if (signal_semaphores != null) signal_semaphores.?[0..] else &.{},
                .fence = self.fence,
            },
        );
    }
};
