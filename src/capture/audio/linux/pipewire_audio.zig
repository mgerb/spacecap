const std = @import("std");
const assert = std.debug.assert;
const AudioCaptureBufferedChan = @import("../audio_capture.zig").AudioCaptureBufferedChan;
const AudioCaptureData = @import("../audio_capture.zig").AudioCaptureData;
const ChanError = @import("../../../channel.zig").ChanError;
const pipewire_include = @import("../../../common/linux/pipewire_include.zig");
const c = pipewire_include.c;
const c_def = pipewire_include.c_def;

const SAMPLE_RATE: u32 = 48_000;
const CHANNELS: u32 = 2;

const StreamType = enum {
    mic,
    sink,
};

const AudioStream = struct {
    id: []const u8,
    stream: ?*c.pw_stream = null,
    stream_type: StreamType,
    format: c.spa_audio_info = .{},
    pipewire_audio: *PipewireAudio,
};

const CallbackData = struct {
    pipewire_audio: *PipewireAudio,
    audio_stream: *AudioStream,
};

pub const PipewireAudio = struct {
    const log = std.log.scoped(.PipewireAudio);
    const Self = @This();
    allocator: std.mem.Allocator,
    data_chan: AudioCaptureBufferedChan,
    thread_loop: ?*c.pw_thread_loop = null,

    // TODO: Make streams a dynamic list provided by the consumer.
    /// Microphone.
    mic_stream: ?AudioStream = null,
    /// Speakers.
    sink_stream: ?AudioStream = null,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);

        self.* = .{
            .allocator = allocator,
            .data_chan = try .init(allocator),
        };

        self.mic_stream = .{
            .id = "mic",
            .stream_type = .mic,
            .pipewire_audio = self,
        };

        self.sink_stream = .{
            .id = "sink",
            .stream_type = .sink,
            .pipewire_audio = self,
        };

        try self.initPipewire();

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.thread_loop) |thread_loop| {
            c.pw_thread_loop_stop(thread_loop);
        }

        if (self.mic_stream) |mic_stream| {
            _ = c.pw_stream_disconnect(mic_stream.stream);
            c.pw_stream_destroy(mic_stream.stream);
        }

        if (self.sink_stream) |sink_stream| {
            _ = c.pw_stream_disconnect(sink_stream.stream);
            c.pw_stream_destroy(sink_stream.stream);
        }

        if (self.thread_loop) |thread_loop| {
            c.pw_thread_loop_destroy(thread_loop);
        }

        self.data_chan.close(.{ .drain = true });
        self.data_chan.deinit();
        self.allocator.destroy(self);
    }

    fn initPipewire(self: *Self) !void {
        self.thread_loop = c.pw_thread_loop_new(
            "spacecap-pipewire-capture-audio",
            null,
        ) orelse return error.pw_main_loop_new;
        errdefer c.pw_thread_loop_destroy(self.thread_loop);

        // TODO: Mic/sink input. Default for now.
        const mic_name = "alsa_input.pci-0000_00_1f.3.analog-stereo";
        const sink_name = "alsa_output.pci-0000_00_1f.3.analog-stereo";

        const mic_props = c.pw_properties_new(
            c.PW_KEY_MEDIA_TYPE,
            "Audio",
            c.PW_KEY_MEDIA_CATEGORY,
            "Capture",
            c.PW_KEY_MEDIA_ROLE,
            "Music",
            c.NULL,
        ) orelse return error.pw_properties_new;
        const mic_z = try self.allocator.dupeZ(u8, mic_name);
        defer self.allocator.free(mic_z);
        _ = c.pw_properties_set(mic_props, c.PW_KEY_TARGET_OBJECT, mic_z);

        const sink_props = c.pw_properties_new(
            c.PW_KEY_MEDIA_TYPE,
            "Audio",
            c.PW_KEY_MEDIA_CATEGORY,
            "Capture",
            c.PW_KEY_MEDIA_ROLE,
            "Music",
            c.NULL,
        ) orelse return error.pw_properties_new;
        _ = c.pw_properties_set(sink_props, c.PW_KEY_STREAM_CAPTURE_SINK, "true");
        const sink_z = try self.allocator.dupeZ(u8, sink_name);
        defer self.allocator.free(sink_z);
        _ = c.pw_properties_set(sink_props, c.PW_KEY_TARGET_OBJECT, sink_z);

        const stream_events = c.pw_stream_events{
            .version = c.PW_VERSION_STREAM_EVENTS,
            .param_changed = streamParamChangedCallback,
            .process = streamProcessCallback,
        };

        self.mic_stream.?.stream = c.pw_stream_new_simple(
            c.pw_thread_loop_get_loop(self.thread_loop),
            "audio-capture-mic",
            mic_props,
            &stream_events,
            &self.mic_stream.?,
        ) orelse return error.pw_stream_new_mic;
        errdefer c.pw_stream_destroy(self.mic_stream.?.stream);

        self.sink_stream.?.stream = c.pw_stream_new_simple(
            c.pw_thread_loop_get_loop(self.thread_loop),
            "audio-capture-sink",
            sink_props,
            &stream_events,
            &self.sink_stream.?,
        ) orelse return error.pw_stream_new;
        errdefer c.pw_stream_destroy(self.sink_stream.?.stream);

        try connectStream(&self.mic_stream.?);
        try connectStream(&self.sink_stream.?);

        if (c.pw_thread_loop_start(self.thread_loop) < 0) {
            return error.pw_thread_loop_start;
        }
    }

    fn streamProcessCallback(callback_data: ?*anyopaque) callconv(.c) void {
        assert(callback_data != null);
        const stream_data: *AudioStream = @ptrCast(@alignCast(callback_data));
        const self = stream_data.pipewire_audio;
        const stream = stream_data.stream orelse return;

        const pwb = c.pw_stream_dequeue_buffer(stream);

        if (pwb == null) {
            log.debug("[streamProcessCallback] out of buffers to dequeue", .{});
            return;
        }

        defer _ = c.pw_stream_queue_buffer(stream, pwb);

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

        // const n_channels = stream_data.format.info.raw.channels;
        const n_samples = size / @sizeOf(f32);
        if (n_samples == 0) {
            return;
        }

        var audio_capture_data = AudioCaptureData.init(self.allocator, stream_data.id, pcm_data[0..n_samples]) catch |err| {
            log.err("[streamProcessCallback] error creating audio capture data: {}", .{err});
            return;
        };

        self.data_chan.trySend(audio_capture_data) catch |err| {
            if (err == ChanError.Closed) {
                log.debug("[streamProcessCallback] chan closed", .{});
            } else {
                log.err("[streamProcessCallback] chan error: {}", .{err});
            }
            audio_capture_data.deinit();
            return;
        };
    }

    fn streamParamChangedCallback(userdata: ?*anyopaque, id: u32, param: [*c]const c.struct_spa_pod) callconv(.c) void {
        assert(userdata != null);
        const stream_data: *AudioStream = @ptrCast(@alignCast(userdata));

        if (param == null or id != c.SPA_PARAM_Format) {
            return;
        }

        var media_type: u32 = 0;
        var media_subtype: u32 = 0;

        if (c_def.spa_format_parse(param, @ptrCast(&media_type), @ptrCast(&media_subtype)) < 0) {
            return;
        }

        if (media_type != c.SPA_MEDIA_TYPE_audio or media_subtype != c.SPA_MEDIA_SUBTYPE_raw) {
            return;
        }

        _ = c_def.spa_format_audio_raw_parse(param, &stream_data.format.info.raw);

        std.log.debug("[onStreamParamChanged] capturing rate: {}, channels: {}", .{
            stream_data.format.info.raw.rate,
            stream_data.format.info.raw.channels,
        });
    }

    fn connectStream(stream_data: *AudioStream) !void {
        var format_buffer = std.mem.zeroes([256]u8);
        var builder = c.spa_pod_builder{
            .data = @ptrCast(&format_buffer),
            .size = format_buffer.len,
        };

        const format = c_def.spa_pod_builder_add_object(
            &builder,
            c.SPA_TYPE_OBJECT_Format,
            c.SPA_PARAM_EnumFormat,
            .{
                c.SPA_FORMAT_mediaType,
                "I",
                @as(i32, c.SPA_MEDIA_TYPE_audio),
                c.SPA_FORMAT_mediaSubtype,
                "I",
                @as(i32, c.SPA_MEDIA_SUBTYPE_raw),
                c.SPA_FORMAT_AUDIO_format,
                "I",
                @as(i32, c.SPA_AUDIO_FORMAT_F32),
                c.SPA_FORMAT_AUDIO_rate,
                "i",
                @as(i32, SAMPLE_RATE),
                c.SPA_FORMAT_AUDIO_channels,
                "i",
                @as(i32, CHANNELS),
            },
        ) orelse return error.pw_format_build;

        var params = [_]*c.struct_spa_pod{@ptrCast(@alignCast(format))};
        const status = c.pw_stream_connect(
            stream_data.stream,
            c.PW_DIRECTION_INPUT,
            c.PW_ID_ANY,
            c.PW_STREAM_FLAG_AUTOCONNECT |
                c.PW_STREAM_FLAG_MAP_BUFFERS |
                c.PW_STREAM_FLAG_RT_PROCESS,
            @ptrCast(params[0..].ptr),
            @intCast(params.len),
        );

        if (status < 0) {
            return error.pw_stream_connect;
        }
    }
};
