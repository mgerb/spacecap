const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const c = @import("ffmpeg_c");
const check_err = @import("./util.zig").check_err;
const vulkan_module = @import("../vulkan/vulkan.zig");
const Vulkan = vulkan_module.Vulkan;
const VIDEO_DECODE_H264_EXTENSIONS = vulkan_module.VIDEO_DECODE_H264_EXTENSIONS;
const VIDEO_DECODE_H265_EXTENSIONS = vulkan_module.VIDEO_DECODE_H265_EXTENSIONS;

// Force the software decoder for unit tests.
const USE_SOFTWARE = builtin.is_test;

pub const VideoDecoder = struct {
    const Self = @This();
    const log = std.log.scoped(.video_decoder);

    const Mode = enum { vulkan, software };

    codec_context: [*c]c.AVCodecContext,
    hw_device_ctx: [*c]c.AVBufferRef,
    frame: [*c]c.AVFrame,
    flushing: bool = false,

    pub fn init(
        vulkan: *Vulkan,
        codec_parameters: *const c.AVCodecParameters,
    ) !Self {
        const mode: Mode = if (can_use_vulkan_decode(vulkan, codec_parameters)) .vulkan else .software;
        if (mode == .software) {
            log.info("[init] Vulkan decoding is unavailable - using software decoding", .{});
        }

        const codec = c.avcodec_find_decoder(codec_parameters.*.codec_id) orelse return error.FFmpegError;

        var codec_context = c.avcodec_alloc_context3(codec) orelse return error.FFmpegError;
        errdefer c.avcodec_free_context(&codec_context);
        try check_err(c.avcodec_parameters_to_context(codec_context, codec_parameters));

        var hw_device_ctx: [*c]c.AVBufferRef = null;
        errdefer c.av_buffer_unref(&hw_device_ctx);

        if (mode == .vulkan) {
            hw_device_ctx = try create_vulkan_hw_device(vulkan, codec_parameters.*.codec_id);
            codec_context.*.hw_device_ctx = c.av_buffer_ref(hw_device_ctx);
            if (codec_context.*.hw_device_ctx == null) return error.FFmpegError;
            codec_context.*.get_format = get_vulkan_format;
        }

        try check_err(c.avcodec_open2(codec_context, codec, null));

        var frame = c.av_frame_alloc() orelse return error.FFmpegError;
        errdefer c.av_frame_free(&frame);

        return .{
            .codec_context = codec_context,
            .hw_device_ctx = hw_device_ctx,
            .frame = frame,
        };
    }

    pub fn deinit(self: *Self) void {
        c.av_frame_free(&self.frame);
        c.avcodec_free_context(&self.codec_context);
        c.av_buffer_unref(&self.hw_device_ctx);
    }

    /// Returns a decoder owned frame that remains valid until the next call to
    /// `decode_frame` or `deinit`. Returns `error.NeedsPacket` when more input
    /// is needed and null at the end of the stream.
    pub fn decode_frame(self: *Self) !?*const c.AVFrame {
        const receive_ret = c.avcodec_receive_frame(self.codec_context, self.frame);

        if (receive_ret >= 0) {
            return self.frame;
        }

        if (receive_ret == c.AVERROR_EOF or (receive_ret == c.AVERROR(c.EAGAIN) and self.flushing)) {
            return null;
        }

        if (receive_ret == c.AVERROR(c.EAGAIN)) {
            return error.NeedsPacket;
        }

        try check_err(receive_ret);

        @panic("[decode_frame] unexpected FFmpeg success result");
    }

    /// Sending a null packet puts the decoder in a `flushing` state, which means
    /// it will not accept any more packets until flushed.
    pub fn send_packet(self: *Self, packet: [*c]const c.AVPacket) !void {
        try check_err(c.avcodec_send_packet(self.codec_context, packet));
        if (packet == null) {
            self.flushing = true;
        }
    }

    pub fn flush(self: *Self) void {
        c.avcodec_flush_buffers(self.codec_context);
        c.av_frame_unref(self.frame);
        self.flushing = false;
    }

    fn can_use_vulkan_decode(vulkan: *const Vulkan, codec_parameters: *const c.AVCodecParameters) bool {
        if (USE_SOFTWARE or vulkan_decode_queue_family(vulkan, codec_parameters.*.codec_id) == null) {
            return false;
        }

        const decoder = c.avcodec_find_decoder(codec_parameters.*.codec_id);

        if (decoder == null) {
            return false;
        }

        var i: i32 = 0;
        while (true) : (i += 1) {
            const hw_config = c.avcodec_get_hw_config(decoder, i);

            if (hw_config == null) {
                return false;
            }

            const supports_device_context = (hw_config.*.methods & c.AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0;

            if (supports_device_context and
                hw_config.*.device_type == c.AV_HWDEVICE_TYPE_VULKAN and
                hw_config.*.pix_fmt == c.AV_PIX_FMT_VULKAN)
            {
                return true;
            }
        }
    }

    fn create_vulkan_hw_device(vulkan: *Vulkan, codec_id: c.AVCodecID) ![*c]c.AVBufferRef {
        const video_decode_queue_family = vulkan_decode_queue_family(vulkan, codec_id) orelse return error.VideoNotSupported;

        const enabled_device_extensions = switch (codec_id) {
            c.AV_CODEC_ID_H264 => &VIDEO_DECODE_H264_EXTENSIONS,
            c.AV_CODEC_ID_HEVC => &VIDEO_DECODE_H265_EXTENSIONS,
            else => return error.VideoNotSupported,
        };
        const video_caps: c_uint = switch (codec_id) {
            c.AV_CODEC_ID_H264 => c.VK_VIDEO_CODEC_OPERATION_DECODE_H264_BIT_KHR,
            c.AV_CODEC_ID_HEVC => c.VK_VIDEO_CODEC_OPERATION_DECODE_H265_BIT_KHR,
            else => return error.VideoNotSupported,
        };

        var hw_device_ctx = c.av_hwdevice_ctx_alloc(c.AV_HWDEVICE_TYPE_VULKAN);
        if (hw_device_ctx == null) return error.FFmpegError;
        errdefer c.av_buffer_unref(&hw_device_ctx);

        const device_context: *c.AVHWDeviceContext = @ptrCast(@alignCast(hw_device_ctx.*.data));
        const vulkan_device_context: *c.AVVulkanDeviceContext = @ptrCast(@alignCast(device_context.hwctx));

        device_context.*.user_opaque = vulkan;
        vulkan_device_context.*.get_proc_addr = @ptrCast(&Vulkan.vkGetInstanceProcAddr);
        vulkan_device_context.*.inst = @ptrFromInt(@backingInt(vulkan.instance.handle));
        vulkan_device_context.*.phys_dev = @ptrFromInt(@backingInt(vulkan.physical_device));
        vulkan_device_context.*.act_dev = @ptrFromInt(@backingInt(vulkan.device.handle));
        vulkan_device_context.*.enabled_dev_extensions = enabled_device_extensions;
        vulkan_device_context.*.nb_enabled_dev_extensions = enabled_device_extensions.len;
        vulkan_device_context.*.lock_queue = lock_vulkan_queue;
        vulkan_device_context.*.unlock_queue = unlock_vulkan_queue;

        try add_ffmpeg_queue_family(
            vulkan_device_context,
            vulkan.graphics_queue.family,
            c.VK_QUEUE_GRAPHICS_BIT | c.VK_QUEUE_COMPUTE_BIT | c.VK_QUEUE_TRANSFER_BIT,
            c.VK_VIDEO_CODEC_OPERATION_NONE_KHR,
        );

        try add_ffmpeg_queue_family(
            vulkan_device_context,
            video_decode_queue_family,
            c.VK_QUEUE_VIDEO_DECODE_BIT_KHR,
            video_caps,
        );

        try check_err(c.av_hwdevice_ctx_init(hw_device_ctx));

        return hw_device_ctx;
    }

    fn vulkan_decode_queue_family(vulkan: *const Vulkan, codec_id: c.AVCodecID) ?u32 {
        return switch (codec_id) {
            c.AV_CODEC_ID_H264 => if (vulkan.video_decode_h264_queue) |*queue| queue.family else null,
            c.AV_CODEC_ID_HEVC => if (vulkan.video_decode_h265_queue) |*queue| queue.family else null,
            else => null,
        };
    }

    fn lock_vulkan_queue(
        device_context: [*c]c.AVHWDeviceContext,
        queue_family: u32,
        queue_index: u32,
    ) callconv(.c) void {
        _ = queue_index;
        const vulkan: *Vulkan = @ptrCast(@alignCast(device_context.*.user_opaque.?));
        vulkan.lock_queue_family(queue_family);
    }

    fn unlock_vulkan_queue(
        device_context: [*c]c.AVHWDeviceContext,
        queue_family: u32,
        queue_index: u32,
    ) callconv(.c) void {
        _ = queue_index;
        const vulkan: *Vulkan = @ptrCast(@alignCast(device_context.*.user_opaque.?));
        vulkan.unlock_queue_family(queue_family);
    }

    fn add_ffmpeg_queue_family(
        vulkan_device_context: *c.AVVulkanDeviceContext,
        family: u32,
        flags: c_uint,
        video_caps: c_uint,
    ) !void {
        for (0..@intCast(vulkan_device_context.*.nb_qf)) |index| {
            if (vulkan_device_context.*.qf[index].idx == family) {
                vulkan_device_context.*.qf[index].flags |= flags;
                vulkan_device_context.*.qf[index].video_caps |= video_caps;
                return;
            }
        }

        const index: usize = @intCast(vulkan_device_context.*.nb_qf);
        if (index >= vulkan_device_context.*.qf.len) return error.TooManyQueueFamilies;

        vulkan_device_context.*.qf[index] = .{
            .idx = @intCast(family),
            .num = 1,
            .flags = flags,
            .video_caps = video_caps,
        };
        vulkan_device_context.*.nb_qf += 1;
    }

    fn get_vulkan_format(codec_context: [*c]c.AVCodecContext, formats: [*c]const c_int) callconv(.c) c_int {
        var index: usize = 0;
        while (formats[index] != c.AV_PIX_FMT_NONE) : (index += 1) {
            if (formats[index] == c.AV_PIX_FMT_VULKAN) break;
        }

        if (formats[index] == c.AV_PIX_FMT_NONE) {
            return c.AV_PIX_FMT_NONE;
        }

        var frames_ref: [*c]c.AVBufferRef = null;
        const params_result = c.avcodec_get_hw_frames_parameters(
            codec_context,
            codec_context.*.hw_device_ctx,
            c.AV_PIX_FMT_VULKAN,
            &frames_ref,
        );
        if (params_result < 0) {
            return codec_context.*.sw_pix_fmt;
        }

        const frames_context: *c.AVHWFramesContext = @ptrCast(@alignCast(frames_ref.*.data));
        const vulkan_frames: *c.AVVulkanFramesContext = @ptrCast(@alignCast(frames_context.hwctx));
        const supported = supports_vulkan_frame_images(codec_context, vulkan_frames);
        c.av_buffer_unref(&frames_ref);
        return if (supported) c.AV_PIX_FMT_VULKAN else codec_context.*.sw_pix_fmt;
    }

    fn supports_vulkan_frame_images(
        codec_context: [*c]c.AVCodecContext,
        vulkan_frames: *const c.AVVulkanFramesContext,
    ) bool {
        const device_context: *c.AVHWDeviceContext = @ptrCast(@alignCast(codec_context.*.hw_device_ctx.*.data));
        const vulkan: *Vulkan = @ptrCast(@alignCast(device_context.user_opaque.?));
        var format_info = vk.PhysicalDeviceImageFormatInfo2{
            .p_next = vulkan_frames.create_pnext,
            .format = @fromBackingInt(@intCast(@as(c_int, @intCast(vulkan_frames.format[0])))),
            .type = .@"2d",
            .tiling = .optimal,
            .usage = vk.ImageUsageFlags.fromInt(@intCast(vulkan_frames.usage | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT)),
            .flags = .{ .mutable_format = true, .extended_usage = true, .alias = true },
        };
        var properties = std.mem.zeroes(vk.ImageFormatProperties2);
        properties.s_type = .image_format_properties_2;

        vulkan.instance.getPhysicalDeviceImageFormatProperties2(
            vulkan.physical_device,
            &format_info,
            &properties,
        ) catch {
            log.info("[supports_vulkan_frame_images] video image configuration is unsupported - using software decoding", .{});
            return false;
        };

        return true;
    }
};
