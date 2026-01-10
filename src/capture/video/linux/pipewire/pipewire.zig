const std = @import("std");
const rc = @import("zigrc");

const pipewire_util = @import("./pipewire_util.zig");
const Chan = @import("../../../../channel.zig").Chan;
const ChanError = @import("../../../../channel.zig").ChanError;
const VulkanImageBufferChan = @import("./vulkan_image_buffer_chan.zig").VulkanImageBufferChan;
const Vulkan = @import("../../../../vulkan/vulkan.zig").Vulkan;
const VideoCaptureError = @import("../../video_capture.zig").VideoCaptureError;
const VideoCaptureSourceType = @import("../../video_capture.zig").VideoCaptureSourceType;
const c = @import("./pipewire_include.zig").c;
const c_def = @import("./pipewire_include.zig").c_def;
const Portal = @import("./portal.zig").Portal;
const PipewireFrameBufferManager = @import("./pipewire_frame_buffer_manager.zig").PipewireFrameBufferManager;
const VulkanImageBuffer = @import("../../../../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;

pub const Pipewire = struct {
    const log = std.log.scoped(.Pipewire);
    const Self = @This();

    portal: *Portal,
    vulkan: *Vulkan,
    allocator: std.mem.Allocator,
    thread_loop: ?*c.pw_thread_loop = null,
    context: ?*c.pw_context = null,
    core: ?*c.pw_core = null,
    core_listener: c.spa_hook = undefined,
    stream: ?*c.pw_stream = null,
    stream_listener: c.spa_hook = undefined,
    has_format: bool = false,
    format_changed: bool = false,
    // Send messages to Pipewire on this channel.
    rx_chan: Chan(bool),
    // Receive messages from Pipewire on this channel.
    tx_chan: Chan(rc.Arc(*VulkanImageBuffer)),
    worker_thread: ?std.Thread = null,
    pipewire_frame_buffer_manager: ?*PipewireFrameBufferManager = null,
    /// Stores all information about the video stream.
    info: ?c.spa_video_info_raw = null,
    /// This channel is used to communicate from the main pipewire thread
    /// to the worker thread. The worker thread must be separate from the
    /// main pipewire loop, because it blocks and waits for the consumer.
    vulkan_image_buffer_chan: VulkanImageBufferChan,

    pub fn init(
        allocator: std.mem.Allocator,
        vulkan: *Vulkan,
    ) (VideoCaptureError || anyerror)!*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .rx_chan = try .init(allocator),
            .tx_chan = try .init(allocator),
            .portal = try .init(allocator),
            .vulkan = vulkan,
            .vulkan_image_buffer_chan = try VulkanImageBufferChan.init(allocator),
        };

        c.pw_init(null, null);
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Stop the thread loop so we don't get anymore process callbacks.
        if (self.thread_loop) |thread_loop| {
            c.pw_thread_loop_lock(thread_loop);
            // Make sure no signals are waiting.
            c.pw_thread_loop_accept(thread_loop);
            c.pw_thread_loop_unlock(thread_loop);
            c.pw_thread_loop_stop(thread_loop);
        }

        // Deinit all channels. This should terminate the worker thread.
        self.rx_chan.deinit();
        self.tx_chan.deinit();
        self.vulkan_image_buffer_chan.deinit();

        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }

        if (self.stream) |stream| {
            _ = c.pw_stream_disconnect(stream);
            _ = c.pw_stream_destroy(stream);
            self.stream = null;
        }

        if (self.core) |core| {
            _ = c.pw_core_disconnect(core);
            self.core = null;
        }

        if (self.context) |context| {
            _ = c.pw_context_destroy(context);
            self.context = null;
        }

        if (self.thread_loop) |thread_loop| {
            c.pw_thread_loop_destroy(thread_loop);
            self.thread_loop = null;
        }

        c.pw_deinit();

        if (self.pipewire_frame_buffer_manager) |frame_buffer_manager| {
            frame_buffer_manager.deinit();
        }

        self.vulkan.destroyCaptureRingBuffer();
        self.portal.deinit();
        self.allocator.destroy(self);
    }

    pub fn selectSource(
        self: *Self,
        source_type: VideoCaptureSourceType,
    ) (VideoCaptureError || anyerror)!void {
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

        self.stream = c.pw_stream_new(self.core, "Spacecap (host)", c.pw_properties_new(
            c.PW_KEY_MEDIA_TYPE,
            "Video",
            c.PW_KEY_MEDIA_CATEGORY,
            "Capture",
            c.PW_KEY_MEDIA_ROLE,
            "Screen",
            c.NULL,
        )) orelse return error.pw_stream_new;

        self.pipewire_frame_buffer_manager = try .init(self.allocator, self.vulkan);

        c.pw_stream_add_listener(self.stream, &self.stream_listener, &stream_events, self);

        try self.startStream(pipewire_node);

        while (!self.has_format) {
            c.pw_thread_loop_wait(self.thread_loop);
        }

        c.pw_thread_loop_unlock(self.thread_loop);

        if (self.info == null or self.info.?.format < 0) {
            return error.bad_format;
        }

        self.worker_thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    fn build_format(self: *const Self, b: ?*c.spa_pod_builder, format: u32, modifiers: []const u64) ?*c.spa_pod {
        _ = self;
        var format_frame = std.mem.zeroes(c.spa_pod_frame);

        _ = c.spa_pod_builder_push_object(b, @ptrCast(&format_frame), c.SPA_TYPE_OBJECT_Format, c.SPA_PARAM_EnumFormat);
        _ = c.spa_pod_builder_add(b, @as(i32, c.SPA_FORMAT_mediaType), "I", @as(i32, c.SPA_MEDIA_TYPE_video), @as(i32, 0));
        _ = c.spa_pod_builder_add(b, @as(u32, c.SPA_FORMAT_mediaSubtype), "I", @as(i32, c.SPA_MEDIA_SUBTYPE_raw), @as(i32, 0));
        _ = c.spa_pod_builder_add(b, @as(u32, c.SPA_FORMAT_VIDEO_format), "I", @as(u32, format), @as(i32, 0));

        // TODO: Need to update this to handle single modifiers - see fixate example.
        if (modifiers.len > 0) {
            var modifier_frame = std.mem.zeroes(c.spa_pod_frame);

            _ = c.spa_pod_builder_prop(b, c.SPA_FORMAT_VIDEO_modifier, c.SPA_POD_PROP_FLAG_MANDATORY | c.SPA_POD_PROP_FLAG_DONT_FIXATE);
            _ = c.spa_pod_builder_push_choice(b, &modifier_frame, c.SPA_CHOICE_Enum, 0);

            for (modifiers) |mod| {
                _ = c_def.spa_pod_builder_long(b, @intCast(mod));
            }

            _ = c_def.spa_pod_builder_pop(b, &modifier_frame);
        }

        // TODO: Update fps.
        _ = c.spa_pod_builder_add(
            b,
            @as(u32, c.SPA_FORMAT_VIDEO_size),
            "?rR",
            @as(u32, 3),
            &c.SPA_RECTANGLE(32, 32),
            &c.SPA_RECTANGLE(1, 1),
            &c.SPA_RECTANGLE(16384, 16384),
            @as(u32, c.SPA_FORMAT_VIDEO_framerate),
            "?rF",
            @as(u32, 3),
            &c.SPA_FRACTION(60, 1), // FPS
            &c.SPA_FRACTION(0, 1),
            &c.SPA_FRACTION(500, 1),
            @as(i32, 0),
        );

        const ptr = c_def.spa_pod_builder_pop(b, &format_frame);

        if (ptr != null) {
            return @ptrCast(@alignCast(ptr));
        }

        return null;
    }

    fn startStream(self: *const Self, node: u32) !void {
        log.debug("[startStream] starting stream for node: {}", .{node});

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
        log.debug("[streamProcessCallback]", .{});
        const self: *Self = @ptrCast(@alignCast(data));

        if (!self.has_format) {
            log.debug("[streamProcessCallback] does not have format", .{});
            return;
        }

        // Grab the newest buffer.
        var pipewire_buffer: ?*c.struct_pw_buffer = null;
        while (true) {
            const tmp: ?*c.struct_pw_buffer = c.pw_stream_dequeue_buffer(self.stream);

            if (tmp == null) {
                break;
            }

            // Only keep buffers that are dmabuf.
            if (tmp.?.buffer == null or tmp.?.buffer[0].datas[0].type != c.SPA_DATA_DmaBuf) {
                _ = c.pw_stream_queue_buffer(self.stream.?, tmp.?);
                continue;
            }

            if (pipewire_buffer) |pwb| {
                _ = c.pw_stream_queue_buffer(self.stream.?, pwb);
            }

            pipewire_buffer = tmp;
        }

        const pwb = pipewire_buffer.?;

        // TODO: Should gracefully handle these errors.
        defer _ = c.pw_stream_queue_buffer(self.stream.?, pwb);

        const vulkan_image = self.pipewire_frame_buffer_manager.?.getVulkanImage(pwb, self.info.?) catch |err| {
            log.err("[streamProcessCallback] unable to get buffer: {}", .{err});
            unreachable;
        };

        const copy_data = blk: {
            const capture_ring_buffer = self.vulkan.capture_ring_buffer.lock();
            defer capture_ring_buffer.unlock();
            break :blk capture_ring_buffer.unwrap().?.copyImageToRingBuffer(.{
                .src_image = vulkan_image.frame_buffer.frame_buffer_image.?.image,
                .src_width = self.info.?.size.width,
                .src_height = self.info.?.size.height,
                .wait_semaphore = vulkan_image.wait_semaphore,
                .use_signal_semaphore = false,
            }) catch |err| {
                log.err("[streamProcessCallback] unable to get buffer: {}", .{err});
                unreachable;
            };
        };

        if (copy_data.fence) |fence| {
            _ = self.vulkan.device.waitForFences(1, @ptrCast(&fence), .true, std.math.maxInt(u64)) catch |err| {
                log.err("[streamProcessCallback] error waiting for fences: {}", .{err});
            };
        }

        if (copy_data.vulkan_image_buffer) |vulkan_image_buffer| {
            self.vulkan_image_buffer_chan.drain();
            self.vulkan_image_buffer_chan.send(vulkan_image_buffer) catch |err| {
                log.err("[streamProcessCallback] vulkan image buffer chan send err: {}", .{err});
            };
        }
    }

    fn workerMain(self: *Self) !void {
        while (true) {
            // Wait for the consumer to request a new frame.
            _ = self.rx_chan.recv() catch |err| {
                if (err == ChanError.Closed) {
                    break;
                }
                log.err("[workerMain] rx_chan error: {}", .{err});
                return err;
            };

            // Wait for a new pipewire frame buffer.
            const vulkan_image_buffer = self.vulkan_image_buffer_chan.recv() catch |err| {
                if (err == ChanError.Closed) {
                    break;
                }
                log.err("[workerMain] vulkan_image_buffer_chan error: {}", .{err});
                return err;
            };

            // Send the buffer to the consumer.
            self.tx_chan.send(vulkan_image_buffer) catch |err| {
                switch (err) {
                    ChanError.Closed => {
                        if (vulkan_image_buffer.releaseUnwrap()) |val| val.deinit();
                        break;
                    },
                    else => {
                        log.err("[workerMain] tx_chan error: {}", .{err});
                        return err;
                    },
                }
            };
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

        log.debug("[streamStateChangedCallback] pipewire stream state change: {s} -> {s}", .{
            c.pw_stream_state_as_string(old_state),
            c.pw_stream_state_as_string(new_state),
        });

        if (new_state == c.PW_STREAM_STATE_ERROR) {
            log.debug("[streamStateChangedCallback] pipewire stream error: {s}", .{error_});
        }

        if (new_state == c.PW_STREAM_STATE_STREAMING) {
            log.debug("[streamStateChangedCallback] pipewire state streaming", .{});
        }
    }

    fn streamParamChangedCallback(data: ?*anyopaque, id: u32, param: [*c]const c.spa_pod) callconv(.c) void {
        log.debug("[streamParamChangedCallback]", .{});

        const self: *Self = @ptrCast(@alignCast(data));

        if (param == null or id != c.SPA_PARAM_Format) {
            return;
        }

        var media_type: u32 = undefined;
        var media_subtype: u32 = undefined;

        const fmt = c_def.spa_format_parse(param, &media_type, &media_subtype);

        if (fmt < 0 or
            media_type != c.SPA_MEDIA_TYPE_video or
            media_subtype != c.SPA_MEDIA_SUBTYPE_raw)
        {
            log.debug("[streamParamChangedCallback] media_type: {}, media_subtype: {}", .{ media_type, media_subtype });
            return;
        }

        self.info = std.mem.zeroes(c.spa_video_info_raw);

        if (c_def.spa_format_video_raw_parse(param, @ptrCast(&self.info)) < 0) {
            log.debug("[streamParamChangedCallback] failed to parse video info", .{});
            return;
        }

        {
            self.vulkan.destroyCaptureRingBuffer();
            // TODO: Figure out how to bubble this error up and display it on the UI.
            self.vulkan.initCaptureRingBuffer(self.info.?.size.width, self.info.?.size.height) catch unreachable;
        }

        self.sendStreamParams();

        log.debug("[streamParamChangedCallback] stream format: {}", .{self.info.?.format});
        self.has_format = true;
        self.format_changed = false;

        c.pw_thread_loop_signal(self.thread_loop, false);
    }

    fn sendStreamParams(self: *Self) void {
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
    }

    fn streamAddBufferCallback(data: ?*anyopaque, pwb: [*c]c.struct_pw_buffer) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        log.debug("[streamAddBufferCallback]", .{});

        self.pipewire_frame_buffer_manager.?.addPipewireBuffer(pwb) catch |err| {
            log.err("[streamAddBufferCallback] failed to add to active_buffers: {}", .{err});
        };
    }

    fn streamRemoveBufferCallback(data: ?*anyopaque, pwb: [*c]c.struct_pw_buffer) callconv(.c) void {
        log.debug("[streamRemoveBufferCallback]", .{});
        const self: *Self = @ptrCast(@alignCast(data));

        self.pipewire_frame_buffer_manager.?.removePipewireBuffer(pwb);
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
        log.err(
            "[coreErrorCallback] pipewire error: id {}, seq: {}, res: {}: {s}",
            .{
                id,
                seq,
                res,
                message,
            },
        );
    }
};
