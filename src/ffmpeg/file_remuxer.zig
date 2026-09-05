const std = @import("std");
const c = @import("ffmpeg_c");
const check_err = @import("./util.zig").check_err;
const ns_time_base = @import("./util.zig").ns_time_base;

/// Remux a keyframe-aligned section of a media file without re-encoding it.
pub const FileRemuxer = struct {
    const Self = @This();

    const Boundary = struct {
        /// Raw presentation timestamp of the packet.
        pts: i64,
        /// Rescaled pts in ns.
        timestamp_ns: i64,
    };

    const Boundaries = struct {
        start: Boundary,
        /// Null when no keyframe exists at or after the requested end time; copy through EOF instead.
        end: ?Boundary,
    };

    allocator: std.mem.Allocator,
    input_path: [:0]u8,
    output_path: [:0]u8,
    input_context: *c.AVFormatContext,
    output_context: *c.AVFormatContext,
    video_stream_index: c_int,
    audio_stream_index: ?c_int,
    output_video_stream: *c.AVStream,
    output_audio_stream: ?*c.AVStream = null,
    last_video_dts: ?i64 = null,
    last_video_duration: i64 = 0,

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
        if (self.output_context.pb != null) {
            _ = c.avio_closep(&self.output_context.pb);
        }
        c.avformat_free_context(self.output_context);
        c.avformat_close_input(@ptrCast(&self.input_context));
        self.allocator.free(self.output_path);
        self.allocator.free(self.input_path);
    }

    pub fn remux(self: *Self, trim_start_ns: i64, trim_end_ns: i64) !void {
        if (trim_start_ns < 0 or trim_end_ns <= trim_start_ns) {
            return error.InvalidTrimRange;
        }

        var packet = c.av_packet_alloc() orelse return error.FFmpegError;
        defer c.av_packet_free(&packet);

        const timeline_start_ns = start_time_ns(self.input_context.*.start_time);
        const requested_start_ns = try std.math.add(i64, timeline_start_ns, trim_start_ns);
        const requested_end_ns = try std.math.add(i64, timeline_start_ns, trim_end_ns);
        const boundaries = try self.find_boundaries(packet, requested_start_ns, requested_end_ns);
        if (boundaries.end) |end| {
            if (end.timestamp_ns <= boundaries.start.timestamp_ns) {
                return error.EmptyKeyframeRange;
            }
        }

        try self.seek_to_ns(packet, boundaries.start.timestamp_ns);
        try self.copy_packets(packet, boundaries);
        try check_err(c.av_write_trailer(self.output_context));
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

    fn find_boundaries(self: *Self, packet: *c.AVPacket, requested_start_ns: i64, requested_end_ns: i64) !Boundaries {
        try self.seek_to_ns(packet, requested_start_ns);

        var start: ?Boundary = null;
        while (true) {
            const read_result = c.av_read_frame(self.input_context, packet);
            if (read_result == c.AVERROR_EOF) {
                break;
            }
            try check_err(read_result);
            defer c.av_packet_unref(packet);

            const packet_data = packet.*;
            if (packet_data.stream_index != self.video_stream_index or
                packet_data.flags & c.AV_PKT_FLAG_KEY == 0)
            {
                continue;
            }

            const timestamp_ticks = try packet_presentation_timestamp(packet_data);
            const timestamp_ns = self.video_timestamp_ns(timestamp_ticks);
            if (timestamp_ns < requested_start_ns) {
                continue;
            }

            if (start == null) {
                start = .{ .pts = timestamp_ticks, .timestamp_ns = timestamp_ns };
            }
            if (timestamp_ns >= requested_end_ns) {
                return .{ .start = start.?, .end = .{
                    .pts = timestamp_ticks,
                    .timestamp_ns = timestamp_ns,
                } };
            }
        }

        return .{
            .start = start orelse return error.MissingStartKeyframe,
            .end = null,
        };
    }

    fn copy_packets(self: *Self, packet: *c.AVPacket, boundaries: Boundaries) !void {
        var video_started = false;
        var video_done = false;
        var audio_done = self.output_audio_stream == null;

        while (!video_done or !audio_done) {
            const read_result = c.av_read_frame(self.input_context, packet);
            if (read_result == c.AVERROR_EOF) {
                break;
            }
            try check_err(read_result);
            errdefer c.av_packet_unref(packet);

            const packet_data = packet.*;

            // ----------------------------------------------------------------------------
            // Video
            // ----------------------------------------------------------------------------
            if (packet_data.stream_index == self.video_stream_index) {
                if (video_done) {
                    c.av_packet_unref(packet);
                    continue;
                }
                const timestamp = try packet_presentation_timestamp(packet_data);
                if (!video_started) {
                    if (packet_data.flags & c.AV_PKT_FLAG_KEY == 0 or timestamp != boundaries.start.pts) {
                        c.av_packet_unref(packet);
                        continue;
                    }
                    video_started = true;
                }
                if (packet_data.pts != c.AV_NOPTS_VALUE and
                    self.video_timestamp_ns(packet_data.pts) < boundaries.start.timestamp_ns)
                {
                    c.av_packet_unref(packet);
                    continue;
                }
                if (boundaries.end) |end| {
                    if (packet_data.flags & c.AV_PKT_FLAG_KEY != 0 and timestamp == end.pts) {
                        video_done = true;
                        c.av_packet_unref(packet);
                        continue;
                    }
                }
                try self.write_packet(packet, self.output_video_stream, boundaries.start.timestamp_ns);
                continue;
            }

            // ----------------------------------------------------------------------------
            // Audio
            // ----------------------------------------------------------------------------
            if (self.output_audio_stream) |output_audio_stream| {
                if (packet_data.stream_index == self.audio_stream_index.?) {
                    if (audio_done) {
                        c.av_packet_unref(packet);
                        continue;
                    }
                    const timestamp = try packet_presentation_timestamp(packet_data);
                    const timestamp_ns = c.av_rescale_q(timestamp, self.input_context.streams[@intCast(self.audio_stream_index.?)].*.time_base, ns_time_base);
                    if (timestamp_ns < boundaries.start.timestamp_ns) {
                        c.av_packet_unref(packet);
                        continue;
                    }
                    if (boundaries.end) |end| {
                        if (timestamp_ns >= end.timestamp_ns) {
                            audio_done = true;
                            c.av_packet_unref(packet);
                            continue;
                        }
                    }
                    try self.write_packet(packet, output_audio_stream, boundaries.start.timestamp_ns);
                    continue;
                }
            }

            c.av_packet_unref(packet);
        }

        if (!video_started) {
            return error.MissingStartKeyframe;
        }
    }

    fn write_packet(self: *Self, packet: *c.AVPacket, output_stream: *c.AVStream, start_ns: i64) !void {
        const input_stream = self.input_context.streams[@intCast(packet.*.stream_index)];
        if (packet.*.dts == c.AV_NOPTS_VALUE) {
            if (input_stream.*.index == self.video_stream_index) {
                if (self.last_video_dts) |last_video_dts| {
                    packet.*.dts = last_video_dts + @max(self.last_video_duration, 1);
                } else if (packet.*.pts != c.AV_NOPTS_VALUE) {
                    const video_delay = @max(input_stream.*.codecpar.*.video_delay, 0);
                    packet.*.dts = packet.*.pts -
                        (@max(packet.*.duration, 1) * video_delay);
                }
            } else if (packet.*.pts != c.AV_NOPTS_VALUE) {
                packet.*.dts = packet.*.pts;
            }
        }

        if (input_stream.*.index == self.video_stream_index) {
            self.last_video_dts = packet.*.dts;
            self.last_video_duration = packet.*.duration;
        }

        const start_timestamp = c.av_rescale_q(start_ns, ns_time_base, input_stream.*.time_base);
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

    /// Seek to the timestamp, starting at the first keyframe before it.
    fn seek_to_ns(self: *Self, packet: *c.AVPacket, timestamp_ns: i64) !void {
        const video_stream = self.input_context.*.streams[@intCast(self.video_stream_index)];

        try check_err(c.av_seek_frame(
            self.input_context,
            self.video_stream_index,
            c.av_rescale_q(timestamp_ns, ns_time_base, video_stream.*.time_base),
            c.AVSEEK_FLAG_BACKWARD,
        ));
        _ = c.avformat_flush(self.input_context);
        c.av_packet_unref(packet);
    }

    fn video_timestamp_ns(self: *const Self, timestamp: i64) i64 {
        const stream = self.input_context.*.streams[@intCast(self.video_stream_index)];
        return c.av_rescale_q(timestamp, stream.*.time_base, ns_time_base);
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

    fn packet_presentation_timestamp(packet: c.AVPacket) !i64 {
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
            .expected_start_ns = 2_500_000_000,
            .expected_end_ns = 40_100_000_000,
        },
        .{
            .input_path = "./test/sample_video_1_h265.mkv",
            .output_name = "trimmed.mkv",
            .expected_video_codec = c.AV_CODEC_ID_HEVC,
            .expected_audio_codec = c.AV_CODEC_ID_OPUS,
            .expected_start_ns = 26_100_000_000,
            .expected_end_ns = 51_100_000_000,
        },
        .{
            .input_path = "./test/sample_video_1_vp9.webm",
            .output_name = "trimmed.webm",
            .expected_video_codec = c.AV_CODEC_ID_VP9,
            .expected_audio_codec = c.AV_CODEC_ID_OPUS,
            .expected_start_ns = 12_800_000_000,
            .expected_end_ns = 38_400_000_000,
        },
    };
};

test "FileRemuxer - remuxes keyframe-aligned MP4 MKV and WebM ranges" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var tmp_dir_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &tmp_dir_path_buffer);
    const tmp_dir_path = tmp_dir_path_buffer[0..tmp_dir_path_len];

    for (TestUtil.fixtures) |fixture| {
        const output_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, fixture.output_name });
        defer allocator.free(output_path);

        var muxer = try FileRemuxer.init(allocator, fixture.input_path, output_path);
        errdefer muxer.deinit();
        const timeline_start_ns = FileRemuxer.start_time_ns(muxer.input_context.start_time);
        var boundary_packet = c.av_packet_alloc() orelse return error.FFmpegError;
        defer c.av_packet_free(&boundary_packet);
        const boundaries = try muxer.find_boundaries(
            boundary_packet,
            timeline_start_ns + 1_200_000_000,
            timeline_start_ns + 30_000_000_000,
        );
        try std.testing.expectEqual(fixture.expected_start_ns, boundaries.start.timestamp_ns - timeline_start_ns);
        try std.testing.expectEqual(fixture.expected_end_ns, boundaries.end.?.timestamp_ns - timeline_start_ns);
        try muxer.remux(1_200_000_000, 30_000_000_000);
        muxer.deinit();

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
        try std.testing.expectEqual(
            fixture.expected_video_codec,
            output_context.?.*.streams[@intCast(video_index)].*.codecpar.*.codec_id,
        );
        try std.testing.expectEqual(
            fixture.expected_audio_codec,
            output_context.?.*.streams[@intCast(audio_index)].*.codecpar.*.codec_id,
        );

        var packet = c.av_packet_alloc() orelse return error.FFmpegError;
        defer c.av_packet_free(&packet);
        while (true) {
            const read_result = c.av_read_frame(output_context, packet);
            if (read_result == c.AVERROR_EOF) {
                return error.MissingOutputVideoPacket;
            }
            try check_err(read_result);
            if (packet.*.stream_index == video_index) {
                try std.testing.expect(packet.*.flags & c.AV_PKT_FLAG_KEY != 0);
                try std.testing.expect(packet.*.size > 0);
                break;
            }
            c.av_packet_unref(packet);
        }
    }
}

test "FileRemuxer - rejects invalid and empty keyframe ranges" {
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
    try std.testing.expectError(error.InvalidTrimRange, invalid_muxer.remux(10, 10));

    var empty_muxer = try FileRemuxer.init(allocator, TestUtil.fixtures[0].input_path, output_path);
    defer empty_muxer.deinit();
    try std.testing.expectError(
        error.EmptyKeyframeRange,
        empty_muxer.remux(10_000_000_000, 11_000_000_000),
    );
}
