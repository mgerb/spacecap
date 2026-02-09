const std = @import("std");
const assert = std.debug.assert;
const AudioCaptureBufferedChan = @import("../audio_capture.zig").AudioCaptureBufferedChan;
const SAMPLE_RATE = @import("../audio_capture.zig").SAMPLE_RATE;
const CHANNELS = @import("../audio_capture.zig").CHANNELS;
const AudioDeviceType = @import("../audio_capture.zig").AudioDeviceType;
const SelectedAudioDevice = @import("../audio_capture.zig").SelectedAudioDevice;
const AudioCaptureData = @import("../audio_capture_data.zig");
const ChanError = @import("../../../channel.zig").ChanError;
const pipewire_include = @import("../../../common/linux/pipewire_include.zig");
const pw = @import("pipewire").c;
const c = pipewire_include.c;
const c_def = pipewire_include.c_def;

const AudioStream = struct {
    id: []u8,
    stream: ?*pw.pw_stream = null,
    device_type: AudioDeviceType,
    raw: pw.struct_spa_audio_info_raw = .{},
    pipewire_audio: *PipewireAudio,
};

pub const PipewireAudio = struct {
    const log = std.log.scoped(.PipewireAudio);
    const Self = @This();
    allocator: std.mem.Allocator,
    data_chan: AudioCaptureBufferedChan,
    thread_loop: ?*pw.pw_thread_loop = null,
    streams: std.ArrayList(*AudioStream),

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .data_chan = try .init(allocator),
            .streams = try std.ArrayList(*AudioStream).initCapacity(allocator, 0),
        };
        errdefer {
            self.streams.deinit(allocator);
            self.data_chan.deinit();
        }

        try self.initPipewire();

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.thread_loop) |thread_loop| {
            pw.pw_thread_loop_stop(thread_loop);
            pw.pw_thread_loop_lock(thread_loop);
            self.clearStreams();
            pw.pw_thread_loop_unlock(thread_loop);
        } else {
            self.clearStreams();
        }

        if (self.thread_loop) |thread_loop| {
            pw.pw_thread_loop_destroy(thread_loop);
        }

        self.data_chan.close(.{ .drain = true });
        self.data_chan.deinit();
        self.streams.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn initPipewire(self: *Self) !void {
        self.thread_loop = pw.pw_thread_loop_new(
            "spacecap-pipewire-capture-audio",
            null,
        ) orelse return error.pw_main_loop_new;
        errdefer pw.pw_thread_loop_destroy(self.thread_loop);

        if (pw.pw_thread_loop_start(self.thread_loop) < 0) {
            return error.pw_thread_loop_start;
        }
    }

    pub fn updateSelectedDevices(self: *Self, selected_devices: []const SelectedAudioDevice) !void {
        const thread_loop = self.thread_loop orelse return error.pw_thread_loop_not_initialized;

        pw.pw_thread_loop_lock(thread_loop);
        defer pw.pw_thread_loop_unlock(thread_loop);

        self.clearStreams();
        errdefer self.clearStreams();

        for (selected_devices) |selected_device| {
            try self.createStream(selected_device);
        }
    }

    fn clearStreams(self: *Self) void {
        for (self.streams.items) |stream_data| {
            if (stream_data.stream) |stream| {
                _ = pw.pw_stream_disconnect(stream);
                pw.pw_stream_destroy(stream);
            }
            self.allocator.free(stream_data.id);
            self.allocator.destroy(stream_data);
        }
        self.streams.clearRetainingCapacity();
    }

    fn createStream(self: *Self, selected_device: SelectedAudioDevice) !void {
        const stream_data = try self.allocator.create(AudioStream);
        errdefer self.allocator.destroy(stream_data);

        stream_data.* = .{
            .id = try self.allocator.dupe(u8, selected_device.id),
            .device_type = selected_device.device_type,
            .pipewire_audio = self,
        };
        errdefer self.allocator.free(stream_data.id);

        const props = pw.pw_properties_new(
            pw.PW_KEY_MEDIA_TYPE,
            "Audio",
            pw.PW_KEY_MEDIA_CATEGORY,
            "Capture",
            pw.PW_KEY_MEDIA_ROLE,
            "Music",
            pw.NULL,
        ) orelse return error.pw_properties_new;
        if (selected_device.device_type == .sink) {
            _ = pw.pw_properties_set(props, pw.PW_KEY_STREAM_CAPTURE_SINK, "true");
        }
        const target_object = try self.allocator.dupeZ(u8, selected_device.id);
        defer self.allocator.free(target_object);
        _ = pw.pw_properties_set(props, pw.PW_KEY_TARGET_OBJECT, target_object);

        const stream_events = pw.pw_stream_events{
            .version = pw.PW_VERSION_STREAM_EVENTS,
            .param_changed = streamParamChangedCallback,
            .process = streamProcessCallback,
        };

        const stream_name = switch (selected_device.device_type) {
            .source => "audio-capture-source",
            .sink => "audio-capture-sink",
        };
        stream_data.stream = pw.pw_stream_new_simple(
            pw.pw_thread_loop_get_loop(self.thread_loop),
            stream_name,
            props,
            &stream_events,
            stream_data,
        ) orelse return error.pw_stream_new;
        errdefer {
            if (stream_data.stream) |stream| {
                _ = pw.pw_stream_disconnect(stream);
                pw.pw_stream_destroy(stream);
                stream_data.stream = null;
            }
        }

        try connectStream(stream_data);
        try self.streams.append(self.allocator, stream_data);
    }

    fn streamProcessCallback(callback_data: ?*anyopaque) callconv(.c) void {
        assert(callback_data != null);
        const stream_data: *AudioStream = @ptrCast(@alignCast(callback_data));
        const self = stream_data.pipewire_audio;
        const stream = stream_data.stream orelse return;

        const pwb = pw.pw_stream_dequeue_buffer(stream);

        if (pwb == null) {
            log.debug("[streamProcessCallback] out of buffers to dequeue", .{});
            return;
        }

        defer _ = pw.pw_stream_queue_buffer(stream, pwb);

        const buffer = pwb.*.buffer orelse return;
        if (buffer.*.n_datas == 0) {
            return;
        }

        const data_ptr = buffer.*.datas[0].data orelse {
            log.warn("[streamProcessCallback] no data in buffer", .{});
            return;
        };

        const chunk = buffer.*.datas[0].chunk orelse return;
        const size: usize = @intCast(chunk.*.size);
        if (size < @sizeOf(f32)) {
            return;
        }

        const pcm_data: [*]const f32 = @ptrCast(@alignCast(data_ptr));

        const n_samples = size / @sizeOf(f32);
        if (n_samples == 0) {
            return;
        }

        const rate = stream_data.raw.rate;
        const channels = stream_data.raw.channels;

        // If this fails, then to my knowledge, there is an issue with pipewire.
        // The streamParamChangedCallback should always fire before the streamProcessCallback,
        // which sets these values.
        assert(rate > 0);
        assert(channels > 0);

        var audio_capture_data = AudioCaptureData.init(
            self.allocator,
            stream_data.id,
            pcm_data[0..n_samples],
            @intCast(pwb.*.time),
            rate,
            channels,
        ) catch |err| {
            log.err("[streamProcessCallback] error creating audio capture data: {}", .{err});
            return;
        };

        const did_send = self.data_chan.trySend(audio_capture_data) catch |err| {
            if (err == ChanError.Closed) {
                log.debug("[streamProcessCallback] chan closed", .{});
            } else {
                log.err("[streamProcessCallback] chan error: {}", .{err});
            }
            audio_capture_data.deinit();
            return;
        };

        if (!did_send) {
            audio_capture_data.deinit();
        }
    }

    fn streamParamChangedCallback(userdata: ?*anyopaque, id: u32, param: [*c]const pw.struct_spa_pod) callconv(.c) void {
        assert(userdata != null);
        const stream_data: *AudioStream = @ptrCast(@alignCast(userdata));

        if (param == null or id != pw.SPA_PARAM_Format) {
            return;
        }

        var media_type: u32 = 0;
        var media_subtype: u32 = 0;

        if (c_def.spa_format_parse(param, @ptrCast(&media_type), @ptrCast(&media_subtype)) < 0) {
            return;
        }

        if (media_type != pw.SPA_MEDIA_TYPE_audio or media_subtype != pw.SPA_MEDIA_SUBTYPE_raw) {
            return;
        }

        _ = c_def.spa_format_audio_raw_parse(param, &stream_data.raw);

        std.log.debug("[onStreamParamChanged] capturing rate: {}, channels: {}", .{
            stream_data.raw.rate,
            stream_data.raw.channels,
        });
    }

    fn connectStream(stream_data: *AudioStream) !void {
        var format_buffer = std.mem.zeroes([512]u8);
        var builder = pw.spa_pod_builder{
            .data = @ptrCast(&format_buffer),
            .size = format_buffer.len,
        };
        const format = c_def.spa_pod_builder_add_object(
            &builder,
            pw.SPA_TYPE_OBJECT_Format,
            pw.SPA_PARAM_EnumFormat,
            .{
                pw.SPA_FORMAT_mediaType,
                "I",
                @as(i32, pw.SPA_MEDIA_TYPE_audio),
                pw.SPA_FORMAT_mediaSubtype,
                "I",
                @as(i32, pw.SPA_MEDIA_SUBTYPE_raw),
                pw.SPA_FORMAT_AUDIO_format,
                "I",
                @as(i32, pw.SPA_AUDIO_FORMAT_F32),
                pw.SPA_FORMAT_AUDIO_rate,
                "i",
                @as(i32, SAMPLE_RATE),
                pw.SPA_FORMAT_AUDIO_channels,
                "i",
                @as(i32, CHANNELS),
            },
        ) orelse return error.pw_format_build;

        // Metadata is required to get the buffer timestamp.
        var meta_buffer = std.mem.zeroes([512]u8);
        var meta_builder = pw.spa_pod_builder{
            .data = @ptrCast(&meta_buffer),
            .size = meta_buffer.len,
        };
        const meta = c_def.spa_pod_builder_add_object(
            &meta_builder,
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
        ) orelse return error.pw_meta_build;

        var params = [_]*pw.struct_spa_pod{
            @ptrCast(@alignCast(format)),
            @ptrCast(@alignCast(meta)),
        };

        const status = pw.pw_stream_connect(
            stream_data.stream,
            pw.PW_DIRECTION_INPUT,
            pw.PW_ID_ANY,
            pw.PW_STREAM_FLAG_AUTOCONNECT |
                pw.PW_STREAM_FLAG_MAP_BUFFERS |
                pw.PW_STREAM_FLAG_RT_PROCESS,
            @ptrCast(params[0..].ptr),
            @intCast(params.len),
        );
        if (status < 0) {
            return error.pw_stream_connect;
        }
    }
};
