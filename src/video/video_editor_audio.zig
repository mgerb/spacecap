const std = @import("std");
const c = @import("ffmpeg_c");
const imguiz = @import("imguiz").imguiz;

const AudioDecoder = @import("../ffmpeg/audio_decoder.zig").AudioDecoder;
const Demuxer = @import("../ffmpeg/demuxer.zig").Demuxer;
const ffmpeg_util = @import("../ffmpeg/util.zig");

pub const VideoEditorAudio = struct {
    const Self = @This();
    const max_queued_duration_ns = 500 * std.time.ns_per_ms;

    demuxer: Demuxer,
    decoder: AudioDecoder,
    time_base: c.AVRational,
    stream: ?*imguiz.SDL_AudioStream = null,
    input_spec: ?imguiz.SDL_AudioSpec = null,
    finished: bool = false,
    flushed: bool = false,

    pub fn init(allocator: std.mem.Allocator, file_path: []const u8) !?Self {
        var demuxer = try Demuxer.init(allocator, file_path);
        errdefer demuxer.deinit();

        const codec_parameters = demuxer.audio_codec_parameters() orelse {
            demuxer.deinit();
            return null;
        };

        var decoder = try AudioDecoder.init(codec_parameters);
        errdefer decoder.deinit();

        return .{
            .demuxer = demuxer,
            .decoder = decoder,
            .time_base = demuxer.audio_time_base().?,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.stream) |stream| {
            imguiz.SDL_DestroyAudioStream(stream);
        }
        self.decoder.deinit();
        self.demuxer.deinit();
    }

    /// Decode and queue audio until the stream buffer is full. When
    /// first_video_frame_pts_ns is provided, it means that the stream is currently
    /// not playing and should start playback. Returns the shared audio/video
    /// timeline origin. If there is a gap between the origin and the audio
    /// start, then queue up silence to fill the gap.
    pub fn fill_and_start_if_stopped(self: *Self, first_video_frame_pts_ns: ?i64) !?i64 {
        var pending_video_pts_ns = first_video_frame_pts_ns;
        var timeline_origin_ns = first_video_frame_pts_ns;
        var should_resume = false;

        while (!self.finished) {
            if (pending_video_pts_ns == null and try self.queue_is_full()) {
                break;
            }

            const frame = try self.demux_and_decode_frame() orelse {
                // If null then there are no frames left to decode.
                try self.finish_stream();
                break;
            };

            // If any stream params change account for that here.
            try self.ensure_stream(frame);

            if (pending_video_pts_ns) |video_pts_ns| {
                const audio_pts_ns = ffmpeg_util.frame_pts_ns(frame, self.time_base) catch video_pts_ns;
                const origin_ns = @min(video_pts_ns, audio_pts_ns);
                timeline_origin_ns = origin_ns;

                // Queueing silence is simpler than synchronizing start times.
                try self.queue_silence(audio_pts_ns - origin_ns);

                pending_video_pts_ns = null;
                should_resume = true;
            }

            try self.queue_frame_data(frame);
        }

        if (should_resume) {
            if (self.stream) |stream| {
                if (!imguiz.SDL_ResumeAudioStreamDevice(stream)) {
                    return error.SDLAudioResumeFailure;
                }
            }
        }

        return timeline_origin_ns;
    }

    /// Seek the demuxer audio to a timestamp_ns.
    pub fn seek(self: *Self, args: struct {
        timestamp_ns: i64,
        seek_before: bool = false,
    }) !void {
        try self.demuxer.seek_audio(.{
            .timestamp_ns = args.timestamp_ns,
            .seek_before = args.seek_before,
        });
        self.decoder.flush();
        if (self.stream) |stream| {
            if (!imguiz.SDL_ClearAudioStream(stream)) {
                return error.SDLAudioClearFailure;
            }
        }
        self.finished = false;
        self.flushed = false;
    }

    pub fn pause(self: *Self) !void {
        const stream = self.stream orelse return;
        if (!imguiz.SDL_PauseAudioStreamDevice(stream)) {
            return error.SDLAudioPauseFailure;
        }
    }

    pub fn queued_bytes(self: *Self) !usize {
        const stream = self.stream orelse return 0;
        const queued = imguiz.SDL_GetAudioStreamQueued(stream);
        if (queued < 0) {
            return error.SDLAudioQueueFailure;
        }
        return @intCast(queued);
    }

    /// We can only queue up so many audio bytes at a time.
    fn queue_is_full(self: *const Self) !bool {
        const stream = self.stream orelse return false;
        const queued = imguiz.SDL_GetAudioStreamQueued(stream);
        if (queued < 0) {
            return error.SDLAudioQueueFailure;
        }
        return queued >= try self.max_queued_bytes();
    }

    fn finish_stream(self: *Self) !void {
        self.finished = true;
        if (self.flushed) {
            return;
        }

        const stream = self.stream orelse return;
        if (!imguiz.SDL_FlushAudioStream(stream)) {
            return error.SDLAudioFlushFailure;
        }
        self.flushed = true;
    }

    /// Decode until a frame has been filled. Returns null when there are no
    /// frames left.
    fn demux_and_decode_frame(self: *Self) !?*const c.AVFrame {
        while (true) {
            return self.decoder.decode_frame() catch |err| switch (err) {
                error.NeedsPacket => {
                    const packet = try self.demuxer.next_audio_packet();
                    try self.decoder.send_packet(if (packet) |value| value else null);
                    continue;
                },
                else => return err,
            };
        }
    }

    /// Ensure the SDL audio stream exists and accepts the decoded frame's
    /// format. Opens the stream initially and reconfigures it when the sample
    /// format, channel count, or sample rate changes. It's not common, but an
    /// audio stream could change this mid flight, so this should be called
    /// when decoding/playing audio.
    fn ensure_stream(self: *Self, frame: *const c.AVFrame) !void {
        const spec = try ffmpeg_util.frame_to_sdl_audio_spec(frame);
        if (self.stream == null) {
            self.stream = imguiz.SDL_OpenAudioDeviceStream(
                imguiz.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
                &spec,
                null,
                null,
            ) orelse return error.SDLAudioOpenFailure;
            self.input_spec = spec;
            return;
        }

        const current_spec = self.input_spec.?;
        if (current_spec.format == spec.format and
            current_spec.channels == spec.channels and
            current_spec.freq == spec.freq)
        {
            return;
        }

        if (!imguiz.SDL_SetAudioStreamFormat(self.stream, &spec, null)) {
            return error.SDLAudioFormatFailure;
        }
        self.input_spec = spec;
    }

    fn queue_frame_data(self: *Self, frame: *const c.AVFrame) !void {
        const stream = self.stream.?;
        const sample_format: c.enum_AVSampleFormat = frame.*.format;
        const channel_count = frame.*.ch_layout.nb_channels;

        if (c.av_sample_fmt_is_planar(sample_format) != 0) {
            const channel_buffers: [*c]const ?*const anyopaque = @ptrCast(frame.*.extended_data);
            if (!imguiz.SDL_PutAudioStreamPlanarData(
                stream,
                channel_buffers,
                channel_count,
                frame.*.nb_samples,
            )) return error.SDLAudioQueueFailure;
            return;
        }

        const bytes_per_sample = c.av_get_bytes_per_sample(sample_format);
        const byte_count = frame.*.nb_samples * channel_count * bytes_per_sample;
        if (byte_count <= 0 or byte_count > std.math.maxInt(c_int)) {
            return error.InvalidAudioFrame;
        }
        if (!imguiz.SDL_PutAudioStreamData(stream, frame.*.extended_data[0], @intCast(byte_count))) {
            return error.SDLAudioQueueFailure;
        }
    }

    fn queue_silence(self: *Self, duration_ns: i64) !void {
        const spec = self.input_spec orelse return;
        const bytes_per_sample = audio_format_bytes(spec.format);
        const bytes_per_frame: usize = @intCast(bytes_per_sample * spec.channels);
        const sample_count: usize = @intCast(@divFloor(
            duration_ns * spec.freq,
            std.time.ns_per_s,
        ));

        if (sample_count == 0) {
            return;
        }

        var zeroes = std.mem.zeroes([4096]u8);
        const samples_per_chunk = zeroes.len / bytes_per_frame;
        var remaining_samples = sample_count;
        while (remaining_samples > 0) {
            const chunk_samples = @min(remaining_samples, samples_per_chunk);
            const chunk_bytes = chunk_samples * bytes_per_frame;
            if (!imguiz.SDL_PutAudioStreamData(self.stream, &zeroes, @intCast(chunk_bytes))) {
                return error.SDLAudioQueueFailure;
            }
            remaining_samples -= chunk_samples;
        }
    }

    fn max_queued_bytes(self: *const Self) !c_int {
        const spec = self.input_spec orelse return 0;
        const bytes_per_sample = audio_format_bytes(spec.format);
        const bytes_per_second = @as(i64, spec.freq) * spec.channels * bytes_per_sample;
        return @intCast(@divFloor(bytes_per_second * max_queued_duration_ns, std.time.ns_per_s));
    }

    fn audio_format_bytes(format: imguiz.SDL_AudioFormat) c_int {
        return switch (format) {
            imguiz.SDL_AUDIO_U8 => 1,
            imguiz.SDL_AUDIO_S16 => 2,
            imguiz.SDL_AUDIO_S32, imguiz.SDL_AUDIO_F32 => 4,
            else => @panic("[audio_format_bytes] unsupported SDL audio format"),
        };
    }
};
