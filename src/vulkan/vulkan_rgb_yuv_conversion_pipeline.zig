const std = @import("std");
const assert = std.debug.assert;
const vk = @import("vulkan");

const Vulkan = @import("vulkan.zig").Vulkan;
const rgb_to_yuv_shader align(@alignOf(u32)) = @embedFile("bgr-to-ycbcr").*;
const yuv_to_rgb_shader align(@alignOf(u32)) = @embedFile("ycbcr-to-rgba").*;
comptime {
    assert(rgb_to_yuv_shader.len > 0);
    assert(yuv_to_rgb_shader.len > 0);
}

pub const VulkanRgbYuvConversionPipeline = struct {
    const Self = @This();

    pub const ConversionType = enum {
        rgb_to_yuv,
        yuv_to_rgb,
    };

    const PushConstants = extern struct {
        width: u32,
        height: u32,
    };

    vulkan: *Vulkan,
    conversion_type: ConversionType,
    descriptor_set_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    descriptor_set: vk.DescriptorSet,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,

    pub fn init(vulkan: *Vulkan, conversion_type: ConversionType) !Self {
        var bindings = std.mem.zeroes([3]vk.DescriptorSetLayoutBinding);
        for (&bindings, 0..) |*binding, index| {
            binding.* = .{
                .binding = @intCast(index),
                .descriptor_type = .storage_image,
                .descriptor_count = 1,
                .stage_flags = .{ .compute = true },
            };
        }

        const descriptor_set_layout = try vulkan.device.createDescriptorSetLayout(&.{
            .binding_count = bindings.len,
            .p_bindings = &bindings,
        }, null);
        errdefer vulkan.device.destroyDescriptorSetLayout(descriptor_set_layout, null);

        const descriptor_pool = try vulkan.device.createDescriptorPool(&.{
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = &.{.{
                .type = .storage_image,
                .descriptor_count = bindings.len,
            }},
        }, null);
        errdefer vulkan.device.destroyDescriptorPool(descriptor_pool, null);

        var descriptor_set: vk.DescriptorSet = undefined;
        try vulkan.device.allocateDescriptorSets(&.{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
        }, @ptrCast(&descriptor_set));

        const push_constant_range = vk.PushConstantRange{
            .stage_flags = .{ .compute = true },
            .offset = 0,
            .size = @sizeOf(PushConstants),
        };
        const pipeline_layout = try vulkan.device.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_constant_range),
        }, null);
        errdefer vulkan.device.destroyPipelineLayout(pipeline_layout, null);

        const shader: []align(@alignOf(u32)) const u8 = switch (conversion_type) {
            .rgb_to_yuv => &rgb_to_yuv_shader,
            .yuv_to_rgb => &yuv_to_rgb_shader,
        };

        const shader_module = try vulkan.device.createShaderModule(&.{
            .code_size = shader.len,
            .p_code = @ptrCast(shader.ptr),
        }, null);
        defer vulkan.device.destroyShaderModule(shader_module, null);

        var pipeline: vk.Pipeline = undefined;
        const result = try vulkan.device.createComputePipelines(.null_handle, &.{.{
            .stage = .{
                .stage = .{ .compute = true },
                .module = shader_module,
                .p_name = "main",
            },
            .layout = pipeline_layout,
            .base_pipeline_index = 0,
        }}, null, @ptrCast(&pipeline));
        if (result != .success) return error.CreateComputePipeline;
        errdefer vulkan.device.destroyPipeline(pipeline, null);

        return .{
            .vulkan = vulkan,
            .conversion_type = conversion_type,
            .descriptor_set_layout = descriptor_set_layout,
            .descriptor_pool = descriptor_pool,
            .descriptor_set = descriptor_set,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
        };
    }

    pub fn deinit(self: *Self) void {
        self.vulkan.device.destroyPipeline(self.pipeline, null);
        self.vulkan.device.destroyPipelineLayout(self.pipeline_layout, null);
        self.vulkan.device.destroyDescriptorPool(self.descriptor_pool, null);
        self.vulkan.device.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
    }

    pub fn record_commands(
        self: *Self,
        command_buffer: vk.CommandBuffer,
        rgb_view: vk.ImageView,
        y_view: vk.ImageView,
        uv_view: vk.ImageView,
        width: u32,
        height: u32,
    ) void {
        const image_views = switch (self.conversion_type) {
            .rgb_to_yuv => [3]vk.ImageView{ rgb_view, y_view, uv_view },
            .yuv_to_rgb => [3]vk.ImageView{ y_view, uv_view, rgb_view },
        };
        var image_infos: [3]vk.DescriptorImageInfo = undefined;
        var writes = std.mem.zeroes([3]vk.WriteDescriptorSet);
        for (&writes, 0..) |*write, index| {
            image_infos[index] = .{
                .sampler = .null_handle,
                .image_view = image_views[index],
                .image_layout = .general,
            };
            write.* = .{
                .dst_set = self.descriptor_set,
                .dst_binding = @intCast(index),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_image,
                .p_image_info = @ptrCast(&image_infos[index]),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };
        }
        self.vulkan.device.updateDescriptorSets(&writes, &.{});

        self.vulkan.device.cmdBindPipeline(command_buffer, .compute, self.pipeline);
        self.vulkan.device.cmdBindDescriptorSets(
            command_buffer,
            .compute,
            self.pipeline_layout,
            0,
            &.{self.descriptor_set},
            &.{},
        );
        const push_constants = PushConstants{ .width = width, .height = height };
        self.vulkan.device.cmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            .{ .compute = true },
            0,
            @sizeOf(PushConstants),
            @ptrCast(&push_constants),
        );
        self.vulkan.device.cmdDispatch(
            command_buffer,
            (width + 15) / 16,
            (height + 15) / 16,
            1,
        );
    }

    pub fn create_yuv_plane_views(vulkan: *Vulkan, image: vk.Image) ![2]vk.ImageView {
        const view_usage = vk.ImageViewUsageCreateInfo{ .usage = .{ .storage = true } };
        var create_info = vk.ImageViewCreateInfo{
            .p_next = &view_usage,
            .image = image,
            .view_type = .@"2d",
            .format = .r8_unorm,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .plane_0 = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const y_view = try vulkan.device.createImageView(&create_info, null);
        errdefer vulkan.device.destroyImageView(y_view, null);

        create_info.format = .r8g8_unorm;
        create_info.subresource_range.aspect_mask = .{ .plane_1 = true };
        const uv_view = try vulkan.device.createImageView(&create_info, null);
        return .{ y_view, uv_view };
    }
};
