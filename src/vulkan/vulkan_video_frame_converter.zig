const std = @import("std");
const c = @import("ffmpeg_c");
const vk = @import("vulkan");
const check_err = @import("../ffmpeg/util.zig").check_err;

const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const VulkanImageBuffer = @import("../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;
const VulkanRgbYuvConversionPipeline = @import("../vulkan/vulkan_rgb_yuv_conversion_pipeline.zig").VulkanRgbYuvConversionPipeline;

/// Converts a decoded FFmpeg video frame to a RGB Vulkan image, which is
/// stored on the GPU.
pub const VulkanVideoFrameConverter = struct {
    const Self = @This();

    vulkan: *Vulkan,
    width: u32,
    height: u32,

    software_image: vk.Image,
    software_memory: vk.DeviceMemory,
    software_views: [2]vk.ImageView,
    software_image_initialized: bool = false,
    staging_buffer: vk.Buffer,
    staging_memory: vk.DeviceMemory,
    staging_frame: [*c]c.AVFrame,
    scale_context: [*c]c.SwsContext,

    rgb_yuv_conversion_pipeline: VulkanRgbYuvConversionPipeline,

    pub fn init(
        vulkan: *Vulkan,
        width: u32,
        height: u32,
    ) !Self {
        const staging_size_result = c.av_image_get_buffer_size(
            c.AV_PIX_FMT_NV12,
            @intCast(width),
            @intCast(height),
            4,
        );
        try check_err(staging_size_result);
        const staging_size: u64 = @intCast(staging_size_result);
        const staging_buffer = try vulkan.device.createBuffer(&.{
            .size = staging_size,
            .usage = .{ .transfer_src = true },
            .sharing_mode = .exclusive,
        }, null);
        errdefer vulkan.device.destroyBuffer(staging_buffer, null);

        const staging_memory = try vulkan.allocate(
            vulkan.device.getBufferMemoryRequirements(staging_buffer),
            .{ .host_visible = true, .host_coherent = true },
            null,
        );
        errdefer vulkan.device.freeMemory(staging_memory, null);
        try vulkan.device.bindBufferMemory(staging_buffer, staging_memory, 0);
        const mapped_staging: [*]u8 = @ptrCast(try vulkan.device.mapMemory(staging_memory, 0, staging_size, .{}));
        errdefer vulkan.device.unmapMemory(staging_memory);

        var staging_frame = c.av_frame_alloc() orelse return error.FFmpegError;
        errdefer c.av_frame_free(&staging_frame);
        staging_frame.*.format = c.AV_PIX_FMT_NV12;
        staging_frame.*.width = @intCast(width);
        staging_frame.*.height = @intCast(height);
        try check_err(c.av_image_fill_arrays(
            &staging_frame.*.data,
            &staging_frame.*.linesize,
            mapped_staging,
            c.AV_PIX_FMT_NV12,
            @intCast(width),
            @intCast(height),
            4,
        ));

        var scale_context = c.sws_alloc_context() orelse return error.FFmpegError;
        errdefer c.sws_free_context(&scale_context);

        const software_image = try vulkan.device.createImage(&.{
            .flags = .{ .mutable_format = true, .extended_usage = true },
            .image_type = .@"2d",
            .format = .g8_b8r8_2plane_420_unorm,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1" = true },
            .tiling = .optimal,
            .usage = .{ .storage = true, .transfer_dst = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        errdefer vulkan.device.destroyImage(software_image, null);

        const software_memory = try vulkan.allocate(
            vulkan.device.getImageMemoryRequirements(software_image),
            .{ .device_local = true },
            null,
        );
        errdefer vulkan.device.freeMemory(software_memory, null);
        try vulkan.device.bindImageMemory(software_image, software_memory, 0);

        const software_views = try VulkanRgbYuvConversionPipeline.create_yuv_plane_views(vulkan, software_image);
        errdefer {
            vulkan.device.destroyImageView(software_views[1], null);
            vulkan.device.destroyImageView(software_views[0], null);
        }

        var rgb_yuv_conversion_pipeline = try VulkanRgbYuvConversionPipeline.init(vulkan, .yuv_to_rgb);
        errdefer rgb_yuv_conversion_pipeline.deinit();

        return .{
            .vulkan = vulkan,
            .width = width,
            .height = height,
            .software_image = software_image,
            .software_memory = software_memory,
            .software_views = software_views,
            .staging_buffer = staging_buffer,
            .staging_memory = staging_memory,
            .staging_frame = staging_frame,
            .scale_context = scale_context,
            .rgb_yuv_conversion_pipeline = rgb_yuv_conversion_pipeline,
        };
    }

    pub fn deinit(self: *Self) void {
        self.rgb_yuv_conversion_pipeline.deinit();
        c.sws_free_context(&self.scale_context);
        c.av_frame_free(&self.staging_frame);

        self.vulkan.device.destroyImageView(self.software_views[1], null);
        self.vulkan.device.destroyImageView(self.software_views[0], null);
        self.vulkan.device.destroyImage(self.software_image, null);
        self.vulkan.device.freeMemory(self.software_memory, null);

        self.vulkan.device.unmapMemory(self.staging_memory);
        self.vulkan.device.destroyBuffer(self.staging_buffer, null);
        self.vulkan.device.freeMemory(self.staging_memory, null);
    }

    /// Convert a YUV AVFrame to an RGB Vulkan image.
    pub fn convert(self: *Self, frame: *const c.AVFrame, output: *VulkanImageBuffer) !void {
        const wait_result = try self.vulkan.device.waitForFences(&.{output.fence}, .true, std.math.maxInt(u64));
        if (wait_result != .success) return error.WaitForFences;

        if (frame.*.format == c.AV_PIX_FMT_VULKAN) {
            try self.convert_vulkan_frame(frame, output);
        } else {
            try self.convert_software_frame(frame, output);
        }
    }

    fn convert_vulkan_frame(self: *Self, frame: *const c.AVFrame, output: *VulkanImageBuffer) !void {
        if (frame.*.data[0] == null or frame.*.hw_frames_ctx == null) return error.InvalidVideoFrame;

        const frames_context: *c.AVHWFramesContext = @ptrCast(@alignCast(frame.*.hw_frames_ctx.*.data));
        const vulkan_frames: *c.AVVulkanFramesContext = @ptrCast(@alignCast(frames_context.hwctx orelse return error.InvalidVideoFrame));
        if (vulkan_frames.format[0] != c.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM) {
            return error.UnsupportedVideoFormat;
        }

        const vulkan_frame: *c.AVVkFrame = @ptrCast(@alignCast(frame.*.data[0]));
        const lock_frame = vulkan_frames.lock_frame orelse return error.InvalidVideoFrame;
        const unlock_frame = vulkan_frames.unlock_frame orelse return error.InvalidVideoFrame;
        lock_frame(frames_context, vulkan_frame);
        defer unlock_frame(frames_context, vulkan_frame);

        if (vulkan_frame.img[0] == null or vulkan_frame.sem[0] == null) return error.InvalidVideoFrame;
        if (vulkan_frame.queue_family[0] != vk.QUEUE_FAMILY_IGNORED and
            vulkan_frame.queue_family[0] != self.vulkan.graphics_queue.family)
        {
            return error.UnsupportedQueueFamily;
        }

        const image: vk.Image = @fromBackingInt(@intCast(@intFromPtr(vulkan_frame.img[0].?)));
        const views = try VulkanRgbYuvConversionPipeline.create_yuv_plane_views(self.vulkan, image);
        defer {
            self.vulkan.device.destroyImageView(views[1], null);
            self.vulkan.device.destroyImageView(views[0], null);
        }

        try self.record_commands(.{
            .output = output,
            .input_image = image,
            .input_views = views,
            .input_layout = @fromBackingInt(@intCast(vulkan_frame.layout[0])),
            .input_access = @bitCast(vulkan_frame.access[0]),
        });

        const semaphore: vk.Semaphore = @fromBackingInt(@intCast(@intFromPtr(vulkan_frame.sem[0].?)));
        const wait_value = vulkan_frame.sem_value[0];
        const signal_value = wait_value + 1;
        const timeline_info = vk.TimelineSemaphoreSubmitInfo{
            .wait_semaphore_value_count = 1,
            .p_wait_semaphore_values = @ptrCast(&wait_value),
            .signal_semaphore_value_count = 1,
            .p_signal_semaphore_values = @ptrCast(&signal_value),
        };
        const wait_stage = vk.PipelineStageFlags{ .all_commands = true };
        try self.vulkan.queue_submit(.graphics, &.{.{
            .p_next = &timeline_info,
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&semaphore),
            .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&output.command_buffer),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&semaphore),
        }}, .{ .fence = output.fence });

        vulkan_frame.layout[0] = @backingInt(vk.ImageLayout.general);
        vulkan_frame.access[0] = @bitCast(vk.AccessFlags2{ .shader_storage_read = true });
        vulkan_frame.sem_value[0] = signal_value;

        const result = try self.vulkan.device.waitForFences(&.{output.fence}, .true, std.math.maxInt(u64));
        if (result != .success) return error.WaitForFences;
    }

    fn convert_software_frame(self: *Self, frame: *const c.AVFrame, output: *VulkanImageBuffer) !void {
        try check_err(c.sws_scale_frame(self.scale_context, self.staging_frame, frame));
        try self.record_commands(.{
            .output = output,
            .input_image = self.software_image,
            .input_views = self.software_views,
            .input_layout = if (self.software_image_initialized) .general else .undefined,
            .input_access = if (self.software_image_initialized)
                .{ .shader_storage_read = true }
            else
                .{},
            .upload_software_frame = true,
        });

        try self.vulkan.queue_submit(.graphics, &.{.{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&output.command_buffer),
        }}, .{ .fence = output.fence });

        const result = try self.vulkan.device.waitForFences(&.{output.fence}, .true, std.math.maxInt(u64));
        if (result != .success) return error.WaitForFences;
        self.software_image_initialized = true;
    }

    fn record_commands(self: *Self, args: struct {
        output: *VulkanImageBuffer,
        input_image: vk.Image,
        input_views: [2]vk.ImageView,
        input_layout: vk.ImageLayout,
        input_access: vk.AccessFlags2,
        upload_software_frame: bool = false,
    }) !void {
        try self.vulkan.device.resetCommandPool(args.output.command_pool, .{});
        try self.vulkan.device.beginCommandBuffer(args.output.command_buffer, &.{
            .flags = .{ .one_time_submit = true },
        });

        const input_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .plane_0 = true, .plane_1 = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        const output_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };

        if (args.upload_software_frame) {
            const before_copy = vk.ImageMemoryBarrier2{
                .src_stage_mask = if (self.software_image_initialized) .{ .compute_shader = true } else .{},
                .src_access_mask = args.input_access,
                .dst_stage_mask = .{ .all_transfer = true },
                .dst_access_mask = .{ .transfer_write = true },
                .old_layout = args.input_layout,
                .new_layout = .transfer_dst_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = args.input_image,
                .subresource_range = input_range,
            };
            self.vulkan.device.cmdPipelineBarrier2(args.output.command_buffer, &.{
                .image_memory_barrier_count = 1,
                .p_image_memory_barriers = @ptrCast(&before_copy),
            });

            const chroma_width = (self.width + 1) / 2;
            const chroma_height = (self.height + 1) / 2;
            const copy_regions = [_]vk.BufferImageCopy{
                .{
                    .buffer_offset = 0,
                    .buffer_row_length = @intCast(self.staging_frame.*.linesize[0]),
                    .buffer_image_height = 0,
                    .image_subresource = .{
                        .aspect_mask = .{ .plane_0 = true },
                        .mip_level = 0,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                    .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                    .image_extent = .{ .width = self.width, .height = self.height, .depth = 1 },
                },
                .{
                    .buffer_offset = @intCast(@intFromPtr(self.staging_frame.*.data[1]) - @intFromPtr(self.staging_frame.*.data[0])),
                    .buffer_row_length = @intCast(@divExact(self.staging_frame.*.linesize[1], 2)),
                    .buffer_image_height = 0,
                    .image_subresource = .{
                        .aspect_mask = .{ .plane_1 = true },
                        .mip_level = 0,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                    .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                    .image_extent = .{ .width = chroma_width, .height = chroma_height, .depth = 1 },
                },
            };
            self.vulkan.device.cmdCopyBufferToImage(
                args.output.command_buffer,
                self.staging_buffer,
                args.input_image,
                .transfer_dst_optimal,
                &copy_regions,
            );
        }

        const input_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = if (args.upload_software_frame) .{ .all_transfer = true } else .{ .all_commands = true },
            .src_access_mask = if (args.upload_software_frame) .{ .transfer_write = true } else args.input_access,
            .dst_stage_mask = .{ .compute_shader = true },
            .dst_access_mask = .{ .shader_storage_read = true },
            .old_layout = if (args.upload_software_frame) .transfer_dst_optimal else args.input_layout,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = args.input_image,
            .subresource_range = input_range,
        };
        const output_barrier = vk.ImageMemoryBarrier2{
            .dst_stage_mask = .{ .compute_shader = true },
            .dst_access_mask = .{ .shader_storage_write = true },
            .old_layout = .undefined,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = args.output.image,
            .subresource_range = output_range,
        };
        const before_compute = [_]vk.ImageMemoryBarrier2{ input_barrier, output_barrier };
        self.vulkan.device.cmdPipelineBarrier2(args.output.command_buffer, &.{
            .image_memory_barrier_count = before_compute.len,
            .p_image_memory_barriers = &before_compute,
        });

        self.rgb_yuv_conversion_pipeline.record_commands(
            args.output.command_buffer,
            args.output.image_view,
            args.input_views[0],
            args.input_views[1],
            self.width,
            self.height,
        );

        const after_compute = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .compute_shader = true },
            .src_access_mask = .{ .shader_storage_write = true },
            .dst_stage_mask = .{ .fragment_shader = true },
            .dst_access_mask = .{ .shader_sampled_read = true },
            .old_layout = .general,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = args.output.image,
            .subresource_range = output_range,
        };
        self.vulkan.device.cmdPipelineBarrier2(args.output.command_buffer, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&after_compute),
        });

        try self.vulkan.device.endCommandBuffer(args.output.command_buffer);
    }
};
