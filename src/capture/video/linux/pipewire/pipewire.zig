const std = @import("std");
const rc = @import("zigrc");
const pw = @import("pipewire").c;

const pipewire_util = @import("./pipewire_util.zig");
const Chan = @import("../../../../channel.zig").Chan;
const ChanError = @import("../../../../channel.zig").ChanError;
const VulkanImageBufferChan = @import("./vulkan_image_buffer_chan.zig").VulkanImageBufferChan;
const Vulkan = @import("../../../../vulkan/vulkan.zig").Vulkan;
const VideoCaptureError = @import("../../video_capture.zig").VideoCaptureError;
const VideoCaptureSourceType = @import("../../video_capture.zig").VideoCaptureSourceType;
const c = @import("../../../../common/linux/pipewire_include.zig").c;
const c_def = @import("../../../../common/linux/pipewire_include.zig").c_def;
const Portal = @import("./portal.zig").Portal;
const PipewireFrameBufferManager = @import("./pipewire_frame_buffer_manager.zig").PipewireFrameBufferManager;
const VulkanImageBuffer = @import("../../../../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;

pub const Pipewire = struct {
    const log = std.log.scoped(.Pipewire);
    const Self = @This();

    portal: *Portal,
    vulkan: *Vulkan,
    allocator: std.mem.Allocator,
    thread_loop: ?*pw.pw_thread_loop = null,
    context: ?*pw.pw_context = null,
    core: ?*pw.pw_core = null,
    core_listener: pw.spa_hook = undefined,
    stream: ?*pw.pw_stream = null,
    stream_listener: pw.spa_hook = undefined,
    has_format: bool = false,
    format_changed: bool = false,
    // Send messages to Pipewire on this channel.
    rx_chan: Chan(bool),
    // Receive messages from Pipewire on this channel.
    tx_chan: Chan(rc.Arc(*VulkanImageBuffer)),
    worker_thread: ?std.Thread = null,
    pipewire_frame_buffer_manager: ?*PipewireFrameBufferManager = null,
    /// Stores all information about the video stream.
    info: ?pw.spa_video_info_raw = null,
    /// This channel is used to communicate from the main pipewire thread
    /// to the worker thread. The worker thread must be separate from the
    /// main pipewire loop, because it blocks and waits for the consumer.
    vulkan_image_buffer_chan: VulkanImageBufferChan,
    previous_frame_timestamp_ns: ?i128 = null,

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

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Stop the thread loop so we don't get anymore process callbacks.
        if (self.thread_loop) |thread_loop| {
            pw.pw_thread_loop_lock(thread_loop);
            // Make sure no signals are waiting.
            pw.pw_thread_loop_accept(thread_loop);
            pw.pw_thread_loop_unlock(thread_loop);
            pw.pw_thread_loop_stop(thread_loop);
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
            _ = pw.pw_stream_disconnect(stream);
            _ = pw.pw_stream_destroy(stream);
            self.stream = null;
        }

        if (self.core) |core| {
            _ = pw.pw_core_disconnect(core);
            self.core = null;
        }

        if (self.context) |context| {
            _ = pw.pw_context_destroy(context);
            self.context = null;
        }

        if (self.thread_loop) |thread_loop| {
            pw.pw_thread_loop_destroy(thread_loop);
            self.thread_loop = null;
        }

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
        errdefer _ = pw.close(pipewire_fd);

        self.thread_loop = pw.pw_thread_loop_new(
            "spacecap-pipewire-capture-video",
            null,
        ) orelse return error.pw_thread_loop_new;
        errdefer pw.pw_thread_loop_destroy(self.thread_loop);

        self.context = pw.pw_context_new(
            pw.pw_thread_loop_get_loop(self.thread_loop),
            null,
            0,
        );

        if (self.context == null) {
            return error.pw_context_new;
        }

        if (pw.pw_thread_loop_start(self.thread_loop) < 0) {
            return error.pw_thread_loop_start;
        }

        pw.pw_thread_loop_lock(self.thread_loop);

        self.core = pw.pw_context_connect_fd(
            self.context,
            pipewire_fd,
            null,
            0,
        ) orelse return error.pw_context_connect_fd;

        _ = pw.pw_core_add_listener(self.core, &self.core_listener, &core_events, null);

        self.stream = pw.pw_stream_new(self.core, "Spacecap (host)", pw.pw_properties_new(
            pw.PW_KEY_MEDIA_TYPE,
            "Video",
            pw.PW_KEY_MEDIA_CATEGORY,
            "Capture",
            pw.PW_KEY_MEDIA_ROLE,
            "Screen",
            pw.NULL,
        )) orelse return error.pw_stream_new;

        self.pipewire_frame_buffer_manager = try .init(self.allocator, self.vulkan);

        pw.pw_stream_add_listener(self.stream, &self.stream_listener, &stream_events, self);

        try self.startStream(pipewire_node);

        while (!self.has_format) {
            pw.pw_thread_loop_wait(self.thread_loop);
        }

        pw.pw_thread_loop_unlock(self.thread_loop);

        if (self.info == null or self.info.?.format < 0) {
            return error.bad_format;
        }

        self.worker_thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    fn build_format(self: *const Self, b: ?*pw.spa_pod_builder, format: u32, modifiers: []const u64) ?*pw.spa_pod {
        _ = self;
        var format_frame = std.mem.zeroes(pw.spa_pod_frame);

        _ = pw.spa_pod_builder_push_object(b, @ptrCast(&format_frame), pw.SPA_TYPE_OBJECT_Format, pw.SPA_PARAM_EnumFormat);
        _ = pw.spa_pod_builder_add(b, @as(i32, pw.SPA_FORMAT_mediaType), "I", @as(i32, pw.SPA_MEDIA_TYPE_video), @as(i32, 0));
        _ = pw.spa_pod_builder_add(b, @as(u32, pw.SPA_FORMAT_mediaSubtype), "I", @as(i32, pw.SPA_MEDIA_SUBTYPE_raw), @as(i32, 0));
        _ = pw.spa_pod_builder_add(b, @as(u32, pw.SPA_FORMAT_VIDEO_format), "I", @as(u32, format), @as(i32, 0));

        // TODO: Need to update this to handle single modifiers - see fixate example.
        if (modifiers.len > 0) {
            var modifier_frame = std.mem.zeroes(pw.spa_pod_frame);

            _ = pw.spa_pod_builder_prop(b, pw.SPA_FORMAT_VIDEO_modifier, pw.SPA_POD_PROP_FLAG_MANDATORY | pw.SPA_POD_PROP_FLAG_DONT_FIXATE);
            _ = pw.spa_pod_builder_push_choice(b, &modifier_frame, pw.SPA_CHOICE_Enum, 0);

            for (modifiers) |mod| {
                _ = c_def.spa_pod_builder_long(b, @intCast(mod));
            }

            _ = c_def.spa_pod_builder_pop(b, &modifier_frame);
        }

        // TODO: Update fps.
        _ = pw.spa_pod_builder_add(
            b,
            @as(u32, pw.SPA_FORMAT_VIDEO_size),
            "?rR",
            @as(u32, 3),
            &pw.SPA_RECTANGLE(32, 32),
            &pw.SPA_RECTANGLE(1, 1),
            &pw.SPA_RECTANGLE(16384, 16384),
            @as(u32, pw.SPA_FORMAT_VIDEO_framerate),
            "?rF",
            @as(u32, 3),
            &pw.SPA_FRACTION(60, 1), // FPS
            &pw.SPA_FRACTION(0, 1),
            &pw.SPA_FRACTION(500, 1),
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

        var builder = pw.spa_pod_builder{
            .data = buffer[0..].ptr,
            .size = buffer.len,
        };

        const formats = [_]u32{
            pw.SPA_VIDEO_FORMAT_RGBx,
            pw.SPA_VIDEO_FORMAT_BGRx,
            pw.SPA_VIDEO_FORMAT_RGBA,
            pw.SPA_VIDEO_FORMAT_BGRA,
            pw.SPA_VIDEO_FORMAT_RGB,
            pw.SPA_VIDEO_FORMAT_BGR,
            pw.SPA_VIDEO_FORMAT_ARGB,
            pw.SPA_VIDEO_FORMAT_ABGR,
            pw.SPA_VIDEO_FORMAT_xRGB_210LE,
            pw.SPA_VIDEO_FORMAT_xBGR_210LE,
            pw.SPA_VIDEO_FORMAT_ARGB_210LE,
            pw.SPA_VIDEO_FORMAT_ABGR_210LE,
        };

        var params = try std.ArrayList(*pw.spa_pod).initCapacity(self.allocator, 0);
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

        const status = pw.pw_stream_connect(
            self.stream,
            pw.PW_DIRECTION_INPUT,
            node,
            pw.PW_STREAM_FLAG_AUTOCONNECT | pw.PW_STREAM_FLAG_MAP_BUFFERS,
            @ptrCast(params.items.ptr),
            @intCast(params.items.len),
        );

        if (status < 0) {
            return error.pw_stream_connect;
        }
    }

    fn streamProcessCallback(data: ?*anyopaque) callconv(.c) void {
        // log.debug("[streamProcessCallback]", .{});
        const self: *Self = @ptrCast(@alignCast(data));

        if (!self.has_format) {
            log.debug("[streamProcessCallback] does not have format", .{});
            return;
        }

        // Grab the newest buffer.
        var pipewire_buffer: ?*pw.struct_pw_buffer = null;
        while (true) {
            const tmp: ?*pw.struct_pw_buffer = pw.pw_stream_dequeue_buffer(self.stream);

            if (tmp == null) {
                break;
            }

            // Only keep buffers that are dmabuf.
            if (tmp.?.buffer == null or tmp.?.buffer[0].datas[0].type != pw.SPA_DATA_DmaBuf) {
                _ = pw.pw_stream_queue_buffer(self.stream.?, tmp.?);
                continue;
            }

            if (pipewire_buffer) |pwb| {
                _ = pw.pw_stream_queue_buffer(self.stream.?, pwb);
            }

            pipewire_buffer = tmp;
        }

        const pwb = pipewire_buffer.?;

        // TODO: Should gracefully handle these errors.
        defer _ = pw.pw_stream_queue_buffer(self.stream.?, pwb);

        const vulkan_image = self.pipewire_frame_buffer_manager.?.getVulkanImage(pwb, self.info.?) catch |err| {
            log.err("[streamProcessCallback] unable to get buffer: {}", .{err});
            unreachable;
        };

        const header = pw.spa_buffer_find_meta_data(pwb.buffer, pw.SPA_META_Header, @sizeOf(pw.spa_meta_header));
        if (header == null) {
            log.err("[streamProcessCallback] unable to get metadata header. This should never happen.", .{});
            return;
        }
        const metadata = @as(*pw.spa_meta_header, @ptrCast(@alignCast(header.?)));
        var timestamp_ns: i128 = @intCast(metadata.pts);

        // Pipewire can occasionally queue a buffer with the same timestamp as the previous
        // frame. In this case, increment it by one. We can't have multiple frames with
        // the same pts.
        if (self.previous_frame_timestamp_ns) |previous| {
            if (timestamp_ns <= previous) {
                timestamp_ns = timestamp_ns + 1;
            }
        }
        self.previous_frame_timestamp_ns = timestamp_ns;

        const copy_data = blk: {
            const capture_ring_buffer = self.vulkan.capture_ring_buffer.lock();
            defer capture_ring_buffer.unlock();
            break :blk capture_ring_buffer.unwrap().?.copyImageToRingBuffer(.{
                .src_image = vulkan_image.frame_buffer.frame_buffer_image.?.image,
                .src_width = self.info.?.size.width,
                .src_height = self.info.?.size.height,
                .wait_semaphore = vulkan_image.wait_semaphore,
                .use_signal_semaphore = false,
                .timestamp_ns = timestamp_ns,
            }) catch |err| {
                log.err("[streamProcessCallback] copyImageToRingBuffer error: {}", .{err});
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
        old_state: pw.pw_stream_state,
        new_state: pw.pw_stream_state,
        error_: [*c]const u8,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        _ = self;

        log.debug("[streamStateChangedCallback] pipewire stream state change: {s} -> {s}", .{
            pw.pw_stream_state_as_string(old_state),
            pw.pw_stream_state_as_string(new_state),
        });

        if (new_state == pw.PW_STREAM_STATE_ERROR) {
            log.debug("[streamStateChangedCallback] pipewire stream error: {s}", .{error_});
        }

        if (new_state == pw.PW_STREAM_STATE_STREAMING) {
            log.debug("[streamStateChangedCallback] pipewire state streaming", .{});
        }
    }

    fn streamParamChangedCallback(data: ?*anyopaque, id: u32, param: [*c]const pw.spa_pod) callconv(.c) void {
        log.debug("[streamParamChangedCallback]", .{});

        const self: *Self = @ptrCast(@alignCast(data));

        if (param == null or id != pw.SPA_PARAM_Format) {
            return;
        }

        var media_type: u32 = undefined;
        var media_subtype: u32 = undefined;

        const fmt = c_def.spa_format_parse(param, &media_type, &media_subtype);

        if (fmt < 0 or
            media_type != pw.SPA_MEDIA_TYPE_video or
            media_subtype != pw.SPA_MEDIA_SUBTYPE_raw)
        {
            log.debug("[streamParamChangedCallback] media_type: {}, media_subtype: {}", .{ media_type, media_subtype });
            return;
        }

        self.info = std.mem.zeroes(pw.spa_video_info_raw);

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

        pw.pw_thread_loop_signal(self.thread_loop, false);
    }

    fn sendStreamParams(self: *Self) void {
        var buffer = std.mem.zeroes([1024]u8);

        var builder = pw.spa_pod_builder{
            .data = @ptrCast(&buffer),
            .size = 1024,
        };

        var params = std.ArrayList(*pw.struct_spa_pod).initCapacity(self.allocator, 0) catch unreachable;
        defer params.deinit(self.allocator);

        // This allows us to get the frame timestamp.
        params.append(self.allocator, @ptrCast(@alignCast(c_def.spa_pod_builder_add_object(
            &builder,
            pw.SPA_TYPE_OBJECT_ParamMeta,
            pw.SPA_PARAM_Meta,
            .{
                pw.SPA_PARAM_META_type,
                "I",
                @as(i32, pw.SPA_META_Header),
                pw.SPA_PARAM_META_size,
                "i",
                @as(i32, @intCast(@sizeOf(pw.spa_meta_header))),
            },
        )))) catch unreachable;

        // damage
        params.append(self.allocator, @ptrCast(@alignCast(c_def.spa_pod_builder_add_object(
            &builder,
            pw.SPA_TYPE_OBJECT_ParamMeta,
            pw.SPA_PARAM_Meta,
            .{
                pw.SPA_PARAM_META_type,
                "I",
                pw.SPA_META_VideoDamage,
                pw.SPA_PARAM_META_size,
                "?ri",
                @as(i32, 3),
                @as(i32, @sizeOf(pw.spa_meta_region) * 16),
                @as(i32, @sizeOf(pw.spa_meta_region) * 1),
                @as(i32, @sizeOf(pw.spa_meta_region) * 16),
            },
        )))) catch unreachable;

        // cursor
        params.append(self.allocator, @ptrCast(@alignCast(c_def.spa_pod_builder_add_object(
            &builder,
            pw.SPA_TYPE_OBJECT_ParamMeta,
            pw.SPA_PARAM_Meta,
            .{
                pw.SPA_PARAM_META_type,
                "I",
                pw.SPA_META_Cursor,
                pw.SPA_PARAM_META_size,
                "?ri",
                @as(i32, 3),
                @as(i32, @sizeOf(pw.spa_meta_cursor) + @sizeOf(pw.spa_meta_bitmap) + 64 + 64 * 4),
                @as(i32, @sizeOf(pw.spa_meta_cursor) + @sizeOf(pw.spa_meta_bitmap) + 1 + 1 * 4),
                @as(i32, @sizeOf(pw.spa_meta_cursor) + @sizeOf(pw.spa_meta_bitmap) + 1024 + 1024 * 4),
            },
        )))) catch unreachable;

        params.append(self.allocator, @ptrCast(@alignCast(c_def.spa_pod_builder_add_object(&builder, pw.SPA_TYPE_OBJECT_ParamBuffers, pw.SPA_PARAM_Buffers, .{
            pw.SPA_PARAM_BUFFERS_dataType,
            "i",
            @as(i32, 1 << pw.SPA_DATA_DmaBuf),
        })))) catch unreachable;

        _ = pw.pw_stream_update_params(self.stream, @ptrCast(params.items.ptr), @intCast(params.items.len));
    }

    fn streamAddBufferCallback(data: ?*anyopaque, pwb: [*c]pw.struct_pw_buffer) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        log.debug("[streamAddBufferCallback]", .{});

        self.pipewire_frame_buffer_manager.?.addPipewireBuffer(pwb) catch |err| {
            log.err("[streamAddBufferCallback] failed to add to active_buffers: {}", .{err});
        };
    }

    fn streamRemoveBufferCallback(data: ?*anyopaque, pwb: [*c]pw.struct_pw_buffer) callconv(.c) void {
        log.debug("[streamRemoveBufferCallback]", .{});
        const self: *Self = @ptrCast(@alignCast(data));

        self.pipewire_frame_buffer_manager.?.removePipewireBuffer(pwb);
    }

    const stream_events = pw.pw_stream_events{
        .version = pw.PW_VERSION_STREAM_EVENTS,
        .process = streamProcessCallback,
        .state_changed = streamStateChangedCallback,
        .param_changed = streamParamChangedCallback,
        .add_buffer = streamAddBufferCallback,
        .remove_buffer = streamRemoveBufferCallback,
    };

    const core_events = pw.pw_core_events{
        .version = pw.PW_VERSION_CORE_EVENTS,
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
