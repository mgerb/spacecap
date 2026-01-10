const std = @import("std");

const Vulkan = @import("../../../../vulkan/vulkan.zig").Vulkan;
const c = @import("../../../../common/linux/pipewire_include.zig").c;
const vk = @import("vulkan");

/// Export a semaphore from a dmabuf file descriptor. This
/// is from spa plugins, but I redefine it here because I don't
/// need to load the whole plugin.
///
/// See pipewire/spa/plugins/vulkan/vulkan-utils.c
pub fn dmabufExportSyncFile(vulkan: *Vulkan, dmabuf_fd: i64, semaphore: vk.Semaphore) !void {
    errdefer _ = c.close(@intCast(dmabuf_fd));
    var data = c.dma_buf_export_sync_file{
        .flags = c.DMA_BUF_SYNC_READ,
        .fd = -1,
    };

    const result = c.drmIoctl(@intCast(dmabuf_fd), c.DMA_BUF_IOCTL_EXPORT_SYNC_FILE, @ptrCast(&data));
    if (result != 0) {
        std.log.err("drmIoctl: {}", .{result});
        return error.drmIoctl;
    }

    errdefer _ = c.close(data.fd);

    const import_info = vk.ImportSemaphoreFdInfoKHR{
        .p_next = null,
        .handle_type = .{ .sync_fd_bit = true },
        .flags = .{ .temporary_bit = true },
        .semaphore = semaphore,
        .fd = data.fd,
    };

    try vulkan.device.importSemaphoreFdKHR(&import_info);
}

pub fn spaToVkFormat(spa_format: u32) vk.Format {
    return switch (spa_format) {
        // NOTE: This may seem odd, but we will swizzle rgb
        // values in the compute shader and set the format
        // as opposite here. This is done to prevent vulkan
        // validation errors.
        c.SPA_VIDEO_FORMAT_BGRx => vk.Format.r8g8b8a8_unorm,
        c.SPA_VIDEO_FORMAT_BGRA => vk.Format.r8g8b8a8_unorm,
        c.SPA_VIDEO_FORMAT_BGR => vk.Format.r8g8b8_srgb,

        c.SPA_VIDEO_FORMAT_RGBx => vk.Format.r8g8b8a8_srgb,
        c.SPA_VIDEO_FORMAT_RGBA => vk.Format.r8g8b8a8_srgb,
        c.SPA_VIDEO_FORMAT_RGB => vk.Format.r8g8b8_srgb,

        c.SPA_VIDEO_FORMAT_ARGB => vk.Format.b8g8r8a8_srgb,
        c.SPA_VIDEO_FORMAT_ABGR => vk.Format.r8g8b8a8_srgb,
        // TODO: figure out rest
        c.SPA_VIDEO_FORMAT_xRGB_210LE => vk.Format.a2r10g10b10_unorm_pack32,
        c.SPA_VIDEO_FORMAT_xBGR_210LE => vk.Format.a2b10g10r10_unorm_pack32,
        c.SPA_VIDEO_FORMAT_ARGB_210LE => vk.Format.a2r10g10b10_unorm_pack32,
        c.SPA_VIDEO_FORMAT_ABGR_210LE => vk.Format.a2b10g10r10_unorm_pack32,
        else => vk.Format.undefined,
    };
}
