const util = @import("../util.zig");
const std = @import("std");
const types = @import("../types.zig");
const vk = @import("vulkan");
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const imguiz = @import("imguiz").imguiz;

pub const CaptureSourceType = enum { window, desktop };

pub const CaptureError = error{
    portal_service_not_found,
    source_picker_cancelled,
};

pub const Capture = struct {
    const Self = @This();
    ptr: *anyopaque,
    vtable: *const VTable,
    vulkan: *Vulkan,
    image: ?vk.Image = null,
    image_view: ?vk.ImageView = null,
    image_memory: ?vk.DeviceMemory = null,
    fence: ?vk.Fence = null,
    command_buffer: ?vk.CommandBuffer = null,

    const VTable = struct {
        selectSource: *const fn (*anyopaque, CaptureSourceType) anyerror!void,
        nextFrame: *const fn (*anyopaque) anyerror!void,
        closeNextFrameChan: *const fn (*anyopaque) anyerror!void,
        waitForFrame: *const fn (*anyopaque) anyerror!types.VkImages,
        size: *const fn (*anyopaque) ?types.Size,
        externalWaitSemaphore: *const fn (*anyopaque) ?vk.Semaphore,
        stop: *const fn (*anyopaque) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn selectSource(self: *Self, source_type: CaptureSourceType) (CaptureError || anyerror)!void {
        return self.vtable.selectSource(self.ptr, source_type);
    }

    pub fn nextFrame(self: *Self) !void {
        return self.vtable.nextFrame(self.ptr);
    }

    pub fn closeNextFrameChan(self: *Self) !void {
        return self.vtable.closeNextFrameChan(self.ptr);
    }

    pub fn waitForFrame(self: *Self) !types.VkImages {
        return self.vtable.waitForFrame(self.ptr);
    }

    pub fn size(self: *Self) ?types.Size {
        return self.vtable.size(self.ptr);
    }

    pub fn externalWaitSemaphore(self: *Self) ?vk.Semaphore {
        return self.vtable.externalWaitSemaphore(self.ptr);
    }

    pub fn stop(self: *Self) !void {
        return self.vtable.stop(self.ptr);
    }

    pub fn deinit(self: *Self) void {
        return self.vtable.deinit(self.ptr);
    }

    fn createImage(self: *Self, width: u32, height: u32) !void {
        const image_create_info = vk.ImageCreateInfo{
            .image_type = .@"2d",
            .format = .b8g8r8a8_unorm,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        };

        self.image = try self.vulkan.device.createImage(&image_create_info, null);
        const mem_req = self.vulkan.device.getImageMemoryRequirements(self.image.?);
        self.image_memory = try self.vulkan.allocate(mem_req, .{ .device_local_bit = true }, null);
        try self.vulkan.device.bindImageMemory(self.image.?, self.image_memory.?, 0);

        const image_view_create_info = vk.ImageViewCreateInfo{
            .image = self.image.?,
            .view_type = .@"2d",
            .format = .b8g8r8a8_unorm,
            .components = .{ .r = .r, .g = .g, .b = .b, .a = .a },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        self.image_view = try self.vulkan.device.createImageView(&image_view_create_info, null);
    }

    fn destroyImage(self: *Self) void {
        if (self.image) |image| self.vulkan.device.destroyImage(image, null);
        if (self.image_view) |image_view| self.vulkan.device.destroyImageView(image_view, null);
        if (self.image_memory) |image_memory| self.vulkan.device.freeMemory(image_memory, null);
    }

    // TODO: Start here - make sure image copy matches examples here: https://github.com/ocornut/imgui/wiki/Image-Loading-and-Displaying-Examples#example-for-vulkan-users
    pub fn copyVulkanImage(
        self: *Self,
        src_image: vk.Image,
        width: u32,
        height: u32,
        wait_semaphore: vk.Semaphore,
    ) !struct {
        semaphore: vk.Semaphore,
        fence: vk.Fence,
        image_view: vk.ImageView,
    } {
        // --- init ---
        if (self.command_buffer == null) {
            const command_buffer_alloc_info = vk.CommandBufferAllocateInfo{
                .command_pool = self.vulkan.command_pool,
                .level = .primary,
                .command_buffer_count = 1,
            };
            var command_buffers = [_]vk.CommandBuffer{undefined};
            try self.vulkan.device.allocateCommandBuffers(&command_buffer_alloc_info, &command_buffers);
            self.command_buffer = command_buffers[0];
        }

        if (self.fence == null) {
            self.fence = try self.vulkan.device.createFence(&.{}, null);
        }

        if (self.image == null) {
            try self.createImage(width, height);
        }

        try self.vulkan.device.resetFences(1, @ptrCast(&self.fence));

        const signal_semaphore = try self.vulkan.device.createSemaphore(&.{}, null);

        const command_buffer = self.command_buffer.?;
        try self.vulkan.device.beginCommandBuffer(command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

        // --- Pre-copy barriers (both source and dest in one call) ---
        const src_barrier = vk.ImageMemoryBarrier{
            .src_access_mask = .{ .color_attachment_write_bit = true }, // what last wrote src_image?
            .dst_access_mask = .{ .transfer_read_bit = true },
            .old_layout = .color_attachment_optimal, // change to whatever layout src_image actually is
            .new_layout = .transfer_src_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = src_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const dst_barrier_pre = vk.ImageMemoryBarrier{
            .src_access_mask = .{ .shader_read_bit = true }, // if it was previously shader-readable
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .undefined, // if the destination was already shader-readable
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image.?,
            .subresource_range = src_barrier.subresource_range,
        };

        // Combine both barriers in a single call. Use srcStages that reflect the *old* usage,
        // and dstStage = TRANSFER_BIT because both are transitioning into transfer usage.
        self.vulkan.device.cmdPipelineBarrier(
            command_buffer,
            // srcStageMask: something that represents the previous writers/readers for those images
            .{ .color_attachment_output_bit = true, .fragment_shader_bit = true },
            // dstStageMask
            .{ .transfer_bit = true },
            .{},
            0,
            null,
            0,
            null,
            2,
            @ptrCast(&[_]vk.ImageMemoryBarrier{ src_barrier, dst_barrier_pre }),
        );

        // --- Do the copy ---
        const copy_region = vk.ImageCopy{
            .src_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .src_offset = .{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
            .extent = .{ .width = width, .height = height, .depth = 1 },
        };
        self.vulkan.device.cmdCopyImage(
            command_buffer,
            src_image,
            .transfer_src_optimal,
            self.image.?,
            .transfer_dst_optimal,
            1,
            @ptrCast(&copy_region),
        );

        // --- Post-copy barrier: make dest shader-readable again ---
        const dst_barrier_post = vk.ImageMemoryBarrier{
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image.?,
            .subresource_range = src_barrier.subresource_range,
        };

        self.vulkan.device.cmdPipelineBarrier(
            command_buffer,
            .{ .transfer_bit = true },
            .{ .fragment_shader_bit = true },
            .{},
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&dst_barrier_post),
        );

        try self.vulkan.device.endCommandBuffer(command_buffer);

        const dst_stage_mask = vk.PipelineStageFlags{
            .all_commands_bit = true,
        };
        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .p_wait_dst_stage_mask = @ptrCast(&dst_stage_mask),
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&wait_semaphore),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&signal_semaphore),
        };
        self.vulkan.graphics_queue.mutex.lock();
        defer self.vulkan.graphics_queue.mutex.unlock();
        try self.vulkan.device.queueSubmit(self.vulkan.graphics_queue.handle, 1, @ptrCast(&submit_info), self.fence.?);

        return .{
            .semaphore = signal_semaphore,
            .fence = self.fence.?,
            .image_view = self.image_view.?,
        };
    }
};
