const std = @import("std");
const vk = @import("vulkan");

const pipewire_util = @import("./pipewire_util.zig");
const types = @import("../../../types.zig");
const Chan = @import("../../../channel.zig").Chan;
const ChanError = @import("../../../channel.zig").ChanError;
const util = @import("../../../util.zig");
const Vulkan = @import("../../../vulkan/vulkan.zig").Vulkan;
const CaptureError = @import("../../capture.zig").CaptureError;
const c = @import("./pipewire_include.zig").c;
const c_def = @import("./pipewire_include.zig").c_def;
const Portal = @import("./portal.zig").Portal;
const CaptureSourceType = @import("../../capture.zig").CaptureSourceType;

pub const Pipewire = struct {
    const Self = @This();

    portal: *Portal,
    allocator: std.mem.Allocator,
    thread_loop: ?*c.pw_thread_loop = null,
    context: ?*c.pw_context = null,
    core: ?*c.pw_core = null,
    core_listener: c.spa_hook = undefined,
    stream: ?*c.pw_stream = null,
    stream_listener: c.spa_hook = undefined,
    has_format: bool = false,
    format_changed: bool = false,
    frame_data: ?[]u8 = null,
    // Send messages to Pipewire on this channel
    rx_chan: Chan(bool),
    // Receive messages from Pipewire on this channel
    tx_chan: Chan(types.VkImages),
    pw_buffer: ?*c.pw_buffer = null,

    /// Stores all information about the video stream
    info: ?c.spa_video_info_raw = null,

    // vulkan stuff
    vulkan: *Vulkan,
    vk_image: ?vk.Image = null,
    vk_image_view: ?vk.ImageView = null,
    vk_device_memory: ?vk.DeviceMemory = null,
    /// This is the semaphore for the pipewire dambuf
    vk_foreign_semaphore: ?vk.Semaphore = null,
    semaphore_fd: ?i32 = null,

    frame_time: i128 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        vulkan: *Vulkan,
    ) (CaptureError || anyerror)!*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .rx_chan = try Chan(bool).init(allocator),
            .tx_chan = try Chan(types.VkImages).init(allocator),
            .portal = try Portal.init(allocator),
            .vulkan = vulkan,
            .frame_time = std.time.nanoTimestamp(),
        };

        c.pw_init(null, null);
        return self;
    }

    pub fn selectSource(
        self: *Self,
        source_type: CaptureSourceType,
    ) (CaptureError || anyerror)!void {
        const pipewire_node = try self.portal.selectSource(source_type);
        const pipewire_fd = try self.portal.openPipewireRemote();
        errdefer _ = c.close(pipewire_fd);

        self.thread_loop = c.pw_thread_loop_new(
            "spacecap-pipewire-capture",
            null,
        ) orelse return error.pw_thread_loop_new;

        self.context = c.pw_context_new(
            c.pw_thread_loop_get_loop(self.thread_loop),
            null,
            0,
        );

        if (self.context == null) {
            return error.pw_context_new;
        }

        if (c.pw_thread_loop_start(self.thread_loop) < 0) {
            return error.pw_thread_loop_start;
        }

        c.pw_thread_loop_lock(self.thread_loop);

        self.core = c.pw_context_connect_fd(
            self.context,
            pipewire_fd,
            null,
            0,
        ) orelse return error.pw_context_connect_fd;

        _ = c.pw_core_add_listener(self.core, &self.core_listener, &core_events, null);

        self.stream = c.pw_stream_new(self.core, "Spacecap (host)", c.pw_properties_new(c.PW_KEY_MEDIA_TYPE, "Video", c.PW_KEY_MEDIA_CATEGORY, "Capture", c.PW_KEY_MEDIA_ROLE, "Screen", c.NULL)) orelse return error.pw_stream_new;

        c.pw_stream_add_listener(self.stream, &self.stream_listener, &stream_events, self);

        try self.startStream(pipewire_node);

        while (!self.has_format) {
            c.pw_thread_loop_wait(self.thread_loop);
        }

        c.pw_thread_loop_unlock(self.thread_loop);

        if (self.info == null or self.info.?.format < 0) {
            return error.bad_format;
        }
    }

    pub fn stop(self: *Self) !void {
        self.rx_chan.close();
        c.pw_thread_loop_lock(self.thread_loop);

        // TODO: probably want to move this to deinit and only stop the loop here
        _ = c.pw_stream_disconnect(self.stream);
        self.stream = null;

        c.pw_thread_loop_unlock(self.thread_loop);
        c.pw_thread_loop_stop(self.thread_loop);
    }

    fn build_format(self: *const Self, b: ?*c.spa_pod_builder, format: u32, modifiers: []const u64) ?*c.spa_pod {
        _ = self;
        var format_frame = std.mem.zeroes(c.spa_pod_frame);

        _ = c.spa_pod_builder_push_object(b, @ptrCast(&format_frame), c.SPA_TYPE_OBJECT_Format, c.SPA_PARAM_EnumFormat);
        _ = c.spa_pod_builder_add(b, @as(i32, c.SPA_FORMAT_mediaType), "I", @as(i32, c.SPA_MEDIA_TYPE_video), @as(i32, 0));
        _ = c.spa_pod_builder_add(b, @as(u32, c.SPA_FORMAT_mediaSubtype), "I", @as(i32, c.SPA_MEDIA_SUBTYPE_raw), @as(i32, 0));
        _ = c.spa_pod_builder_add(b, @as(u32, c.SPA_FORMAT_VIDEO_format), "I", @as(u32, format), @as(i32, 0));

        // TODO: need to update this to handle single modifiers - see fixate example
        if (modifiers.len > 0) {
            var modifier_frame = std.mem.zeroes(c.spa_pod_frame);

            _ = c.spa_pod_builder_prop(b, c.SPA_FORMAT_VIDEO_modifier, c.SPA_POD_PROP_FLAG_MANDATORY | c.SPA_POD_PROP_FLAG_DONT_FIXATE);
            _ = c.spa_pod_builder_push_choice(b, &modifier_frame, c.SPA_CHOICE_Enum, 0);

            for (modifiers) |mod| {
                _ = c_def.spa_pod_builder_long(b, @intCast(mod));
            }

            _ = c_def.spa_pod_builder_pop(b, &modifier_frame);
        }

        // TODO: update fps
        // Keep one line otherwise zls breaks from the variadic c functions when cursoring over args.
        _ = c.spa_pod_builder_add(b, @as(u32, c.SPA_FORMAT_VIDEO_size), "?rR", @as(u32, 3), &c.SPA_RECTANGLE(32, 32), &c.SPA_RECTANGLE(1, 1), &c.SPA_RECTANGLE(16384, 16384), @as(u32, c.SPA_FORMAT_VIDEO_framerate), "?rF", @as(u32, 3), &c.SPA_FRACTION(60, 1), &c.SPA_FRACTION(0, 1), &c.SPA_FRACTION(500, 1), @as(i32, 0));

        const ptr = c_def.spa_pod_builder_pop(b, &format_frame);

        if (ptr != null) {
            return @ptrCast(@alignCast(ptr));
        }

        return null;
    }

    fn startStream(self: *const Self, node: u32) !void {
        std.debug.print("[startStream] starting stream for node: {}\n", .{node});

        var buffer = std.mem.zeroes([4096]u8);

        var builder = c.spa_pod_builder{
            .data = buffer[0..].ptr,
            .size = buffer.len,
        };

        const formats = [_]u32{
            c.SPA_VIDEO_FORMAT_RGBx,
            c.SPA_VIDEO_FORMAT_BGRx,
            c.SPA_VIDEO_FORMAT_RGBA,
            c.SPA_VIDEO_FORMAT_BGRA,
            c.SPA_VIDEO_FORMAT_RGB,
            c.SPA_VIDEO_FORMAT_BGR,
            c.SPA_VIDEO_FORMAT_ARGB,
            c.SPA_VIDEO_FORMAT_ABGR,
            c.SPA_VIDEO_FORMAT_xRGB_210LE,
            c.SPA_VIDEO_FORMAT_xBGR_210LE,
            c.SPA_VIDEO_FORMAT_ARGB_210LE,
            c.SPA_VIDEO_FORMAT_ABGR_210LE,
        };

        var params = try std.ArrayList(*c.spa_pod).initCapacity(self.allocator, 0);
        defer params.deinit(self.allocator);

        for (formats) |format| {
            var modifiers = try self.vulkan.queryFormatModifiers(pipewire_util.spaToVkFormat(format));
            defer modifiers.deinit(self.allocator);
            if (modifiers.items.len == 0) {
                continue;
            }
            if (self.build_format(&builder, format, modifiers.items)) |spa_pod| {
                try params.append(self.allocator, spa_pod);
            }
        }

        const status = c.pw_stream_connect(
            self.stream,
            c.PW_DIRECTION_INPUT,
            node,
            c.PW_STREAM_FLAG_AUTOCONNECT | c.PW_STREAM_FLAG_MAP_BUFFERS,
            @ptrCast(params.items.ptr),
            @intCast(params.items.len),
        );

        if (status < 0) {
            return error.pw_stream_connect;
        }
    }

    fn streamProcessCallback(data: ?*anyopaque) callconv(.c) void {
        std.debug.print("[streamProcessCallback]\n", .{});
        const self: *Self = @ptrCast(@alignCast(data));

        if (!self.has_format) {
            return;
        }

        // wait until consumer is ready for a new frame
        const get_next_frame = self.rx_chan.recv() catch |err| {
            switch (err) {
                ChanError.Closed => return,
                else => unreachable,
            }
        };

        if (!get_next_frame) {
            return;
        }

        // dequeue all buffers to get the latest one
        while (true) {
            const tmp = c.pw_stream_dequeue_buffer(self.stream);

            if (tmp == null) {
                break;
            }

            if (self.pw_buffer) |pwb| {
                _ = c.pw_stream_queue_buffer(self.stream, pwb);
            }

            self.pw_buffer = tmp;
        }

        if (self.pw_buffer) |pwb| {
            if (pwb.buffer != null and pwb.buffer[0].datas[0].type == c.SPA_DATA_DmaBuf) {
                const buffer: *c.struct_spa_buffer = @ptrCast(pwb.buffer);

                if (buffer.datas[0].chunk[0].size <= 0) {
                    return;
                }

                var subresource_layouts = std.ArrayList(vk.SubresourceLayout).initCapacity(self.allocator, 0) catch unreachable;
                defer subresource_layouts.deinit(self.allocator);

                for (0..pwb.buffer[0].n_datas) |i| {
                    const buf_data = pwb.buffer[0].datas[i];
                    const row_pitch: u64 = @intCast(buf_data.chunk[0].stride);
                    const subresource_layout = vk.SubresourceLayout{
                        .offset = buf_data.chunk[0].offset,
                        .size = 0,
                        .array_pitch = 0,
                        .depth_pitch = 0,
                        .row_pitch = row_pitch,
                    };
                    subresource_layouts.append(self.allocator, subresource_layout) catch unreachable;
                }

                const images = self.createVulkanImage(
                    self.info.?,
                    buffer.datas[0].fd,
                    subresource_layouts.items,
                ) catch unreachable;

                self.tx_chan.send(images) catch |err| {
                    switch (err) {
                        ChanError.Closed => {}, // do nothing on closed
                        else => unreachable,
                    }
                };

                _ = c.pw_stream_queue_buffer(self.stream, self.pw_buffer.?);
                self.pw_buffer = null;

                util.printElapsed(self.frame_time, "frame time");
                self.frame_time = std.time.nanoTimestamp();
            }
        } else {
            std.debug.print("[streamProcessCallback] pipewire out of buffers\n", .{});
        }
    }

    fn streamStateChangedCallback(
        data: ?*anyopaque,
        old_state: c.pw_stream_state,
        new_state: c.pw_stream_state,
        error_: [*c]const u8,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        _ = self;

        std.debug.print("[streamStateChangedCallback] pipewire stream state change: {s} -> {s}\n", .{
            c.pw_stream_state_as_string(old_state),
            c.pw_stream_state_as_string(new_state),
        });

        if (new_state == c.PW_STREAM_STATE_ERROR) {
            std.debug.print("[streamStateChangedCallback] pipewire stream error: {s}\n", .{error_});
        }
    }

    fn streamParamChangedCallback(data: ?*anyopaque, id: u32, param: [*c]const c.spa_pod) callconv(.c) void {
        std.debug.print("[streamParamChangedCallback]\n", .{});

        const self: *Self = @ptrCast(@alignCast(data));

        if (param == null or id != c.SPA_PARAM_Format) {
            return;
        }

        var media_type: u32 = undefined;
        var media_subtype: u32 = undefined;

        const fmt = c_def.spa_format_parse(param, &media_type, &media_subtype);

        std.debug.print("[streamParamChangedCallback] fmt: {}\n", .{fmt});

        if (fmt < 0 or
            media_type != c.SPA_MEDIA_TYPE_video or
            media_subtype != c.SPA_MEDIA_SUBTYPE_raw)
        {
            std.debug.print("[streamParamChangedCallback] media_type: {}, media_subtype: {}\n", .{ media_type, media_subtype });
            return;
        }

        self.info = std.mem.zeroes(c.spa_video_info_raw);

        if (c_def.spa_format_video_raw_parse(param, @ptrCast(&self.info)) < 0) {
            std.debug.print("[streamParamChangedCallback] failed to parse video info", .{});
            return;
        }

        if (self.has_format) {
            self.format_changed = true;
            return;
        }

        var buffer = std.mem.zeroes([1024]u8);

        var builder = c.spa_pod_builder{
            .data = @ptrCast(&buffer),
            .size = 1024,
        };

        var params = std.ArrayList(*c.struct_spa_pod).initCapacity(self.allocator, 0) catch unreachable;
        defer params.deinit(self.allocator);

        // damage
        params.append(self.allocator, @ptrCast(@alignCast(c_def.spa_pod_builder_add_object(
            &builder,
            c.SPA_TYPE_OBJECT_ParamMeta,
            c.SPA_PARAM_Meta,
            .{
                c.SPA_PARAM_META_type,
                "I",
                c.SPA_META_VideoDamage,
                c.SPA_PARAM_META_size,
                "?ri",
                @as(i32, 3),
                @as(i32, @sizeOf(c.spa_meta_region) * 16),
                @as(i32, @sizeOf(c.spa_meta_region) * 1),
                @as(i32, @sizeOf(c.spa_meta_region) * 16),
            },
        )))) catch unreachable;

        // cursor
        params.append(self.allocator, @ptrCast(@alignCast(c_def.spa_pod_builder_add_object(
            &builder,
            c.SPA_TYPE_OBJECT_ParamMeta,
            c.SPA_PARAM_Meta,
            .{
                c.SPA_PARAM_META_type,
                "I",
                c.SPA_META_Cursor,
                c.SPA_PARAM_META_size,
                "?ri",
                @as(i32, 3),
                @as(i32, @sizeOf(c.spa_meta_cursor) + @sizeOf(c.spa_meta_bitmap) + 64 + 64 * 4),
                @as(i32, @sizeOf(c.spa_meta_cursor) + @sizeOf(c.spa_meta_bitmap) + 1 + 1 * 4),
                @as(i32, @sizeOf(c.spa_meta_cursor) + @sizeOf(c.spa_meta_bitmap) + 1024 + 1024 * 4),
            },
        )))) catch unreachable;

        params.append(self.allocator, @ptrCast(@alignCast(c_def.spa_pod_builder_add_object(&builder, c.SPA_TYPE_OBJECT_ParamBuffers, c.SPA_PARAM_Buffers, .{
            c.SPA_PARAM_BUFFERS_dataType,
            "i",
            @as(i32, 1 << c.SPA_DATA_DmaBuf),
        })))) catch unreachable;

        _ = c.pw_stream_update_params(self.stream, @ptrCast(params.items.ptr), @intCast(params.items.len));

        std.debug.print("[streamParamChangedCallback] stream format: {}\n", .{self.info.?.format});
        self.has_format = true;

        c.pw_thread_loop_signal(self.thread_loop, false);
    }

    fn streamAddBufferCallback(data: ?*anyopaque, pw_buffer: [*c]c.struct_pw_buffer) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        _ = self;
        _ = pw_buffer;
        std.debug.print("[streamAddBufferCallback]\n", .{});
    }

    // TODO: reuse vulkan images instead of creating/destroying them for every frame
    fn createVulkanImage(
        self: *Self,
        info: c.spa_video_info_raw,
        fd: i64,
        subresource_layouts: []vk.SubresourceLayout,
    ) !types.VkImages {
        self.cleanVulkanResources();

        if (self.vk_foreign_semaphore == null) {
            self.vk_foreign_semaphore = try self.vulkan.device.createSemaphore(&.{}, null);
        }

        self.semaphore_fd = c.fcntl(@intCast(fd), c.F_DUPFD_CLOEXEC, @as(u32, 0));
        try pipewire_util.dmabufExportSyncFile(self.vulkan, fd, self.vk_foreign_semaphore.?);

        errdefer {
            _ = c.close(@intCast(self.semaphore_fd.?));
            self.semaphore_fd = null;
        }

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

        self.vk_image = image;
        self.vk_image_view = image_view;
        self.vk_device_memory = device_memory;

        return .{
            .image = image,
            .image_view = image_view,
        };
    }

    fn streamRemoveBufferCallback(data: ?*anyopaque, pw_buffer: [*c]c.struct_pw_buffer) callconv(.c) void {
        std.debug.print("[streamRemoveBufferCallback]\n", .{});
        const self: *Self = @ptrCast(@alignCast(data));
        _ = pw_buffer;
        _ = self;
    }

    const stream_events = c.pw_stream_events{
        .version = c.PW_VERSION_STREAM_EVENTS,
        .process = streamProcessCallback,
        .state_changed = streamStateChangedCallback,
        .param_changed = streamParamChangedCallback,
        .add_buffer = streamAddBufferCallback,
        .remove_buffer = streamRemoveBufferCallback,
    };

    const core_events = c.pw_core_events{
        .version = c.PW_VERSION_CORE_EVENTS,
        .@"error" = coreErrorCallback,
    };

    fn coreErrorCallback(
        opaque_: ?*anyopaque,
        id: u32,
        seq: i32,
        res: i32,
        message: [*c]const u8,
    ) callconv(.c) void {
        _ = opaque_;
        std.log.err(
            "[coreErrorCallback] pipewire error: id {}, seq: {}, res: {}: {s}\n",
            .{
                id,
                seq,
                res,
                message,
            },
        );
    }

    fn cleanVulkanResources(self: *Self) void {
        if (self.vk_image) |image| {
            self.vulkan.device.destroyImage(image, null);
        }
        self.vk_image = null;
        if (self.vk_image_view) |image_view| {
            self.vulkan.device.destroyImageView(image_view, null);
        }
        self.vk_image_view = null;
        if (self.vk_device_memory) |device_memory| {
            self.vulkan.device.freeMemory(device_memory, null);
        }
        self.vk_device_memory = null;

        if (self.semaphore_fd) |semaphore_fd| {
            _ = c.close(semaphore_fd);
        }
        self.semaphore_fd = null;
    }

    pub fn deinit(self: *Self) void {
        self.rx_chan.deinit();
        self.tx_chan.deinit();

        if (self.vk_foreign_semaphore) |vk_foreign_semaphore| {
            self.vulkan.device.destroySemaphore(vk_foreign_semaphore, null);
        }
        self.vk_foreign_semaphore = null;

        self.cleanVulkanResources();

        self.portal.deinit();

        if (self.thread_loop) |thread_loop| {
            c.pw_thread_loop_lock(thread_loop);

            self.pw_buffer = null;

            // make sure no signals are waiting
            c.pw_thread_loop_accept(thread_loop);
        }

        if (self.core) |core| {
            _ = c.pw_core_disconnect(core);
        }

        if (self.stream) |stream| {
            _ = c.pw_stream_disconnect(stream);
            self.stream = null;
        }

        if (self.thread_loop) |thread_loop| {
            c.pw_thread_loop_unlock(self.thread_loop);
            c.pw_thread_loop_stop(thread_loop);
            c.pw_thread_loop_destroy(thread_loop);
            self.thread_loop = null;
        }

        c.pw_deinit();

        self.allocator.destroy(self);
    }
};
