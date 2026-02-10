const std = @import("std");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.muxer);
const VideoReplayBuffer = @import("./vulkan/video_replay_buffer.zig").VideoReplayBuffer;
const VideoReplayBufferNode = @import("./vulkan/video_replay_buffer.zig").VideoReplayBufferNode;
const AudioEncoder = @import("./audio_encoder.zig").AudioEncoder;
const ffmpeg = @import("./ffmpeg.zig").ffmpeg;
const checkErr = @import("./ffmpeg.zig").checkErr;

pub const Muxer = struct {
    const Self = @This();
    allocator: Allocator,
    video_replay_buffer: *VideoReplayBuffer,
    width: u32,
    height: u32,
    fps: u32,
    audio_samples: []const f32,
    audio_sample_rate: u32,
    audio_channels: u32,
    audio_encoder: AudioEncoder,
    format_context: *ffmpeg.AVFormatContext,
    file_name: [:0]u8,
    video_stream: *ffmpeg.AVStream,

    pub fn init(
        allocator: Allocator,
        video_replay_buffer: *VideoReplayBuffer,
        width: u32,
        height: u32,
        fps: u32,
        audio_samples: []const f32,
        audio_sample_rate: u32,
        audio_channels: u32,
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
        @memcpy(extradata[0..video_replay_buffer.header_frame.items.len], video_replay_buffer.header_frame.items);

        video_codecpar.*.extradata = extradata;
        video_codecpar.*.extradata_size = @intCast(video_replay_buffer.header_frame.items.len);

        // Convert nanosecond capture timestamps to a muxer-friendly video time base.
        video_stream.*.time_base = ffmpeg.AVRational{ .num = 1, .den = 90_000 };
        video_stream.*.avg_frame_rate = ffmpeg.AVRational{ .num = @intCast(fps), .den = 1 };
        video_stream.*.r_frame_rate = ffmpeg.AVRational{ .num = @intCast(fps), .den = 1 };

        // Register audio stream before writing container headers.
        var audio_encoder = try AudioEncoder.init(allocator, audio_sample_rate, audio_channels, format_context);
        errdefer audio_encoder.deinit();

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
            .width = width,
            .height = height,
            .fps = fps,
            .audio_samples = audio_samples,
            .audio_sample_rate = audio_sample_rate,
            .audio_channels = audio_channels,
            .audio_encoder = audio_encoder,
            .format_context = format_context,
            .file_name = file_name,
            .video_stream = video_stream,
        };
    }

    pub fn deinit(self: *Self) void {
        self.audio_encoder.deinit();
        if (self.format_context.pb != null) {
            _ = ffmpeg.avio_closep(&self.format_context.pb);
        }
        ffmpeg.avformat_free_context(self.format_context);
        self.allocator.free(self.file_name);
    }

    pub fn muxAudioVideo(
        self: *Self,
    ) !void {
        const audio_time_base = self.audio_encoder.audio_stream.*.time_base;
        var audio_encode_result = try self.audio_encoder.encode(self.audio_samples);
        defer audio_encode_result.deinit();
        const audio_packets = audio_encode_result.packets.items;

        var video_pkt = ffmpeg.av_packet_alloc() orelse return error.FFmpegError;
        defer ffmpeg.av_packet_free(&video_pkt);

        const max_mux_duration: i64 = std.math.maxInt(i32);
        var audio_index: usize = 0;
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

        while (try self.video_replay_buffer.popFirstOwned()) |data| {
            const video_frame = data.data;

            if (first_frame_time_ns == null) {
                first_frame_time_ns = video_frame.timestamp_ns;
            }

            const pts_ns = video_frame.timestamp_ns - first_frame_time_ns.?;
            const raw_current_pts: i64 = ffmpeg.av_rescale_q(@intCast(pts_ns), ns_time_base, self.video_stream.time_base);
            const current_pts = applyJitterCorrectionToPts(
                raw_current_pts,
                if (pending_node != null) previous_pts else null,
                frame_duration_pts,
                jitter_tolerance_pts,
            );

            if (pending_node) |pending| {
                // We now have the next PTS, so we can set duration on the pending packet.
                const duration = if (current_pts > previous_pts) current_pts - previous_pts else 0;
                const safe_duration = if (duration > max_mux_duration) max_mux_duration else duration;

                // Flush audio packets that should play before this video frame.
                while (audio_index < audio_packets.len and
                    ffmpeg.av_compare_ts(audio_packets[audio_index].*.pts, audio_time_base, previous_pts, self.video_stream.time_base) < 0)
                {
                    const pkt = audio_packets[audio_index];
                    const ret = ffmpeg.av_interleaved_write_frame(self.format_context, pkt);
                    ffmpeg.av_packet_unref(pkt);
                    try checkErr(ret);
                    audio_index += 1;
                }

                video_pkt.*.data = pending.data.data.items.ptr;
                video_pkt.*.size = @intCast(pending.data.data.items.len);
                video_pkt.*.stream_index = self.video_stream.index;
                video_pkt.*.pts = previous_pts;
                video_pkt.*.dts = video_pkt.*.pts;
                video_pkt.*.duration = safe_duration;
                if (pending.data.is_idr) {
                    video_pkt.*.flags |= ffmpeg.AV_PKT_FLAG_KEY;
                } else {
                    video_pkt.*.flags &= ~@as(c_int, ffmpeg.AV_PKT_FLAG_KEY);
                }

                const ret = ffmpeg.av_interleaved_write_frame(self.format_context, video_pkt);
                ffmpeg.av_packet_unref(video_pkt);
                try checkErr(ret);

                last_delta = safe_duration;
                pending.deinit();
            }

            pending_node = data;
            previous_pts = current_pts;
        }

        if (pending_node) |pending| {
            // Write the final packet with the last known delta (or zero if only one frame).
            // Flush any remaining audio packets that belong before the last video frame.
            while (audio_index < audio_packets.len and
                ffmpeg.av_compare_ts(audio_packets[audio_index].*.pts, audio_time_base, previous_pts, self.video_stream.time_base) < 0)
            {
                const pkt = audio_packets[audio_index];
                const ret = ffmpeg.av_interleaved_write_frame(self.format_context, pkt);
                ffmpeg.av_packet_unref(pkt);
                try checkErr(ret);
                audio_index += 1;
            }

            video_pkt.*.data = pending.data.data.items.ptr;
            video_pkt.*.size = @intCast(pending.data.data.items.len);
            video_pkt.*.stream_index = self.video_stream.index;
            video_pkt.*.pts = previous_pts;
            video_pkt.*.dts = video_pkt.*.pts;
            video_pkt.*.duration = if (last_delta > 0) last_delta else 0;
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

        // Flush any remaining audio after the last video frame.
        while (audio_index < audio_packets.len) {
            const pkt = audio_packets[audio_index];
            const ret = ffmpeg.av_interleaved_write_frame(self.format_context, pkt);
            ffmpeg.av_packet_unref(pkt);
            try checkErr(ret);
            audio_index += 1;
        }

        // Finalize the container.
        const ret = ffmpeg.av_write_trailer(self.format_context);
        try checkErr(ret);
    }

    fn applyJitterCorrectionToPts(raw_current_pts: i64, previous_pts: ?i64, frame_duration_pts: i64, jitter_tolerance_pts: i64) i64 {
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
    const raw_current_pts: i64 = 1030;
    const previous_pts: i64 = 1000;
    const frame_duration_pts: i64 = 33;
    const jitter_tolerance_pts: i64 = 10;

    const smoothed = Muxer.applyJitterCorrectionToPts(raw_current_pts, previous_pts, frame_duration_pts, jitter_tolerance_pts);
    try std.testing.expectEqual(@as(i64, 1033), smoothed);
}

test "applyJitterCorrectionToPts keeps larger gaps" {
    const raw_current_pts: i64 = 1100;
    const previous_pts: i64 = 1000;
    const frame_duration_pts: i64 = 33;
    const jitter_tolerance_pts: i64 = 10;

    const smoothed = Muxer.applyJitterCorrectionToPts(raw_current_pts, previous_pts, frame_duration_pts, jitter_tolerance_pts);
    try std.testing.expectEqual(raw_current_pts, smoothed);
}

test "applyJitterCorrectionToPts enforces strictly increasing pts" {
    const raw_current_pts: i64 = 998;
    const previous_pts: i64 = 1000;
    const frame_duration_pts: i64 = 33;
    const jitter_tolerance_pts: i64 = 10;

    const smoothed = Muxer.applyJitterCorrectionToPts(raw_current_pts, previous_pts, frame_duration_pts, jitter_tolerance_pts);
    try std.testing.expectEqual(@as(i64, 1001), smoothed);
}

test "applyJitterCorrectionToPts leaves first frame unchanged" {
    const raw_current_pts: i64 = 123;
    const smoothed = Muxer.applyJitterCorrectionToPts(raw_current_pts, null, 33, 10);
    try std.testing.expectEqual(raw_current_pts, smoothed);
}
