const std = @import("std");
const vk = @import("vulkan");
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const imguiz = @import("imguiz").imguiz;
const util = @import("../util.zig");

pub const CapturePreviewBuffer = struct {
    const Self = @This();

    vulkan: *Vulkan,
    image: vk.Image,
    image_view: vk.ImageView,
    image_memory: vk.DeviceMemory,
    command_buffer: vk.CommandBuffer,
    command_pool: vk.CommandPool,
    signal_semaphore: vk.Semaphore,
    fence: vk.Fence,
    sampler: vk.Sampler,
    descriptor_set: imguiz.VkDescriptorSet,
    im_texture_ref: imguiz.ImTextureRef,
    width: u32,
    height: u32,
    mutex: std.Thread.Mutex = .{},

    pub fn init(vulkan: *Vulkan, width: u32, height: u32) !Self {
        const image_create_info = vk.ImageCreateInfo{
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{
                .transfer_dst_bit = true,
                .sampled_bit = true,
                .color_attachment_bit = true,
            },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        };

        const image = try vulkan.device.createImage(&image_create_info, null);
        const mem_req = vulkan.device.getImageMemoryRequirements(image);
        const image_memory = try vulkan.allocate(mem_req, .{ .device_local_bit = true }, null);
        try vulkan.device.bindImageMemory(image, image_memory, 0);

        const image_view_create_info = vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            // TODO: need to check source format and swizzle values based on that
            .components = .{
                .r = .b,
                .g = .identity,
                .b = .r,
                .a = .one,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const image_view = try vulkan.device.createImageView(&image_view_create_info, null);
        const sampler = try vulkan.device.createSampler(&vk.SamplerCreateInfo{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0.0,
            .anisotropy_enable = vk.FALSE,
            .max_anisotropy = 1.0,
            .compare_enable = vk.FALSE,
            .compare_op = .always,
            .min_lod = 0.0,
            .max_lod = 0.0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = vk.FALSE,
        }, null);

        const s: imguiz.VkSampler = @ptrFromInt(@intFromEnum(sampler));
        const i: imguiz.VkImageView = @ptrFromInt(@intFromEnum(image_view));
        // TODO: need to move this to the UI thread?
        const descriptor_set = imguiz.cImGui_ImplVulkan_AddTexture(s, i, imguiz.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL).?;
        const im_texture_ref = imguiz.ImTextureRef{
            ._TexID = @intFromPtr(descriptor_set),
        };

        const command_pool = try vulkan.device.createCommandPool(&.{
            .queue_family_index = vulkan.graphics_queue.family,
            .flags = .{ .reset_command_buffer_bit = true },
        }, null);

        const cmd_alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };

        var command_buffer: vk.CommandBuffer = undefined;
        try vulkan.device.allocateCommandBuffers(&cmd_alloc_info, @ptrCast(&command_buffer));
        const signal_semaphore = try vulkan.device.createSemaphore(&.{}, null);
        const fence = try vulkan.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);

        return .{
            .vulkan = vulkan,
            .image = image,
            .image_view = image_view,
            .image_memory = image_memory,
            .command_buffer = command_buffer,
            .command_pool = command_pool,
            .signal_semaphore = signal_semaphore,
            .fence = fence,
            .sampler = sampler,
            .descriptor_set = descriptor_set,
            .im_texture_ref = im_texture_ref,
            .width = width,
            .height = height,
        };
    }

    pub fn copyImage(
        self: *Self,
        src_image: vk.Image,
        wait_semaphore: vk.Semaphore,
    ) !vk.Semaphore {
        const result = try self.vulkan.device.waitForFences(1, @ptrCast(&self.fence), vk.TRUE, std.math.maxInt(u64));
        if (result != .success) {
            return error.waitForFences;
        }

        try self.vulkan.device.beginCommandBuffer(self.command_buffer, &.{});

        const src_barrier = vk.ImageMemoryBarrier2{
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .dst_access_mask = .{ .transfer_read_bit = true },
            .old_layout = .color_attachment_optimal,
            .new_layout = .transfer_src_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_EXTERNAL,
            .dst_queue_family_index = self.vulkan.graphics_queue.family,
            .image = src_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const initial_dep_info = vk.DependencyInfoKHR{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&src_barrier),
        };
        self.vulkan.device.cmdPipelineBarrier2(self.command_buffer, &initial_dep_info);

        const dst_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{},
            .src_access_mask = .{},
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const dst_dep_info = vk.DependencyInfoKHR{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&dst_barrier),
        };

        self.vulkan.device.cmdPipelineBarrier2(self.command_buffer, &dst_dep_info);

        const copy_region = vk.ImageCopy{
            .src_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .src_offset = .{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
            .extent = .{ .width = self.width, .height = self.height, .depth = 1 },
        };

        self.vulkan.device.cmdCopyImage(
            self.command_buffer,
            src_image,
            .transfer_src_optimal,
            self.image,
            .transfer_dst_optimal,
            1,
            @ptrCast(&copy_region),
        );

        const shader_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .fragment_shader_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const shader_dep_info = vk.DependencyInfoKHR{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&shader_barrier),
        };

        self.vulkan.device.cmdPipelineBarrier2(self.command_buffer, &shader_dep_info);

        try self.vulkan.device.endCommandBuffer(self.command_buffer);

        const dst_stage_mask = vk.PipelineStageFlags{
            .transfer_bit = true,
        };
        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&self.command_buffer),
            .p_wait_dst_stage_mask = @ptrCast(&dst_stage_mask),
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&wait_semaphore),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&self.signal_semaphore),
        };

        try self.vulkan.queueSubmit(.graphics, &.{submit_info}, .{ .fence = self.fence });

        return self.signal_semaphore;
    }

    pub fn deinit(self: *Self) void {
        _ = self.vulkan.device.waitForFences(1, @ptrCast(&self.fence), vk.TRUE, std.math.maxInt(u64)) catch unreachable;
        imguiz.cImGui_ImplVulkan_RemoveTexture(self.descriptor_set);
        self.vulkan.device.destroyImage(self.image, null);
        self.vulkan.device.destroyImageView(self.image_view, null);
        self.vulkan.device.freeMemory(self.image_memory, null);
        self.vulkan.device.destroySampler(self.sampler, null);
        self.vulkan.device.freeCommandBuffers(self.command_pool, 1, @ptrCast(&self.command_buffer));
        self.vulkan.device.destroyCommandPool(self.command_pool, null);
        self.vulkan.device.destroyFence(self.fence, null);
        self.vulkan.device.destroySemaphore(self.signal_semaphore, null);
    }
};

pub const CapturePreviewSwapchain = struct {
    const Self = @This();
    buffers: [3]CapturePreviewBuffer,
    vulkan: *Vulkan,
    most_recent_index: ?u32 = null,
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, vulkan: *Vulkan, width: u32, height: u32) !*Self {
        const self = try allocator.create(Self);

        self.* = .{
            .allocator = allocator,
            .buffers = .{
                try CapturePreviewBuffer.init(vulkan, width, height),
                try CapturePreviewBuffer.init(vulkan, width, height),
                try CapturePreviewBuffer.init(vulkan, width, height),
            },
            .vulkan = vulkan,
        };
        return self;
    }

    /// Find a buffer that currently isn't locked, lock it,
    /// then copy the source image into the buffer. Will return
    /// a new semaphore, but if a buffer is not available, the
    /// wait semaphore provided will be returned.
    pub fn copyImageToSwapChain(
        self: *Self,
        src_image: vk.Image,
        wait_semaphore: vk.Semaphore,
    ) !vk.Semaphore {
        // Probably won't ever fill the 3rd buffer given how
        // current synchronization is.
        for (0..3) |i| {
            // most_recent_index will only be null after the swapchain has been initialized.
            if (self.most_recent_index != null and i == @as(usize, @intCast(self.most_recent_index.?))) {
                continue;
            }
            var buffer = self.buffers[i];
            const did_lock = buffer.mutex.tryLock();

            if (did_lock) {
                defer buffer.mutex.unlock();
                self.most_recent_index = @intCast(i);
                return buffer.copyImage(src_image, wait_semaphore);
            }
        }
        return wait_semaphore;
    }

    pub fn getMostRecentBuffer(self: *Self) ?*CapturePreviewBuffer {
        if (self.most_recent_index) |most_recent_index| {
            const buffer = &self.buffers[most_recent_index];
            buffer.mutex.lock();
            return buffer;
        }

        return null;
    }

    pub fn deinit(self: *Self) void {
        for (&self.buffers) |*buffer| {
            buffer.deinit();
        }
        self.allocator.destroy(self);
    }
};
