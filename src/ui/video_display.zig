const std = @import("std");
const c = @import("imguiz").imguiz;
const vk = @import("vulkan");

const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;

pub const VideoDisplay = struct {
    const Self = @This();

    vulkan: *Vulkan,
    allocator: std.mem.Allocator,

    image: ?vk.Image = null,
    image_view: ?vk.ImageView = null,
    image_memory: ?vk.DeviceMemory = null,
    descriptor_set: c.VkDescriptorSet = null,

    command_buffer: ?vk.CommandBuffer = null,
    fence: ?vk.Fence = null,

    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator, vulkan: *Vulkan, width: u32, height: u32) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .vulkan = vulkan,
            .width = width,
            .height = height,
        };

        try self.createImage();

        const command_buffer_alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.vulkan.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        var command_buffers = [_]vk.CommandBuffer{undefined};
        try self.vulkan.device.allocateCommandBuffers(&command_buffer_alloc_info, &command_buffers);
        self.command_buffer = command_buffers[0];

        self.fence = try self.vulkan.device.createFence(&.{}, null);

        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = self.vulkan.device.waitForFences(1, @ptrCast(&self.fence), vk.TRUE, std.math.maxInt(u64)) catch unreachable;

        if (self.image) |image| self.vulkan.device.destroyImage(image, null);
        if (self.image_view) |image_view| self.vulkan.device.destroyImageView(image_view, null);
        if (self.image_memory) |image_memory| self.vulkan.device.freeMemory(image_memory, null);
        if (self.descriptor_set) |descriptor_set| c.cImGui_ImplVulkan_RemoveTexture(descriptor_set);
        if (self.command_buffer) |buffer| self.vulkan.device.freeCommandBuffers(self.vulkan.command_pool, 1, @ptrCast(&buffer));
        if (self.fence) |fence| self.vulkan.device.destroyFence(fence, null);

        self.allocator.destroy(self);
    }

    fn createImage(self: *Self) !void {
        const image_create_info = vk.ImageCreateInfo{
            .image_type = .@"2d",
            .format = .b8g8r8a8_unorm,
            .extent = .{ .width = self.width, .height = self.height, .depth = 1 },
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

    pub fn copyAndDraw(self: *Self, src_image: vk.Image) !void {
        try self.vulkan.device.resetFences(1, @ptrCast(&self.fence));

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
            .extent = .{ .width = self.width, .height = self.height, .depth = 1 },
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

        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
        };
        try self.vulkan.device.queueSubmit(self.vulkan.graphics_queue.handle, 1, @ptrCast(&submit_info), self.fence.?);
        const result = try self.vulkan.device.waitForFences(1, @ptrCast(&self.fence.?), vk.TRUE, std.math.maxInt(u64));
        if (result != .success) {
            return error.Spacecap_waitForFencesError;
        }

        if (self.descriptor_set == null) {
            const sampler = try self.vulkan.device.createSampler(&vk.SamplerCreateInfo{
                .mag_filter = .linear,
                .min_filter = .linear,
                .mipmap_mode = .linear,
                .address_mode_u = .repeat,
                .address_mode_v = .repeat,
                .address_mode_w = .repeat,
                .mip_lod_bias = 0.0,
                .anisotropy_enable = vk.FALSE,
                .max_anisotropy = 1.0,
                .compare_enable = vk.FALSE,
                .compare_op = .always,
                .min_lod = -1000,
                .max_lod = 1000,
                .border_color = .float_transparent_black,
                .unnormalized_coordinates = vk.FALSE,
            }, null);

            const s: c.VkSampler = @ptrFromInt(@intFromEnum(sampler));
            const i: c.VkImageView = @ptrFromInt(@intFromEnum(self.image_view.?));

            const sss = c.cImGui_ImplVulkan_AddTexture(s, i, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL).?;
            self.descriptor_set = sss;
        }

        const size = c.ImGui_GetContentRegionAvail();
        const im_texture_ref: *c.ImTextureRef = @alignCast(@ptrCast(self.descriptor_set.?));
        // TODO: may need to pass this thing in directly and not deref it
        c.ImGui_Image(im_texture_ref.*, size);
    }
};
