const std = @import("std");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const AudioReplayBuffer = @import("./capture/audio/audio_replay_buffer.zig");
const SampleWindow = @import("./capture/audio/audio_timeline.zig").SampleWindow;
const EncodedAudioPacketNode = @import("./audio_encoder.zig").EncodedAudioPacketNode;
const LinkedListIterator = @import("./util.zig").LinkedListIterator;
const VideoReplayBuffer = @import("./vulkan/video_replay_buffer.zig").VideoReplayBuffer;
const VideoReplayBufferNode = @import("./vulkan/video_replay_buffer.zig").VideoReplayBufferNode;
const ReplayWindow = @import("./types.zig").ReplayWindow;
const ffmpeg = @import("./ffmpeg.zig").ffmpeg;
const checkErr = @import("./ffmpeg.zig").check_err;

pub const Muxer = struct {
    const Self = @This();
    allocator: Allocator,
    video_replay_buffer: *VideoReplayBuffer,
    audio_replay_buffer: *AudioReplayBuffer,
    // Audio packets are stored on the same absolute sample timeline used by the
    // replay buffer. Export converts the chosen video window into this range.
    audio_sample_window: ?SampleWindow,
    fps: u32,
    format_context: *ffmpeg.AVFormatContext,
    file_name: [:0]u8,
    video_stream: *ffmpeg.AVStream,
    // Audio is optional so replays can still export when no audio packets were
    // captured or when audio falls completely outside the final replay window.
    audio_stream: ?*ffmpeg.AVStream,

    pub fn init(
        allocator: Allocator,
        video_replay_buffer: *VideoReplayBuffer,
        audio_replay_buffer: *AudioReplayBuffer,
        replay_window: ReplayWindow,
        width: u32,
        height: u32,
        fps: u32,
        file_name_prefix: []const u8,
    ) !Self {
        var format_context: *ffmpeg.AVFormatContext = undefined;
        // TODO: File name.
        const file_name = try std.fmt.allocPrintSentinel(allocator, "{s}_{}.mp4", .{ file_name_prefix, std.time.nanoTimestamp() }, 0);
        errdefer allocator.free(file_name);

        var ret = ffmpeg.avformat_alloc_output_context2(@ptrCast(&format_context), null, "mp4", file_name);
        try checkErr(ret);
        errdefer {
            if (format_context.pb != null) {
                _ = ffmpeg.avio_closep(&format_context.pb);
            }
            ffmpeg.avformat_free_context(format_context);
        }

        // Configure the H264 video stream as passthrough of the encoded bitstream.
        const video_stream = ffmpeg.avformat_new_stream(format_context, null) orelse return error.FFmpegError;

        const video_codecpar = video_stream.*.codecpar;
        video_codecpar.*.codec_id = ffmpeg.AV_CODEC_ID_H264;
        video_codecpar.*.codec_type = ffmpeg.AVMEDIA_TYPE_VIDEO;
        video_codecpar.*.width = @intCast(width);
        video_codecpar.*.height = @intCast(height);

        // ffmpeg frees this memory when it's done so we need to copy it.
        const extradata: [*c]u8 = @ptrCast(ffmpeg.av_malloc(video_replay_buffer.header_frame.items.len));
        if (extradata == null) {
            return error.OutOfMemory;
        }
        @memcpy(extradata[0..video_replay_buffer.header_frame.items.len], video_replay_buffer.header_frame.items);

        video_codecpar.*.extradata = extradata;
        video_codecpar.*.extradata_size = @intCast(video_replay_buffer.header_frame.items.len);

        // Convert nanosecond capture timestamps to a muxer-friendly video time base.
        video_stream.*.time_base = ffmpeg.AVRational{ .num = 1, .den = 90_000 };
        video_stream.*.avg_frame_rate = ffmpeg.AVRational{ .num = @intCast(fps), .den = 1 };
        video_stream.*.r_frame_rate = ffmpeg.AVRational{ .num = @intCast(fps), .den = 1 };

        var audio_stream: ?*ffmpeg.AVStream = null;
        const audio_sample_window = audio_replay_buffer.timeline.get_sample_window(replay_window.start_ns, replay_window.end_ns);
        if (audio_replay_buffer.has_packets() and audio_sample_window != null) {
            const stream = ffmpeg.avformat_new_stream(format_context, null) orelse return error.FFmpegError;
            const codec_context = audio_replay_buffer.timeline.get_codec_context();
            try checkErr(ffmpeg.avcodec_parameters_from_context(stream.*.codecpar, codec_context.audio_codec_ctx));
            stream.*.time_base = codec_context.time_base;
            audio_stream = stream;
        }

        if (format_context.oformat.*.flags & ffmpeg.AVFMT_NOFILE == 0) {
            ret = ffmpeg.avio_open(&format_context.pb, file_name, ffmpeg.AVIO_FLAG_WRITE);
            try checkErr(ret);
        }

        // Write container headers once streams are configured.
        ret = ffmpeg.avformat_write_header(format_context, null);
        try checkErr(ret);

        return .{
            .allocator = allocator,
            .video_replay_buffer = video_replay_buffer,
            .audio_replay_buffer = audio_replay_buffer,
            .audio_sample_window = audio_sample_window,
            .fps = fps,
            .format_context = format_context,
            .file_name = file_name,
            .video_stream = video_stream,
            .audio_stream = audio_stream,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.format_context.pb != null) {
            _ = ffmpeg.avio_closep(&self.format_context.pb);
        }
        ffmpeg.avformat_free_context(self.format_context);
        self.allocator.free(self.file_name);
    }

    pub fn mux_audio_video(self: *Self) !void {
        var video_pkt = ffmpeg.av_packet_alloc() orelse return error.FFmpegError;
        defer ffmpeg.av_packet_free(&video_pkt);

        var audio_pkt = ffmpeg.av_packet_alloc() orelse return error.FFmpegError;
        defer ffmpeg.av_packet_free(&audio_pkt);

        const max_mux_duration: i64 = std.math.maxInt(i32);
        var first_frame_time_ns: ?i128 = null;
        var pending_node: ?*VideoReplayBufferNode = null;
        var previous_pts: i64 = 0;
        var last_delta: i64 = 0;
        const ns_time_base = ffmpeg.AVRational{ .num = 1, .den = 1_000_000_000 };
        const frame_duration_pts = if (self.fps > 0)
            @max(ffmpeg.av_rescale_q(1, .{ .num = 1, .den = @intCast(self.fps) }, self.video_stream.time_base), 1)
        else
            0;
        // Snap only small capture jitter. Preserve real timeline gaps when capture/encode stalls.
        const jitter_tolerance_pts = if (self.fps > 0)
            @max(ffmpeg.av_rescale_q(10 * std.time.ns_per_ms, ns_time_base, self.video_stream.time_base), 1)
        else
            0;

        var audio_iterator = self.audio_replay_buffer.packet_iterator();
        var next_audio_packet = self.next_audio_packet_for_window(&audio_iterator);

        while (try self.video_replay_buffer.pop_first_owned()) |data| {
            const video_frame = data.data;

            if (first_frame_time_ns == null) {
                first_frame_time_ns = video_frame.timestamp_ns;
            }

            const pts_ns = video_frame.timestamp_ns - first_frame_time_ns.?;
            const raw_current_pts: i64 = ffmpeg.av_rescale_q(@intCast(pts_ns), ns_time_base, self.video_stream.time_base);
            const current_pts = apply_jitter_correction_to_pts(
                raw_current_pts,
                if (pending_node != null) previous_pts else null,
                frame_duration_pts,
                jitter_tolerance_pts,
            );

            // The video packet writes rely on the previous frame PTS, so that
            // is why we do this weird pending_node logic and then write the last
            // packet when the loop exits.
            if (pending_node) |pending| {
                // We now have the next PTS, so we can set duration on the pending packet.
                const duration = if (current_pts > previous_pts) current_pts - previous_pts else 0;
                const safe_duration = if (duration > max_mux_duration) max_mux_duration else duration;
                try self.write_pending_video_packet(
                    video_pkt,
                    audio_pkt,
                    &audio_iterator,
                    &next_audio_packet,
                    pending,
                    previous_pts,
                    safe_duration,
                );
                last_delta = safe_duration;
            }

            pending_node = data;
            previous_pts = current_pts;
        }

        if (pending_node) |pending| {
            try self.write_pending_video_packet(
                video_pkt,
                audio_pkt,
                &audio_iterator,
                &next_audio_packet,
                pending,
                previous_pts,
                if (last_delta > 0) last_delta else 0,
            );
        }

        // Any remaining audio belongs after the final video packet.
        while (next_audio_packet) |audio_node| {
            try self.write_audio_packet(audio_pkt, audio_node);
            next_audio_packet = self.next_audio_packet_for_window(&audio_iterator);
        }

        const ret = ffmpeg.av_write_trailer(self.format_context);
        try checkErr(ret);
    }

    fn next_audio_packet_for_window(self: *Self, iterator: *LinkedListIterator(EncodedAudioPacketNode)) ?*EncodedAudioPacketNode {
        const audio_sample_window = self.audio_sample_window orelse return null;

        while (iterator.next()) |packet_node| {
            const packet_start = packet_node.data.*.pts;
            const packet_end = packet_start + packet_node.data.*.duration;

            if (packet_end <= audio_sample_window.start_sample) {
                continue;
            }
            if (packet_start >= audio_sample_window.end_sample) {
                return null;
            }
            return packet_node;
        }

        return null;
    }

    fn should_write_audio_before_video(self: *Self, packet_node: *EncodedAudioPacketNode, video_pts: i64) bool {
        assert(self.audio_stream != null);
        assert(self.audio_sample_window != null);
        const packet_pts = packet_node.data.*.pts - self.audio_sample_window.?.start_sample;
        return ffmpeg.av_compare_ts(packet_pts, self.audio_stream.?.*.time_base, video_pts, self.video_stream.time_base) < 0;
    }

    fn write_pending_video_packet(
        self: *Self,
        video_pkt: [*c]ffmpeg.AVPacket,
        audio_pkt: [*c]ffmpeg.AVPacket,
        audio_iterator: *LinkedListIterator(EncodedAudioPacketNode),
        next_audio_packet: *?*EncodedAudioPacketNode,
        pending: *VideoReplayBufferNode,
        pts: i64,
        duration: i64,
    ) !void {
        // Before writing the pending video frame, flush any audio packet whose
        // sample-time PTS belongs earlier on the mux timeline.
        while (next_audio_packet.*) |audio_node| {
            if (!self.should_write_audio_before_video(audio_node, pts)) {
                break;
            }
            try self.write_audio_packet(audio_pkt, audio_node);
            next_audio_packet.* = self.next_audio_packet_for_window(audio_iterator);
        }

        video_pkt.*.data = pending.data.data.items.ptr;
        video_pkt.*.size = @intCast(pending.data.data.items.len);
        video_pkt.*.stream_index = self.video_stream.index;
        video_pkt.*.pts = pts;
        video_pkt.*.dts = video_pkt.*.pts;
        video_pkt.*.duration = duration;
        if (pending.data.is_idr) {
            video_pkt.*.flags |= ffmpeg.AV_PKT_FLAG_KEY;
        } else {
            video_pkt.*.flags &= ~@as(c_int, ffmpeg.AV_PKT_FLAG_KEY);
        }

        const ret = ffmpeg.av_interleaved_write_frame(self.format_context, video_pkt);
        ffmpeg.av_packet_unref(video_pkt);
        try checkErr(ret);

        pending.deinit();
    }

    fn write_audio_packet(self: *Self, pkt: [*c]ffmpeg.AVPacket, packet_node: *EncodedAudioPacketNode) !void {
        assert(self.audio_stream != null);
        assert(self.audio_sample_window != null);
        try checkErr(ffmpeg.av_packet_ref(pkt, @constCast(packet_node.data)));
        pkt.*.stream_index = self.audio_stream.?.*.index;
        pkt.*.pts = packet_node.data.*.pts - self.audio_sample_window.?.start_sample;
        pkt.*.dts = packet_node.data.*.dts - self.audio_sample_window.?.start_sample;
        pkt.*.duration = packet_node.data.*.duration;
        pkt.*.flags = packet_node.data.*.flags;

        const ret = ffmpeg.av_interleaved_write_frame(self.format_context, pkt);
        ffmpeg.av_packet_unref(pkt);
        try checkErr(ret);
    }

    // TODO: Move video timeline processing upstream.
    fn apply_jitter_correction_to_pts(raw_current_pts: i64, previous_pts: ?i64, frame_duration_pts: i64, jitter_tolerance_pts: i64) i64 {
        var current_pts = raw_current_pts;
        if (previous_pts) |prev_pts| {
            if (frame_duration_pts > 0) {
                const expected_pts = prev_pts + frame_duration_pts;
                const min_snap = expected_pts - jitter_tolerance_pts;
                const max_snap = expected_pts + jitter_tolerance_pts;
                if (raw_current_pts >= min_snap and raw_current_pts <= max_snap) {
                    current_pts = expected_pts;
                }
            }

            if (current_pts <= prev_pts) {
                current_pts = prev_pts + 1;
            }
        }
        return current_pts;
    }
};

test "applyJitterCorrectionToPts snaps small jitter to expected cadence" {
    const expected = 3_000;
    const previous = 2_000;
    const frame_duration = 1_000;
    const jitter_tolerance = 250;

    try std.testing.expectEqual(
        expected,
        Muxer.apply_jitter_correction_to_pts(expected + 100, previous, frame_duration, jitter_tolerance),
    );
}

test "applyJitterCorrectionToPts preserves large capture gaps" {
    const previous = 2_000;
    const frame_duration = 1_000;
    const jitter_tolerance = 250;
    const raw_current = 5_000;

    try std.testing.expectEqual(
        raw_current,
        Muxer.apply_jitter_correction_to_pts(raw_current, previous, frame_duration, jitter_tolerance),
    );
}
