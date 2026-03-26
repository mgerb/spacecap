const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ffmpeg = @import("./ffmpeg.zig").ffmpeg;
const checkErr = @import("./ffmpeg.zig").check_err;

pub const EncodedAudioPacketNode = struct {
    data: [*c]const ffmpeg.AVPacket,
    node: std.DoublyLinkedList.Node = .{},
    allocator: Allocator,

    pub fn init(allocator: Allocator, packet: [*c]const ffmpeg.AVPacket) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);

        self.* = .{
            .data = packet,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        var packet: [*c]ffmpeg.AVPacket = @constCast(self.data);
        ffmpeg.av_packet_free(&packet);
        self.allocator.destroy(self);
    }
};

pub const AudioEncoder = struct {
    const Self = @This();

    allocator: Allocator,
    audio_codec_ctx: [*c]ffmpeg.AVCodecContext,
    channels: u32,
    // A rolling buffer of raw audio waiting to be encoded. We only encode
    // once enough sample positions have accumulated.
    pending_samples: std.ArrayList(f32),
    // Absolute sample position of the first sample in `pending_samples`.
    pending_start_sample: ?i64 = null,
    is_flushed: bool = false,

    pub fn init(
        allocator: Allocator,
        sample_rate: u32,
        channels: u32,
    ) !Self {
        assert(channels > 0);
        assert(sample_rate > 0);
        const audio_codec = ffmpeg.avcodec_find_encoder(ffmpeg.AV_CODEC_ID_AAC) orelse return error.MissingAudioEncoder;
        var audio_codec_ctx = ffmpeg.avcodec_alloc_context3(audio_codec) orelse return error.FFmpegError;
        errdefer ffmpeg.avcodec_free_context(&audio_codec_ctx);

        audio_codec_ctx.*.sample_rate = @intCast(sample_rate);
        _ = ffmpeg.av_channel_layout_default(&audio_codec_ctx.*.ch_layout, @intCast(channels));
        audio_codec_ctx.*.time_base = ffmpeg.AVRational{ .num = 1, .den = @intCast(sample_rate) };
        audio_codec_ctx.*.bit_rate = 320_000;

        // Prefer floating-point formats so the replay mixer can hand PCM to the
        // encoder without an extra sample conversion stage.
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

        if (chosen_fmt == ffmpeg.AV_SAMPLE_FMT_NONE) {
            return error.UnsupportedAudioSampleFormat;
        }
        audio_codec_ctx.*.sample_fmt = chosen_fmt;
        audio_codec_ctx.*.profile = ffmpeg.AV_PROFILE_AAC_LOW;

        _ = ffmpeg.av_opt_set_int(audio_codec_ctx.*.priv_data, "aac_pns", 0, 0);
        _ = ffmpeg.av_opt_set_int(audio_codec_ctx.*.priv_data, "vbr", 4, 0);

        const ret = ffmpeg.avcodec_open2(audio_codec_ctx, audio_codec, null);
        try checkErr(ret);

        return .{
            .allocator = allocator,
            .audio_codec_ctx = audio_codec_ctx,
            .channels = channels,
            .pending_samples = try .initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *Self) void {
        self.pending_samples.deinit(self.allocator);
        ffmpeg.avcodec_free_context(&self.audio_codec_ctx);
    }

    /// Encode a chunk of contiguous audio that begins at `start_sample`.
    /// Timeline shaping is handled by the replay buffer before audio reaches
    /// the encoder.
    pub fn encode_chunk(
        self: *Self,
        start_sample: i64,
        pcm: []const f32,
    ) !?std.DoublyLinkedList {
        assert(!self.is_flushed);

        const total_samples: usize = pcm.len / self.channels;

        if (total_samples == 0) {
            return null;
        }

        if (self.pending_start_sample == null) {
            // The first chunk establishes the absolute sample position for the
            // rolling PCM buffer.
            self.pending_start_sample = start_sample;
        } else {
            const expected_next_sample = self.pending_start_sample.? +
                @as(i64, @intCast(self.pending_samples.items.len / self.channels));
            if (start_sample != expected_next_sample) {
                return error.NonContiguousAudioPts;
            }
        }

        try self.pending_samples.appendSlice(self.allocator, pcm);

        return try self.encode_buffered_frames(false);
    }

    /// Encode buffered samples if there are enough to fill the codec frame size.
    /// allow_partial - Set to true to ignore this check and encode anyway.
    fn encode_buffered_frames(self: *Self, allow_partial: bool) !std.DoublyLinkedList {
        var audio_packets: std.DoublyLinkedList = .{};
        errdefer deinit_packet_list(&audio_packets);

        assert(self.audio_codec_ctx.*.frame_size > 0);
        const codec_samples_per_packet: usize = @intCast(self.audio_codec_ctx.*.frame_size);

        var frame = ffmpeg.av_frame_alloc() orelse return error.FFmpegError;
        defer ffmpeg.av_frame_free(&frame);

        frame.*.format = self.audio_codec_ctx.*.sample_fmt;
        frame.*.ch_layout = self.audio_codec_ctx.*.ch_layout;
        frame.*.sample_rate = self.audio_codec_ctx.*.sample_rate;
        frame.*.nb_samples = @intCast(codec_samples_per_packet);

        const ret = ffmpeg.av_frame_get_buffer(frame, 0);
        try checkErr(ret);

        while (true) {
            const buffered_samples = self.pending_samples.items.len / self.channels;
            if (buffered_samples < codec_samples_per_packet and !(allow_partial and buffered_samples > 0)) {
                break;
            }

            const submitted_samples: usize = @min(codec_samples_per_packet, buffered_samples);
            // `sendFrame` reads from the front of `pending_samples`, so after it
            // returns we compact the remaining PCM to keep the rolling buffer
            // contiguous for the next capture chunk.
            try self.send_frame(&audio_packets, frame, self.pending_start_sample.?, codec_samples_per_packet, submitted_samples);

            const consumed_samples = submitted_samples * self.channels;
            const remaining_samples = self.pending_samples.items.len - consumed_samples;
            std.mem.copyForwards(
                f32,
                self.pending_samples.items[0..remaining_samples],
                self.pending_samples.items[consumed_samples..],
            );
            try self.pending_samples.resize(self.allocator, remaining_samples);

            self.pending_start_sample.? += @intCast(submitted_samples);
            if (remaining_samples == 0) {
                self.pending_start_sample = null;
                break;
            }
        }

        return audio_packets;
    }

    pub fn flush(self: *Self) !std.DoublyLinkedList {
        assert(!self.is_flushed);

        var audio_packets = try self.encode_buffered_frames(true);
        errdefer deinit_packet_list(&audio_packets);

        self.is_flushed = true;
        const ret = ffmpeg.avcodec_send_frame(self.audio_codec_ctx, null);
        try checkErr(ret);
        try self.collect_ready_packets(&audio_packets);
        return audio_packets;
    }

    fn send_frame(
        self: *Self,
        audio_packets: *std.DoublyLinkedList,
        frame: [*c]ffmpeg.AVFrame,
        start_sample: i64,
        codec_samples_per_packet: usize,
        submitted_samples: usize,
    ) !void {
        const source_pcm = self.pending_samples.items[0 .. submitted_samples * self.channels];

        var ret = ffmpeg.av_frame_make_writable(frame);
        try checkErr(ret);

        if (self.audio_codec_ctx.*.sample_fmt == ffmpeg.AV_SAMPLE_FMT_FLTP) {
            // Planar float expects one channel per FFmpeg plane.
            var ch: usize = 0;
            while (ch < self.channels) : (ch += 1) {
                const dst: [*]f32 = @ptrCast(@alignCast(frame.*.data[ch]));
                if (submitted_samples < codec_samples_per_packet) {
                    @memset(dst[0..codec_samples_per_packet], 0.0);
                }
                var i: usize = 0;
                while (i < submitted_samples) : (i += 1) {
                    dst[i] = source_pcm[i * self.channels + ch];
                }
            }
        } else if (self.audio_codec_ctx.*.sample_fmt == ffmpeg.AV_SAMPLE_FMT_FLT) {
            // Interleaved float stores all channels in the first plane.
            const dst: [*]f32 = @ptrCast(@alignCast(frame.*.data[0]));
            if (submitted_samples < codec_samples_per_packet) {
                @memset(dst[0 .. codec_samples_per_packet * self.channels], 0.0);
            }
            @memcpy(dst[0..source_pcm.len], source_pcm);
        } else {
            return error.UnsupportedAudioSampleFormat;
        }

        frame.*.nb_samples = @intCast(submitted_samples);
        frame.*.pts = start_sample;

        ret = ffmpeg.avcodec_send_frame(self.audio_codec_ctx, frame);
        try checkErr(ret);
        // A single submitted frame can produce zero, one, or multiple packets
        // depending on encoder delay, so always drain after each send.
        try self.collect_ready_packets(audio_packets);
    }

    fn collect_ready_packets(
        self: *Self,
        audio_packets: *std.DoublyLinkedList,
    ) !void {
        var audio_pkt = ffmpeg.av_packet_alloc() orelse return error.FFmpegError;
        defer ffmpeg.av_packet_free(&audio_pkt);

        while (true) {
            const ret = ffmpeg.avcodec_receive_packet(self.audio_codec_ctx, audio_pkt);
            if (ret == ffmpeg.AVERROR(ffmpeg.EAGAIN) or ret == ffmpeg.AVERROR_EOF) {
                break;
            }
            try checkErr(ret);
            var owned_pkt = ffmpeg.av_packet_alloc() orelse return error.FFmpegError;
            errdefer ffmpeg.av_packet_free(&owned_pkt);
            ffmpeg.av_packet_move_ref(owned_pkt, audio_pkt);
            const node = try EncodedAudioPacketNode.init(self.allocator, owned_pkt);
            audio_packets.append(&node.node);
        }
    }
};

pub fn deinit_packet_list(packets: *std.DoublyLinkedList) void {
    while (packets.popFirst()) |node| {
        const packet_node: *EncodedAudioPacketNode = @alignCast(@fieldParentPtr("node", node));
        packet_node.deinit();
    }
}

test "encodeChunk rejects non-contiguous sample input" {
    const allocator = std.testing.allocator;

    var encoder = try AudioEncoder.init(allocator, 48_000, 2);
    defer encoder.deinit();

    const pcm = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    var first_result = (try encoder.encode_chunk(0, &pcm)).?;
    defer deinit_packet_list(&first_result);
    try std.testing.expect(first_result.first == null);
    try std.testing.expectError(error.NonContiguousAudioPts, encoder.encode_chunk(3, &pcm));
}

test "encodeChunk plus flush produces encoded audio packets" {
    const allocator = std.testing.allocator;
    const sample_rate: u32 = 48_000;
    const channels: u32 = 2;
    const start_sample: i64 = 12_345;
    const sample_positions: usize = 2_048;

    var encoder = try AudioEncoder.init(allocator, sample_rate, channels);
    defer encoder.deinit();

    const pcm = try allocator.alloc(f32, sample_positions * channels);
    defer allocator.free(pcm);

    for (0..sample_positions) |sample_idx| {
        const value = @as(f32, @floatFromInt(@mod(sample_idx, 32))) / 32.0;
        const pcm_offset = sample_idx * channels;
        pcm[pcm_offset] = value;
        pcm[pcm_offset + 1] = -value;
    }

    var all_packets: std.DoublyLinkedList = .{};
    defer deinit_packet_list(&all_packets);

    var encoded_packets = (try encoder.encode_chunk(start_sample, pcm)).?;
    while (encoded_packets.popFirst()) |node| {
        all_packets.append(node);
    }

    var flushed_packets = try encoder.flush();
    while (flushed_packets.popFirst()) |node| {
        all_packets.append(node);
    }

    try std.testing.expect(all_packets.first != null);

    var node = all_packets.first;
    var previous_pts: ?i64 = null;
    while (node) |current| : (node = current.next) {
        const packet_node: *EncodedAudioPacketNode = @fieldParentPtr("node", current);
        try std.testing.expect(packet_node.data.*.size > 0);
        try std.testing.expect(packet_node.data.*.pts != ffmpeg.AV_NOPTS_VALUE);
        try std.testing.expect(packet_node.data.*.dts != ffmpeg.AV_NOPTS_VALUE);
        try std.testing.expect(packet_node.data.*.duration > 0);
        if (previous_pts) |prev| {
            try std.testing.expect(packet_node.data.*.pts >= prev);
        }
        previous_pts = packet_node.data.*.pts;
    }
}

// TODO: Add integration test to compare encoded audio file.
