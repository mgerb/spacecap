const std = @import("std");
const Allocator = std.mem.Allocator;
const ffmpeg = @import("./ffmpeg.zig").ffmpeg;
const checkErr = @import("./ffmpeg.zig").checkErr;

pub const AudioEncodeResult = struct {
    const Self = @This();
    allocator: Allocator,
    packets: std.ArrayList([*c]ffmpeg.AVPacket),

    pub fn init(allocator: Allocator) !Self {
        return .{
            .allocator = allocator,
            .packets = try .initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.packets.items) |*item| {
            const i: [*c][*c]ffmpeg.struct_AVPacket = item;
            ffmpeg.av_packet_free(i);
        }
        self.packets.deinit(self.allocator);
    }

    pub fn append(self: *Self, item: [*c]ffmpeg.AVPacket) !void {
        try self.packets.append(self.allocator, item);
    }
};

/// Encode audio with ffmpeg. Only aac supported currently.
pub const AudioEncoder = struct {
    const Self = @This();
    allocator: Allocator,
    audio_codec_ctx: [*c]ffmpeg.AVCodecContext,
    audio_stream: [*c]ffmpeg.AVStream,
    channels: u32,

    pub fn init(
        allocator: Allocator,
        sample_rate: u32,
        channels: u32,
        format_context: *ffmpeg.AVFormatContext,
    ) !Self {
        const audio_codec = ffmpeg.avcodec_find_encoder(ffmpeg.AV_CODEC_ID_AAC) orelse return error.MissingAudioEncoder;
        const audio_codec_ctx = ffmpeg.avcodec_alloc_context3(audio_codec) orelse return error.FFmpegError;

        audio_codec_ctx.*.sample_rate = @intCast(sample_rate);
        _ = ffmpeg.av_channel_layout_default(&audio_codec_ctx.*.ch_layout, @intCast(channels));
        audio_codec_ctx.*.time_base = ffmpeg.AVRational{ .num = 1, .den = @intCast(sample_rate) };
        audio_codec_ctx.*.bit_rate = 320_000;

        var chosen_fmt: ffmpeg.AVSampleFormat = ffmpeg.AV_SAMPLE_FMT_NONE;
        if (audio_codec.*.sample_fmts != null) {
            var fmt_ptr = audio_codec.*.sample_fmts;
            while (fmt_ptr[0] != ffmpeg.AV_SAMPLE_FMT_NONE) : (fmt_ptr += 1) {
                if (fmt_ptr[0] == ffmpeg.AV_SAMPLE_FMT_FLTP) {
                    chosen_fmt = ffmpeg.AV_SAMPLE_FMT_FLTP;
                    break;
                }
                if (fmt_ptr[0] == ffmpeg.AV_SAMPLE_FMT_FLT and chosen_fmt == ffmpeg.AV_SAMPLE_FMT_NONE) {
                    chosen_fmt = ffmpeg.AV_SAMPLE_FMT_FLT;
                }
            }
        } else {
            chosen_fmt = ffmpeg.AV_SAMPLE_FMT_FLTP;
        }

        if (chosen_fmt == ffmpeg.AV_SAMPLE_FMT_NONE) return error.UnsupportedAudioSampleFormat;
        audio_codec_ctx.*.sample_fmt = chosen_fmt;
        audio_codec_ctx.*.profile = ffmpeg.FF_PROFILE_AAC_LOW;

        if (format_context.oformat.*.flags & ffmpeg.AVFMT_GLOBALHEADER != 0) {
            audio_codec_ctx.*.flags |= ffmpeg.AV_CODEC_FLAG_GLOBAL_HEADER;
        }

        _ = ffmpeg.av_opt_set_int(audio_codec_ctx.*.priv_data, "aac_pns", 0, 0);
        _ = ffmpeg.av_opt_set_int(audio_codec_ctx.*.priv_data, "vbr", 4, 0);

        // Open the encoder before attaching it to the stream.
        var ret = ffmpeg.avcodec_open2(audio_codec_ctx, audio_codec, null);
        try checkErr(ret);

        const audio_stream = ffmpeg.avformat_new_stream(format_context, null) orelse return error.FFmpegError;

        ret = ffmpeg.avcodec_parameters_from_context(audio_stream.*.codecpar, audio_codec_ctx);
        try checkErr(ret);

        audio_stream.*.time_base = audio_codec_ctx.*.time_base;

        return .{
            .allocator = allocator,
            .audio_codec_ctx = audio_codec_ctx,
            .audio_stream = audio_stream,
            .channels = channels,
        };
    }

    pub fn deinit(self: *Self) void {
        ffmpeg.avcodec_free_context(&self.audio_codec_ctx);
    }

    pub fn encode(
        self: *Self,
        samples: []const f32,
    ) !AudioEncodeResult {
        var audio_packets: AudioEncodeResult = try .init(self.allocator);

        // Interpret interleaved f32 samples as frames for the encoder.
        const channels_usize: usize = @intCast(self.channels);
        const total_frames: usize = samples.len / channels_usize;
        if (total_frames == 0) return error.NoAudioSamples;

        // AAC prefers fixed frame sizes; pad the final frame if needed.
        const frame_size: usize = if (self.audio_codec_ctx.*.frame_size > 0)
            @intCast(self.audio_codec_ctx.*.frame_size)
        else
            1024;

        var frame = ffmpeg.av_frame_alloc() orelse return error.FFmpegError;
        defer ffmpeg.av_frame_free(&frame);

        frame.*.format = self.audio_codec_ctx.*.sample_fmt;
        frame.*.ch_layout = self.audio_codec_ctx.*.ch_layout;
        frame.*.sample_rate = self.audio_codec_ctx.*.sample_rate;
        frame.*.nb_samples = @intCast(frame_size);

        // Allocate backing buffers for the audio frame.
        var ret = ffmpeg.av_frame_get_buffer(frame, 0);
        try checkErr(ret);

        var audio_pkt = ffmpeg.av_packet_alloc() orelse return error.FFmpegError;
        defer ffmpeg.av_packet_free(&audio_pkt);

        const err_eagain = ffmpeg.AVERROR(ffmpeg.EAGAIN);
        const err_eof = ffmpeg.AVERROR_EOF;
        const audio_stream_idx = self.audio_stream.*.index;

        var sample_index: usize = 0;
        var next_audio_pts: i64 = 0;

        // Feed frames into the encoder in order, then drain any queued packets.
        while (sample_index < total_frames) {
            const remaining_frames = total_frames - sample_index;
            const nb_samples = if (remaining_frames >= frame_size) frame_size else remaining_frames;

            frame.*.nb_samples = @intCast(nb_samples);
            ret = ffmpeg.av_frame_make_writable(frame);
            try checkErr(ret);

            // Fill the encoder frame in the expected sample format.
            if (self.audio_codec_ctx.*.sample_fmt == ffmpeg.AV_SAMPLE_FMT_FLTP) {
                var ch: usize = 0;
                while (ch < channels_usize) : (ch += 1) {
                    const dst: [*]f32 = @ptrCast(@alignCast(frame.*.data[ch]));
                    if (nb_samples < frame_size) {
                        @memset(dst[0..frame_size], @as(f32, 0.0));
                    }
                    var i: usize = 0;
                    while (i < nb_samples) : (i += 1) {
                        dst[i] = samples[(sample_index + i) * channels_usize + ch];
                    }
                }
            } else if (self.audio_codec_ctx.*.sample_fmt == ffmpeg.AV_SAMPLE_FMT_FLT) {
                const dst: [*]f32 = @ptrCast(@alignCast(frame.*.data[0]));
                const copy_len = nb_samples * channels_usize;
                if (nb_samples < frame_size) {
                    @memset(dst[0 .. frame_size * channels_usize], @as(f32, 0.0));
                }
                @memcpy(dst[0..copy_len], samples[sample_index * channels_usize .. sample_index * channels_usize + copy_len]);
            } else {
                return error.UnsupportedAudioSampleFormat;
            }

            // Keep PTS in samples to match audio time_base.
            frame.*.pts = next_audio_pts;
            next_audio_pts += @intCast(nb_samples);

            // Submit the frame and collect any ready packets.
            ret = ffmpeg.avcodec_send_frame(self.audio_codec_ctx, frame);
            try checkErr(ret);

            while (true) {
                ret = ffmpeg.avcodec_receive_packet(self.audio_codec_ctx, audio_pkt);
                if (ret == err_eagain or ret == err_eof) break;
                try checkErr(ret);

                // Convert packet timestamps to the container's time base.
                ffmpeg.av_packet_rescale_ts(audio_pkt, self.audio_codec_ctx.*.time_base, self.audio_stream.*.time_base);
                audio_pkt.*.stream_index = audio_stream_idx;

                // Keep a copy for later interleaving with video by nanosecond PTS.
                const stored_pkt = ffmpeg.av_packet_alloc() orelse return error.FFmpegError;
                ret = ffmpeg.av_packet_ref(stored_pkt, audio_pkt);
                try checkErr(ret);
                try audio_packets.append(stored_pkt);
                ffmpeg.av_packet_unref(audio_pkt);
            }

            sample_index += nb_samples;
        }

        ret = ffmpeg.avcodec_send_frame(self.audio_codec_ctx, null);
        try checkErr(ret);

        // Drain the encoder for delayed packets.
        while (true) {
            ret = ffmpeg.avcodec_receive_packet(self.audio_codec_ctx, audio_pkt);
            if (ret == err_eagain or ret == err_eof) break;
            try checkErr(ret);

            ffmpeg.av_packet_rescale_ts(audio_pkt, self.audio_codec_ctx.*.time_base, self.audio_stream.*.time_base);
            audio_pkt.*.stream_index = audio_stream_idx;

            const stored_pkt = ffmpeg.av_packet_alloc() orelse return error.FFmpegError;
            ret = ffmpeg.av_packet_ref(stored_pkt, audio_pkt);
            try checkErr(ret);
            try audio_packets.append(stored_pkt);
            ffmpeg.av_packet_unref(audio_pkt);
        }

        return audio_packets;
    }
};
