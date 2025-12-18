const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const c = @import("./pipewire_include.zig").c;
const vk = @import("vulkan");
const Vulkan = @import("../../../vulkan/vulkan.zig").Vulkan;
const BufferedChan = @import("../../../channel.zig").BufferedChan;
const pipewire_util = @import("./pipewire_util.zig");

const PipewireFrameBufferImage = struct {
    image: vk.Image,
    image_view: vk.ImageView,
    device_memory: vk.DeviceMemory,
    fd: i64,
};

pub const PipewireFrameBuffer = struct {
    pwb: *c.struct_pw_buffer,
    dequeued: bool = false,
    dequeued_time: ?i128 = null,
    frame_buffer_image: ?PipewireFrameBufferImage = null,
};

/// Manages Vulkan images per pipewire frame buffer. This is not thread safe.
/// It should only be used within the main pipewire loop.
pub const PipewireFrameBufferManager = struct {
    const Self = @This();
    const log = std.log.scoped(.FrameBufferManager);
    allocator: Allocator,
    vulkan: *Vulkan,
    frame_buffers: std.AutoHashMap(*c.struct_pw_buffer, PipewireFrameBuffer),
    /// This is the semaphore for the pipewire dmabuf.
    vk_foreign_semaphore: ?vk.Semaphore = null,

    pub fn init(
        allocator: Allocator,
        vulkan: *Vulkan,
    ) !*Self {
        const self = try allocator.create(Self);

        self.* = .{
            .allocator = allocator,
            .vulkan = vulkan,
            .frame_buffers = .init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.vk_foreign_semaphore) |vk_foreign_semaphore| {
            self.vulkan.device.destroySemaphore(vk_foreign_semaphore, null);
            self.vk_foreign_semaphore = null;
        }

        var iter = self.frame_buffers.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.frame_buffer_image) |*frame_buffer_image| {
                self.destroyBufferImage(frame_buffer_image);
            }
        }
        self.frame_buffers.deinit();
        self.allocator.destroy(self);
    }

    pub fn addPipewireBuffer(self: *Self, pwb: *c.struct_pw_buffer) !void {
        try self.frame_buffers.put(pwb, .{
            .pwb = pwb,
        });
    }

    pub fn removePipewireBuffer(self: *Self, pwb: *c.struct_pw_buffer) void {
        if (self.frame_buffers.getPtr(pwb)) |frame_buffer| {
            if (frame_buffer.frame_buffer_image) |*frame_buffer_image| {
                self.destroyBufferImage(frame_buffer_image);
            }
        }
        _ = self.frame_buffers.remove(pwb);
    }

    /// Get a Vulkan image from a pipewire buffer. Vulkan images are lazily created.
    pub fn getVulkanImage(
        self: *Self,
        pwb: *c.struct_pw_buffer,
        info: c.spa_video_info_raw,
    ) !struct { frame_buffer: *PipewireFrameBuffer, wait_semaphore: vk.Semaphore } {
        const _frame_buffer = self.frame_buffers.getPtr(pwb);
        // Should never be null here. If it is, there are big problems.
        assert(_frame_buffer != null);
        const frame_buffer = _frame_buffer.?;

        const n_datas = frame_buffer.pwb.buffer[0].n_datas;
        var subresource_layouts = try std.ArrayList(vk.SubresourceLayout).initCapacity(self.allocator, n_datas);
        defer subresource_layouts.deinit(self.allocator);

        for (0..n_datas) |i| {
            const buf_data = frame_buffer.pwb.buffer[0].datas[i];
            const row_pitch: u64 = @intCast(buf_data.chunk[0].stride);
            const subresource_layout = vk.SubresourceLayout{
                .offset = buf_data.chunk[0].offset,
                .size = 0,
                .array_pitch = 0,
                .depth_pitch = 0,
                .row_pitch = row_pitch,
            };
            try subresource_layouts.append(self.allocator, subresource_layout);
        }

        if (self.vk_foreign_semaphore == null) {
            self.vk_foreign_semaphore = try self.vulkan.device.createSemaphore(&.{}, null);
        }

        const fd = frame_buffer.pwb.buffer[0].datas[0].fd;
        try pipewire_util.dmabufExportSyncFile(self.vulkan, fd, self.vk_foreign_semaphore.?);

        // First, check if vulkan images have not yet been created for a buffer.
        if (frame_buffer.frame_buffer_image == null) {
            frame_buffer.frame_buffer_image = try self.createVulkanImage(info, fd, subresource_layouts.items);
        }

        assert(frame_buffer.frame_buffer_image != null);

        var buffer_image = frame_buffer.frame_buffer_image.?;

        // Next, check if the file descriptor matches, then return if so.
        if (buffer_image.fd != fd) {
            // Finally, if the FD doesn't match, destroy the buffer image and create a new one.
            self.destroyBufferImage(&buffer_image);

            frame_buffer.frame_buffer_image = try self.createVulkanImage(info, fd, subresource_layouts.items);
            assert(frame_buffer.frame_buffer_image != null);
        }

        return .{
            .frame_buffer = frame_buffer,
            .wait_semaphore = self.vk_foreign_semaphore.?,
        };
    }

    fn destroyBufferImage(self: *Self, buffer_image: *PipewireFrameBufferImage) void {
        self.vulkan.device.destroyImageView(buffer_image.image_view, null);
        self.vulkan.device.destroyImage(buffer_image.image, null);
        self.vulkan.device.freeMemory(buffer_image.device_memory, null);
    }

    fn createVulkanImage(
        self: *Self,
        info: c.spa_video_info_raw,
        fd: i64,
        subresource_layouts: []vk.SubresourceLayout,
    ) !PipewireFrameBufferImage {
        const modifier_info = vk.ImageDrmFormatModifierExplicitCreateInfoEXT{
            .drm_format_modifier = info.modifier,
            .drm_format_modifier_plane_count = @intCast(subresource_layouts.len),
            .p_plane_layouts = subresource_layouts.ptr,
        };

        const external_memory_image_info = vk.ExternalMemoryImageCreateInfo{
            .handle_types = .{ .dma_buf_bit_ext = true },
            .p_next = &modifier_info,
        };

        const image_create_info = vk.ImageCreateInfo{
            .p_next = &external_memory_image_info,
            .image_type = .@"2d",
            .format = pipewire_util.spaToVkFormat(info.format),
            .extent = .{ .depth = 1, .width = info.size.width, .height = info.size.height },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .drm_format_modifier_ext,
            .usage = .{
                .storage_bit = true,
                .color_attachment_bit = true,
                .transfer_src_bit = true,
            },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        };

        const image = try self.vulkan.device.createImage(&image_create_info, null);
        errdefer self.vulkan.device.destroyImage(image, null);

        const mem_reqs = self.vulkan.device.getImageMemoryRequirements(image);

        var import_fd_info = vk.ImportMemoryFdInfoKHR{
            .handle_type = .{ .dma_buf_bit_ext = true },
            .fd = c.fcntl(@intCast(fd), c.F_DUPFD_CLOEXEC, @as(u32, 0)),
        };

        // NOTE: This is critical for Nvidia cards. Causes buffer to be empty without it.
        const memory_dedicated_allocate_info = vk.MemoryDedicatedAllocateInfo{
            .image = image,
        };

        import_fd_info.p_next = &memory_dedicated_allocate_info;

        // CRITICAL: If this call succeeds, Vulkan owns the FD.
        const device_memory = try self.vulkan.allocate(mem_reqs, .{ .device_local_bit = true }, @ptrCast(&import_fd_info));
        errdefer self.vulkan.device.freeMemory(device_memory, null);

        try self.vulkan.device.bindImageMemory(image, device_memory, 0);

        const view_info = vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = pipewire_util.spaToVkFormat(info.format),
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
        };

        const image_view = try self.vulkan.device.createImageView(&view_info, null);
        errdefer self.vulkan.device.destroyImageView(image_view, null);

        return .{
            .image = image,
            .image_view = image_view,
            .device_memory = device_memory,
            .fd = fd,
        };
    }
};
