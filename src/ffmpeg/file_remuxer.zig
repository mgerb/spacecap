const std = @import("std");
const c = @import("ffmpeg_c");
const check_err = @import("./util.zig").check_err;
const ns_time_base = @import("./util.zig").ns_time_base;

/// Used to remux a video file and trim by range.
pub const FileRemuxer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    input_path: [:0]u8,
    output_path: [:0]u8,
    input_context: *c.AVFormatContext,
    output_context: *c.AVFormatContext,
    video_stream_index: c_int,
    audio_stream_index: ?c_int,
    output_video_stream: *c.AVStream,
    output_audio_stream: ?*c.AVStream = null,

    pub fn init(
        allocator: std.mem.Allocator,
        input_path: []const u8,
        output_path: []const u8,
    ) !Self {
        const input_path_z = try allocator.dupeSentinel(u8, input_path, 0);
        errdefer allocator.free(input_path_z);
        const output_path_z = try allocator.dupeSentinel(u8, output_path, 0);
        errdefer allocator.free(output_path_z);

        var input_context: *c.AVFormatContext = c.avformat_alloc_context() orelse return error.FFmpegError;
        try check_err(c.avformat_open_input(@ptrCast(&input_context), input_path_z.ptr, null, null));
        errdefer c.avformat_close_input(@ptrCast(&input_context));
        try check_err(c.avformat_find_stream_info(input_context, null));

        const video_stream_index = c.av_find_best_stream(
            input_context,
            c.AVMEDIA_TYPE_VIDEO,
            -1,
            -1,
            null,
            0,
        );
        if (video_stream_index < 0) {
            return error.MissingVideoStream;
        }

        const audio_stream_index = c.av_find_best_stream(
            input_context,
            c.AVMEDIA_TYPE_AUDIO,
            -1,
            video_stream_index,
            null,
            0,
        );

        var output_context: *c.AVFormatContext = undefined;
        try check_err(c.avformat_alloc_output_context2(
            @ptrCast(&output_context),
            null,
            null,
            output_path_z.ptr,
        ));
        errdefer {
            if (output_context.pb != null) {
                _ = c.avio_closep(&output_context.pb);
            }
            c.avformat_free_context(output_context);
        }

        const output_video_stream = try add_output_stream(input_context, output_context, video_stream_index);
        const output_audio_stream = if (audio_stream_index >= 0)
            try add_output_stream(input_context, output_context, audio_stream_index)
        else
            null;

        try check_err(c.av_dict_copy(&output_context.metadata, input_context.metadata, 0));

        if (output_context.oformat.*.flags & c.AVFMT_NOFILE == 0) {
            try check_err(c.avio_open(&output_context.pb, output_path_z.ptr, c.AVIO_FLAG_WRITE));
        }
        try check_err(c.avformat_write_header(output_context, null));

        return .{
            .allocator = allocator,
            .input_path = input_path_z,
            .output_path = output_path_z,
            .input_context = input_context,
            .output_context = output_context,
            .video_stream_index = video_stream_index,
            .audio_stream_index = if (audio_stream_index >= 0) audio_stream_index else null,
            .output_video_stream = output_video_stream,
            .output_audio_stream = output_audio_stream,
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up an output left open by a failed remux.
        if (self.output_context.pb != null) {
            _ = c.avio_closep(&self.output_context.pb);
        }
        c.avformat_free_context(self.output_context);
        c.avformat_close_input(@ptrCast(&self.input_context));
        self.allocator.free(self.output_path);
        self.allocator.free(self.input_path);
    }

    /// Remux a video constrained by to a trim range. This is not frame exact.
    /// The start snaps backward and the end snaps forward to keyframes.
    /// To be exact, we would need to
    /// decode/encode.
    pub fn remux_range(self: *Self, requested_start_ns: i64, requested_end_ns: i64) !void {
        if (requested_start_ns < 0 or requested_end_ns <= requested_start_ns) {
            return error.InvalidTrimRange;
        }

        // We can reuse a single packet.
        var packet = c.av_packet_alloc() orelse return error.FFmpegError;
        defer c.av_packet_free(&packet);

        const timeline_start_ns = start_time_ns(self.input_context.*.start_time);
        const video_time_base = self.get_video_time_base();
        // Round down so the start cannot advance to a keyframe after the request.
        const requested_start_pts = c.av_rescale_q_rnd(
            timeline_start_ns + requested_start_ns,
            ns_time_base,
            video_time_base,
            c.AV_ROUND_DOWN,
        );
        const requested_end_pts = c.av_rescale_q_rnd(
            timeline_start_ns + requested_end_ns,
            ns_time_base,
            video_time_base,
            c.AV_ROUND_UP,
        );
        const trim_range = try self.find_exact_trim_range(packet, requested_start_pts, requested_end_pts);
        if (trim_range.end_pts) |end_pts| {
            if (end_pts <= trim_range.start_pts) {
                return error.EmptyKeyframeRange;
            }
        }

        try self.seek_to_pts(trim_range.start_pts);
        try self.iterate_packets(packet, trim_range.start_pts, trim_range.end_pts, trim_range.start_dts);
        try check_err(c.av_write_trailer(self.output_context));

        if (self.output_context.pb != null) {
            try check_err(c.avio_closep(&self.output_context.pb));
        }
    }

    fn add_output_stream(
        input_context: *c.AVFormatContext,
        output_context: *c.AVFormatContext,
        input_index: c_int,
    ) !*c.AVStream {
        const input_stream = input_context.streams[@intCast(input_index)];
        const output_stream = c.avformat_new_stream(output_context, null) orelse {
            return error.FFmpegError;
        };
        try check_err(c.avcodec_parameters_copy(
            output_stream.*.codecpar,
            input_stream.*.codecpar,
        ));
        output_stream.*.codecpar.*.codec_tag = 0;
        output_stream.*.time_base = input_stream.*.time_base;
        output_stream.*.avg_frame_rate = input_stream.*.avg_frame_rate;
        output_stream.*.sample_aspect_ratio = input_stream.*.sample_aspect_ratio;
        output_stream.*.disposition = input_stream.*.disposition;
        try check_err(c.av_dict_copy(&output_stream.*.metadata, input_stream.*.metadata, 0));

        return output_stream;
    }

    /// Select the last keyframe at or before the start and the first at or after the end.
    /// If end of file is reached before the end, end_pts is null.
    fn find_exact_trim_range(
        self: *Self,
        packet: *c.AVPacket,
        requested_start_pts: i64,
        requested_end_pts: i64,
    ) !struct { start_pts: i64, end_pts: ?i64, start_dts: i64 } {
        try self.seek_to_pts(requested_start_pts);

        var start_pts: ?i64 = null;
        var start_dts: ?i64 = null;
        var duration: i64 = 0;
        var end_pts: ?i64 = null;
        while (true) {
            const read_result = c.av_read_frame(self.input_context, packet);
            defer c.av_packet_unref(packet);
            if (read_result == c.AVERROR_EOF) {
                break;
            }
            try check_err(read_result);

            // Only check video packets.
            if (packet.stream_index != self.video_stream_index) {
                continue;
            }

            const pts = try packet_pts(packet);

            // If keyframe.
            if (packet.flags & c.AV_PKT_FLAG_KEY != 0) {
                if (pts <= requested_start_pts and (start_pts == null or pts > start_pts.?)) {
                    start_pts = pts;
                    start_dts = null;
                    duration = 0;
                }
                if (end_pts == null and pts >= requested_end_pts) {
                    end_pts = pts;
                }
            }

            // Recover the starting DTS from the first known DTS after it.
            // Include leading frames that will later be discarded by PTS.
            if (start_pts != null and start_dts == null) {
                if (packet.dts != c.AV_NOPTS_VALUE) {
                    start_dts = packet.dts - duration;
                } else {
                    if (packet.duration <= 0) {
                        return error.MissingPacketDuration;
                    }
                    duration += packet.duration;
                }
            }

            // If the current pts is less than the selected end_pts, this
            // likely means that packets were out of order and we need to keep
            // searching through to the end. There's a good chance the end_pts
            // will be null, which just means it will just be remuxed to the
            // end of the file.
            if (end_pts) |epts| {
                if (pts < epts) {
                    end_pts = null;
                }
            }
        }

        return .{
            .start_pts = start_pts orelse return error.MissingStartKeyframe,
            .end_pts = end_pts,
            .start_dts = start_dts orelse return error.MissingPacketTimestamp,
        };
    }

    /// Iterate through all the packets in the trim range and write to a new file.
    fn iterate_packets(self: *Self, packet: *c.AVPacket, start_pts: i64, end_pts: ?i64, start_dts: i64) !void {
        var next_video_dts: ?i64 = start_dts;
        const video_time_base = self.get_video_time_base();
        var video_started = false;
        var video_done = false;
        var audio_done = self.output_audio_stream == null;

        while (!video_done or !audio_done) {
            const read_result = c.av_read_frame(self.input_context, packet);
            defer c.av_packet_unref(packet);
            if (read_result == c.AVERROR_EOF) {
                break;
            }
            try check_err(read_result);

            // ----------------------------------------------------------------------------
            // Video
            // ----------------------------------------------------------------------------
            if (packet.stream_index == self.video_stream_index) {
                if (video_done) {
                    continue;
                }

                const pts = try packet_pts(packet);

                if (!video_started) {
                    if (pts != start_pts) {
                        continue;
                    }
                    video_started = true;
                }

                // This fixes a deprecation warning, which will be removed in
                // future versions. FFmpeg used to automatically set the dts,
                // but it will no longer do it. I've noticed in mkv files, the
                // dts sometimes is not set.
                if (packet.dts == c.AV_NOPTS_VALUE) {
                    packet.dts = next_video_dts orelse return error.MissingPacketTimestamp;
                }
                next_video_dts = if (packet.duration > 0)
                    packet.dts + packet.duration
                else
                    null;

                // Presentation timestamps can precede the start even after its keyframe.
                if (pts < start_pts) {
                    continue;
                }

                if (end_pts) |epts| {
                    if (pts == epts) {
                        video_done = true;
                        continue;
                    }
                }

                try self.write_packet(packet, self.output_video_stream, start_pts);
                continue;
            }

            // ----------------------------------------------------------------------------
            // Audio
            // ----------------------------------------------------------------------------
            if (self.output_audio_stream) |output_audio_stream| {
                if (packet.stream_index == self.audio_stream_index.?) {
                    if (audio_done) {
                        continue;
                    }
                    const pts = try packet_pts(packet);
                    const audio_time_base = self.input_context.streams[@intCast(self.audio_stream_index.?)].*.time_base;
                    // Continue if audio packet starts before the start_pts.
                    if (c.av_compare_ts(pts, audio_time_base, start_pts, video_time_base) < 0) {
                        continue;
                    }
                    if (end_pts) |epts| {
                        // Audio is done if the packet pts is after the end_pts.
                        if (c.av_compare_ts(pts, audio_time_base, epts, video_time_base) >= 0) {
                            audio_done = true;
                            continue;
                        }
                    }
                    try self.write_packet(packet, output_audio_stream, start_pts);
                    continue;
                }
            }
        }

        // If somehow we didn't get any video then return an error.
        if (!video_started) {
            return error.MissingStartKeyframe;
        }
    }

    fn write_packet(self: *Self, packet: *c.AVPacket, output_stream: *c.AVStream, start_pts: i64) !void {
        if (packet.pts == c.AV_NOPTS_VALUE or packet.dts == c.AV_NOPTS_VALUE) {
            return error.MissingPacketTimestamp;
        }
        const input_stream = self.input_context.streams[@intCast(packet.*.stream_index)];

        const start_timestamp = c.av_rescale_q(start_pts, self.get_video_time_base(), input_stream.*.time_base);
        if (packet.*.pts != c.AV_NOPTS_VALUE) {
            packet.*.pts -= start_timestamp;
        }
        if (packet.*.dts != c.AV_NOPTS_VALUE) {
            packet.*.dts -= start_timestamp;
        }

        c.av_packet_rescale_ts(
            packet,
            input_stream.*.time_base,
            output_stream.time_base,
        );

        packet.*.stream_index = output_stream.index;
        packet.*.pos = -1;

        try check_err(c.av_interleaved_write_frame(self.output_context, packet));
    }

    /// Seek to the pts, starting at the first keyframe before it.
    fn seek_to_pts(self: *Self, pts: i64) !void {
        try check_err(c.av_seek_frame(
            self.input_context,
            self.video_stream_index,
            pts,
            c.AVSEEK_FLAG_BACKWARD,
        ));
        _ = c.avformat_flush(self.input_context);
    }

    fn get_video_time_base(self: *Self) c.AVRational {
        return self.input_context.*.streams[@intCast(self.video_stream_index)].*.time_base;
    }

    fn start_time_ns(start_time: i64) i64 {
        if (start_time == c.AV_NOPTS_VALUE) {
            return 0;
        }
        return c.av_rescale_q(
            start_time,
            .{ .num = 1, .den = c.AV_TIME_BASE },
            ns_time_base,
        );
    }

    /// Get the packt PTS, returning an error if not found.
    fn packet_pts(packet: *c.AVPacket) !i64 {
        if (packet.pts == c.AV_NOPTS_VALUE) {
            return error.MissingPacketTimestamp;
        }
        return packet.pts;
    }
};

const TestUtil = struct {
    const Fixture = struct {
        input_path: []const u8,
        output_name: []const u8,
        expected_video_codec: c_uint,
        expected_audio_codec: c_uint,
        expected_start_ns: i64,
        expected_end_ns: i64,
    };

    const fixtures = [_]Fixture{
        .{
            .input_path = "./test/sample_video_1_h264.mp4",
            .output_name = "trimmed.mp4",
            .expected_video_codec = c.AV_CODEC_ID_H264,
            .expected_audio_codec = c.AV_CODEC_ID_AAC,
            .expected_start_ns = 1_100_000_000,
            .expected_end_ns = 40_100_000_000,
        },
        .{
            .input_path = "./test/sample_video_1_h265.mkv",
            .output_name = "trimmed.mkv",
            .expected_video_codec = c.AV_CODEC_ID_HEVC,
            .expected_audio_codec = c.AV_CODEC_ID_OPUS,
            .expected_start_ns = 1_100_000_000,
            .expected_end_ns = 63_600_000_000,
        },
        .{
            .input_path = "./test/sample_video_1_vp9.webm",
            .output_name = "trimmed.webm",
            .expected_video_codec = c.AV_CODEC_ID_VP9,
            .expected_audio_codec = c.AV_CODEC_ID_OPUS,
            .expected_start_ns = 0,
            .expected_end_ns = 38_400_000_000,
        },
    };
};

// This is essentially a snapshot test. It tests for time ranges, which are
// hard coded in TestUtil. If any of these tests break, then there is likely a
// regression.
test "FileRemuxer - remuxes and trims on keyframes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const requested_start_time_ns = 1_200_000_000;
    const requested_end_time_ns = 30_000_000_000;

    var tmp_dir_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &tmp_dir_path_buffer);
    const tmp_dir_path = tmp_dir_path_buffer[0..tmp_dir_path_len];

    for (TestUtil.fixtures) |fixture| {
        const output_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, fixture.output_name });
        defer allocator.free(output_path);

        {
            var muxer = try FileRemuxer.init(allocator, fixture.input_path, output_path);
            defer muxer.deinit();

            const timeline_start_ns = FileRemuxer.start_time_ns(muxer.input_context.start_time);
            const video_time_base = muxer.get_video_time_base();
            var boundary_packet = c.av_packet_alloc() orelse return error.FFmpegError;
            defer c.av_packet_free(&boundary_packet);

            // ----------------------------------------------------------------------------
            // Should be trimmed on keyframes.
            // ----------------------------------------------------------------------------
            const trim_range = try muxer.find_exact_trim_range(
                boundary_packet,
                c.av_rescale_q_rnd(timeline_start_ns + requested_start_time_ns, ns_time_base, video_time_base, c.AV_ROUND_DOWN),
                c.av_rescale_q_rnd(timeline_start_ns + requested_end_time_ns, ns_time_base, video_time_base, c.AV_ROUND_UP),
            );
            try std.testing.expectEqual(
                fixture.expected_start_ns,
                c.av_rescale_q(trim_range.start_pts, video_time_base, ns_time_base) - timeline_start_ns,
            );
            try std.testing.expectEqual(
                fixture.expected_end_ns,
                c.av_rescale_q(trim_range.end_pts.?, video_time_base, ns_time_base) - timeline_start_ns,
            );
            // Exact keyframes and requests just after them must retain that keyframe.
            for ([_]i64{ 0, 1 }) |offset_ns| {
                const boundary_range = try muxer.find_exact_trim_range(
                    boundary_packet,
                    c.av_rescale_q_rnd(timeline_start_ns + fixture.expected_start_ns + offset_ns, ns_time_base, video_time_base, c.AV_ROUND_DOWN),
                    c.av_rescale_q_rnd(timeline_start_ns + requested_end_time_ns, ns_time_base, video_time_base, c.AV_ROUND_UP),
                );
                try std.testing.expectEqual(trim_range.start_pts, boundary_range.start_pts);
            }
            try muxer.remux_range(requested_start_time_ns, requested_end_time_ns);
            try std.testing.expect(muxer.output_context.pb == null);
        }

        // ----------------------------------------------------------------------------
        // After remuxing, then we test the output file.
        // ----------------------------------------------------------------------------
        const output_path_z = try allocator.dupeSentinel(u8, output_path, 0);
        defer allocator.free(output_path_z);
        var output_context: ?*c.AVFormatContext = null;
        try check_err(c.avformat_open_input(&output_context, output_path_z.ptr, null, null));
        try check_err(c.avformat_find_stream_info(output_context, null));
        defer c.avformat_close_input(&output_context);

        const video_index = c.av_find_best_stream(output_context, c.AVMEDIA_TYPE_VIDEO, -1, -1, null, 0);
        const audio_index = c.av_find_best_stream(output_context, c.AVMEDIA_TYPE_AUDIO, -1, video_index, null, 0);
        try std.testing.expect(video_index >= 0);
        try std.testing.expect(audio_index >= 0);

        // ----------------------------------------------------------------------------
        // Expect codecs to be the same.
        // ----------------------------------------------------------------------------
        try std.testing.expectEqual(
            fixture.expected_video_codec,
            output_context.?.*.streams[@intCast(video_index)].*.codecpar.*.codec_id,
        );
        try std.testing.expectEqual(
            fixture.expected_audio_codec,
            output_context.?.*.streams[@intCast(audio_index)].*.codecpar.*.codec_id,
        );

        // ----------------------------------------------------------------------------
        // Ensure that the first video packet is a keyframe.
        // ----------------------------------------------------------------------------
        var packet = c.av_packet_alloc() orelse return error.FFmpegError;
        defer c.av_packet_free(&packet);
        while (true) {
            const read_result = c.av_read_frame(output_context, packet);
            defer c.av_packet_unref(packet);
            if (read_result == c.AVERROR_EOF) {
                return error.MissingOutputVideoPacket;
            }
            try check_err(read_result);
            if (packet.*.stream_index == video_index) {
                try std.testing.expect(packet.*.flags & c.AV_PKT_FLAG_KEY != 0);
                try std.testing.expect(packet.*.size > 0);
                break;
            }
        }
    }
}

test "FileRemuxer - rejects invalid ranges and preserves trims within a GOP" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var tmp_dir_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &tmp_dir_path_buffer);
    const output_path = try std.fs.path.join(
        allocator,
        &.{ tmp_dir_path_buffer[0..tmp_dir_path_len], "invalid.mp4" },
    );
    defer allocator.free(output_path);

    var invalid_muxer = try FileRemuxer.init(allocator, TestUtil.fixtures[0].input_path, output_path);
    defer invalid_muxer.deinit();
    try std.testing.expectError(error.InvalidTrimRange, invalid_muxer.remux_range(10, 10));

    var short_muxer = try FileRemuxer.init(allocator, TestUtil.fixtures[0].input_path, output_path);
    defer short_muxer.deinit();
    try short_muxer.remux_range(10_000_000_000, 11_000_000_000);
    try std.testing.expect(short_muxer.output_context.pb == null);
}
