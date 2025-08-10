const std = @import("std");

const vk = @import("vulkan");

const Device = @import("./vulkan.zig").Device;
const Instance = @import("./vulkan.zig").Instance;
const Queue = @import("./vulkan.zig").Queue;
const Vulkan = @import("./vulkan.zig").Vulkan;

const IMAGE_COUNT = 2;

/// Render a moving triangle. This is only use
/// for testing purposes.
pub const TrianglePipeline = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    vulkan: *Vulkan,
    device: Device,
    graphics_queue: Queue,
    images: std.ArrayList(vk.Image) = undefined,
    image_views: std.ArrayList(vk.ImageView) = undefined,
    image_memory: std.ArrayList(vk.DeviceMemory),
    command_pool: vk.CommandPool,
    graphics_pipeline_layout: vk.PipelineLayout = undefined,
    graphics_pipeline: vk.Pipeline = undefined,
    command_buffers: std.ArrayList(vk.CommandBuffer),
    fence: vk.Fence = undefined,

    width: u32,
    height: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        vulkan: *Vulkan,
        device: Device,
        graphics_queue: Queue,
        command_pool: vk.CommandPool,
        width: u32,
        height: u32,
    ) !*Self {
        const self = try allocator.create(Self);

        self.* = .{
            .allocator = allocator,
            .vulkan = vulkan,
            .device = device,
            .graphics_queue = graphics_queue,
            .image_memory = std.ArrayList(vk.DeviceMemory).init(allocator),
            .command_buffers = std.ArrayList(vk.CommandBuffer).init(allocator),
            .command_pool = command_pool,
            .width = width,
            .height = height,
            .fence = try self.vulkan.device.createFence(&.{}, null),
        };

        try self.initImages();
        errdefer self.destroyImages();

        try self.initGraphicsPipeline();
        errdefer {
            device.destroyPipeline(self.graphics_pipeline, null);
            device.destroyPipelineLayout(self.graphics_pipeline_layout, null);
        }

        try self.createCommandBuffers();

        return self;
    }

    pub fn drawFrame(self: *Self, current_image_ix: u32, current_frame_number: u32) !void {
        try self.device.resetCommandBuffer(
            self.command_buffers.items[current_image_ix],
            .{},
        );
        try self.recordCommandBuffer(
            self.command_buffers.items[current_image_ix],
            current_image_ix,
            current_frame_number,
        );

        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&self.command_buffers.items[current_image_ix]),
        };

        try self.vulkan.device.resetFences(1, @ptrCast(&self.fence));

        self.graphics_queue.mutex.lock();
        defer self.graphics_queue.mutex.unlock();
        try self.device.queueSubmit(
            self.graphics_queue.handle,
            1,
            @ptrCast(&submit_info),
            self.fence,
        );
    }

    fn initImages(self: *Self) !void {
        self.images = std.ArrayList(vk.Image).init(self.allocator);

        // Create iamges
        for (0..IMAGE_COUNT) |_| {
            const image_create_info = vk.ImageCreateInfo{
                .image_type = .@"2d",
                .format = .r8g8b8a8_unorm,
                .extent = .{ .height = self.height, .width = self.width, .depth = 1 },
                .mip_levels = 1,
                .array_layers = 1,
                .samples = .{ .@"1_bit" = true },
                .tiling = .optimal,
                .usage = .{
                    .color_attachment_bit = true,
                    .storage_bit = true,
                    .transfer_src_bit = true,
                },
                .sharing_mode = .exclusive,
                .initial_layout = .undefined,
            };
            const image = try self.device.createImage(&image_create_info, null);
            try self.images.append(image);
            const memory_reqs = self.device.getImageMemoryRequirements(image);

            const memory = try self.vulkan.allocate(memory_reqs, .{}, null);
            try self.image_memory.append(memory);
            try self.device.bindImageMemory(image, memory, 0);
        }

        self.image_views = std.ArrayList(vk.ImageView).init(self.allocator);

        // Create image views
        for (0..IMAGE_COUNT) |i| {
            const view_info = vk.ImageViewCreateInfo{
                .image = self.images.items[i],
                .view_type = .@"2d",
                .format = .r8g8b8a8_unorm,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .components = .{
                    .r = .r,
                    .g = .g,
                    .b = .b,
                    .a = .a,
                },
            };
            const image_view = try self.device.createImageView(&view_info, null);
            try self.image_views.append(image_view);
        }
    }

    fn initGraphicsPipeline(self: *Self) !void {
        const vert_spv = @embedFile("random_vert_shader");
        const vert = try self.device.createShaderModule(&.{
            .code_size = vert_spv.len,
            .p_code = @alignCast(@ptrCast(vert_spv)),
        }, null);
        defer self.device.destroyShaderModule(vert, null);

        const frag_spv = @embedFile("random_frag_shader");
        const frag = try self.device.createShaderModule(&.{
            .code_size = frag_spv.len,
            .p_code = @alignCast(@ptrCast(frag_spv)),
        }, null);
        defer self.device.destroyShaderModule(frag, null);

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .stage = .{ .vertex_bit = true },
                .module = vert,
                .p_name = "main",
            },
            .{
                .stage = .{ .fragment_bit = true },
                .module = frag,
                .p_name = "main",
            },
        };

        const push_constant_range = [_]vk.PushConstantRange{.{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(u32),
        }};

        self.graphics_pipeline_layout = try self.device.createPipelineLayout(&.{
            .push_constant_range_count = push_constant_range.len,
            .p_push_constant_ranges = &push_constant_range,
        }, null);

        const vertext_input_info = vk.PipelineVertexInputStateCreateInfo{};
        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = .triangle_list,
            .primitive_restart_enable = vk.FALSE,
        };
        const viewport = [_]vk.Viewport{.{
            .x = 0,
            .y = 0,
            .height = @floatFromInt(self.height),
            .width = @floatFromInt(self.width),
            .min_depth = 0,
            .max_depth = 1,
        }};

        const scissor = [_]vk.Rect2D{.{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{
                .height = self.height,
                .width = self.width,
            },
        }};

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .p_viewports = &viewport,
            .scissor_count = 1,
            .p_scissors = &scissor,
        };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = vk.FALSE,
            .rasterizer_discard_enable = vk.FALSE,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = true },
            .front_face = .clockwise,
            .depth_bias_enable = vk.TRUE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        };

        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = vk.FALSE,
            .min_sample_shading = 1,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = vk.FALSE,
            .alpha_to_one_enable = vk.FALSE,
        };

        const color_blend_attachment = [_]vk.PipelineColorBlendAttachmentState{.{
            .blend_enable = vk.FALSE,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{
                .r_bit = true,
                .g_bit = true,
                .b_bit = true,
                .a_bit = true,
            },
        }};

        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = vk.FALSE,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = &color_blend_attachment,
            .blend_constants = .{ 0, 0, 0, 0 },
        };

        const color_attachment_format = [_]vk.Format{.r8g8b8a8_unorm};

        const rendering_create_info = vk.PipelineRenderingCreateInfo{
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachment_formats = &color_attachment_format,
            .depth_attachment_format = .undefined,
            .stencil_attachment_format = .undefined,
        };

        const pipeline_info = vk.GraphicsPipelineCreateInfo{
            .p_next = &rendering_create_info,
            .stage_count = 2,
            .p_stages = &shader_stages,
            .p_vertex_input_state = &vertext_input_info,
            .p_input_assembly_state = &input_assembly,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisampling,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &color_blending,
            .p_dynamic_state = null,
            .layout = self.graphics_pipeline_layout,
            .render_pass = .null_handle,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };

        _ = try self.device.createGraphicsPipelines(
            .null_handle,
            1,
            @ptrCast(&pipeline_info),
            null,
            @ptrCast(&self.graphics_pipeline),
        );
    }

    fn createCommandBuffers(self: *Self) !void {
        try self.command_buffers.resize(self.images.items.len);
        const alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = @intCast(self.command_buffers.items.len),
        };
        _ = try self.device.allocateCommandBuffers(&alloc_info, self.command_buffers.items.ptr);
    }

    fn recordCommandBuffer(
        self: *Self,
        command_buffer: vk.CommandBuffer,
        current_image_ix: u32,
        current_frame_number: u32,
    ) !void {
        try self.device.beginCommandBuffer(command_buffer, &.{});

        const image_memory_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .compute_shader_bit = true },
            .src_access_mask = .{ .shader_storage_read_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_access_mask = .{ .color_attachment_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .attachment_optimal,
            .image = self.images.items[current_image_ix],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = 0,
            .dst_queue_family_index = 0,
        };
        const dependency_info = vk.DependencyInfoKHR{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&image_memory_barrier),
        };

        self.device.cmdPipelineBarrier2(command_buffer, &dependency_info);

        const clear_value = vk.ClearValue{ .color = .{ .float_32 = [4]f32{
            0.0,
            0.0,
            0.0,
            0.0,
        } } };

        const color_attachment_info = vk.RenderingAttachmentInfo{
            .image_view = self.image_views.items[current_image_ix],
            .image_layout = .attachment_optimal,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = clear_value,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
        };

        const render_info = vk.RenderingInfo{
            .render_area = .{
                .extent = .{
                    .height = self.height,
                    .width = self.width,
                },
                .offset = .{
                    .x = 0,
                    .y = 0,
                },
            },
            .layer_count = 1,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment_info),
            .view_mask = 0,
        };

        self.device.cmdBeginRendering(command_buffer, &render_info);
        self.device.cmdBindPipeline(command_buffer, .graphics, self.graphics_pipeline);
        self.device.cmdPushConstants(
            command_buffer,
            self.graphics_pipeline_layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(u32),
            &current_frame_number,
        );
        self.device.cmdDraw(command_buffer, 3, 1, 0, 0);
        self.device.cmdEndRendering(command_buffer);
        try self.device.endCommandBuffer(command_buffer);
    }

    fn destroyImages(self: *const Self) void {
        for (self.images.items) |image| {
            self.device.destroyImage(image, null);
        }
        for (self.image_views.items) |image_view| {
            self.device.destroyImageView(image_view, null);
        }
        for (self.image_memory.items) |memory| {
            self.device.freeMemory(memory, null);
        }
    }

    pub fn deinit(self: *const Self) void {
        self.destroyImages();

        self.device.destroyFence(self.fence, null);
        self.device.destroyPipeline(self.graphics_pipeline, null);
        self.device.destroyPipelineLayout(self.graphics_pipeline_layout, null);

        self.images.deinit();
        self.image_views.deinit();
        self.image_memory.deinit();
        self.command_buffers.deinit();
        self.allocator.destroy(self);
    }
};
