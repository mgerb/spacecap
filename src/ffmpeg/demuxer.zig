const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("ffmpeg_c");
const check_err = @import("./util.zig").check_err;

/// Open a file and demux audio and video streams.
pub const Demuxer = struct {
    const Self = @This();

    allocator: Allocator,
    file_path: [:0]u8,
    format_context: ?*c.AVFormatContext,
    packet: [*c]c.AVPacket,
    video_stream_index: ?c_int,
    audio_stream_index: ?c_int,

    pub fn init(allocator: Allocator, file_path: []const u8) !Self {
        const file_path_z = try allocator.dupeSentinel(u8, file_path, 0);
        errdefer allocator.free(file_path_z);

        var format_context: ?*c.AVFormatContext = null;
        try check_err(c.avformat_open_input(&format_context, file_path_z.ptr, null, null));
        errdefer c.avformat_close_input(&format_context);

        try check_err(c.avformat_find_stream_info(format_context, null));

        const video_stream_result = c.av_find_best_stream(
            format_context,
            c.AVMEDIA_TYPE_VIDEO,
            -1,
            -1,
            null,
            0,
        );
        const video_stream_index: ?c_int = if (video_stream_result >= 0) video_stream_result else null;

        const audio_stream_result = c.av_find_best_stream(
            format_context,
            c.AVMEDIA_TYPE_AUDIO,
            -1,
            -1,
            null,
            0,
        );
        const audio_stream_index: ?c_int = if (audio_stream_result >= 0) audio_stream_result else null;

        if (video_stream_index == null and audio_stream_index == null) return error.MissingMediaStream;

        return .{
            .allocator = allocator,
            .file_path = file_path_z,
            .format_context = format_context,
            .packet = c.av_packet_alloc() orelse return error.FFmpegError,
            .video_stream_index = video_stream_index,
            .audio_stream_index = audio_stream_index,
        };
    }

    pub fn deinit(self: *Self) void {
        c.av_packet_free(&self.packet);
        c.avformat_close_input(&self.format_context);
        self.allocator.free(self.file_path);
    }

    pub fn video_codec_parameters(self: *const Self) ?*c.AVCodecParameters {
        const video_stream_index = self.video_stream_index orelse return null;
        const video_stream = self.format_context.?.*.streams[@intCast(video_stream_index)];
        return video_stream.*.codecpar;
    }

    pub fn video_time_base(self: *const Self) ?c.AVRational {
        const video_stream_index = self.video_stream_index orelse return null;
        const video_stream = self.format_context.?.*.streams[@intCast(video_stream_index)];
        return video_stream.*.time_base;
    }

    pub fn audio_codec_parameters(self: *const Self) ?*c.AVCodecParameters {
        const audio_stream_index = self.audio_stream_index orelse return null;
        const audio_stream = self.format_context.?.*.streams[@intCast(audio_stream_index)];
        return audio_stream.*.codecpar;
    }

    pub fn audio_time_base(self: *const Self) ?c.AVRational {
        const audio_stream_index = self.audio_stream_index orelse return null;
        const audio_stream = self.format_context.?.*.streams[@intCast(audio_stream_index)];
        return audio_stream.*.time_base;
    }

    pub fn duration_ns(self: *const Self) ?i64 {
        const duration = self.format_context.?.*.duration;
        if (duration == c.AV_NOPTS_VALUE or duration <= 0) return null;
        return c.av_rescale_q(duration, .{
            .num = 1,
            .den = c.AV_TIME_BASE,
        }, .{
            .num = 1,
            .den = std.time.ns_per_s,
        });
    }

    pub fn start_time_ns(self: *const Self) i64 {
        const start_time = self.format_context.?.*.start_time;
        if (start_time == c.AV_NOPTS_VALUE) return 0;
        return c.av_rescale_q(start_time, .{
            .num = 1,
            .den = c.AV_TIME_BASE,
        }, .{
            .num = 1,
            .den = std.time.ns_per_s,
        });
    }

    pub fn seek_video(self: *Self, args: struct {
        timestamp_ns: i64,
        seek_before: bool = false,
    }) !void {
        const stream_index = self.video_stream_index orelse return error.MissingVideoStream;
        try self.seek_stream(.{
            .stream_index = stream_index,
            .timestamp_ns = args.timestamp_ns,
            .seek_before = args.seek_before,
        });
    }

    pub fn seek_audio(self: *Self, args: struct {
        timestamp_ns: i64,
        seek_before: bool = false,
    }) !void {
        const stream_index = self.audio_stream_index orelse return error.MissingAudioStream;
        try self.seek_stream(.{
            .stream_index = stream_index,
            .timestamp_ns = args.timestamp_ns,
            .seek_before = args.seek_before,
        });
    }

    /// The returned packet is owned by the demuxer and
    /// remains valid until the next call to
    /// next_video_packet or deinit.
    pub fn next_video_packet(self: *Self) !?*c.AVPacket {
        const video_stream_index = self.video_stream_index orelse return error.MissingVideoStream;
        return self.next_packet_for_stream(video_stream_index);
    }

    /// The returned packet is owned by the demuxer and
    /// remains valid until the next call to
    /// next_audio_packet or deinit.
    pub fn next_audio_packet(self: *Self) !?*c.AVPacket {
        const audio_stream_index = self.audio_stream_index orelse return error.MissingAudioStream;
        return self.next_packet_for_stream(audio_stream_index);
    }

    fn next_packet_for_stream(self: *Self, stream_index: c_int) !?*c.AVPacket {
        c.av_packet_unref(self.packet);

        while (true) {
            const read_ret = c.av_read_frame(self.format_context, self.packet);
            if (read_ret == c.AVERROR_EOF) return null;
            try check_err(read_ret);

            if (self.packet.*.stream_index == stream_index) {
                return self.packet;
            }

            c.av_packet_unref(self.packet);
        }
    }

    fn seek_stream(self: *Self, args: struct {
        stream_index: c_int,
        timestamp_ns: i64,
        seek_before: bool = false,
    }) !void {
        const stream = self.format_context.?.*.streams[@intCast(args.stream_index)];
        var timestamp = c.av_rescale_q(args.timestamp_ns, .{
            .num = 1,
            .den = std.time.ns_per_s,
        }, stream.*.time_base);

        if (args.seek_before) {
            timestamp -= 1;
        }

        try check_err(c.av_seek_frame(
            self.format_context,
            args.stream_index,
            timestamp,
            c.AVSEEK_FLAG_BACKWARD,
        ));
        c.av_packet_unref(self.packet);
    }
};

const TestUtil = struct {
    // NOTE: All these tests are based on this file. If this file ever changes,
    // then hard coded values in the tests will need to be updated.
    const sample_file_path_h264_mp4 = "./test/sample_video_1_h264.mp4";
    const sample_file_path_h265_mkv = "./test/sample_video_1_h265.mkv";
    const sample_file_path_vp9_webm = "./test/sample_video_1_vp9.webm";
};

test "Demuxer - video_codec_parameters" {
    inline for (.{
        .{ TestUtil.sample_file_path_h264_mp4, c.AV_CODEC_ID_H264 },
        .{ TestUtil.sample_file_path_h265_mkv, c.AV_CODEC_ID_H265 },
        .{ TestUtil.sample_file_path_vp9_webm, c.AV_CODEC_ID_VP9 },
    }) |val| {
        const file_path = val.@"0";
        const expected_codec = val.@"1";
        var demuxer = try Demuxer.init(std.testing.allocator, file_path);
        defer demuxer.deinit();

        const codec_parameters = demuxer.video_codec_parameters().?;

        try std.testing.expectEqual(@as(c_uint, expected_codec), codec_parameters.*.codec_id);
        try std.testing.expectEqual(320, codec_parameters.*.width);
        try std.testing.expectEqual(224, codec_parameters.*.height);
    }
}

test "Demuxer - video_time_base" {
    inline for (.{
        .{ TestUtil.sample_file_path_h264_mp4, 10_240 },
        .{ TestUtil.sample_file_path_h265_mkv, 1000 },
        .{ TestUtil.sample_file_path_vp9_webm, 1000 },
    }) |val| {
        const file_path = val.@"0";
        const expected_time_base_den = val.@"1";
        var demuxer = try Demuxer.init(std.testing.allocator, file_path);
        defer demuxer.deinit();

        const time_base = demuxer.video_time_base().?;
        try std.testing.expectEqual(1, time_base.num);
        try std.testing.expectEqual(expected_time_base_den, time_base.den);
    }
}

test "Demuxer - audio_codec_parameters" {
    inline for (.{
        .{ TestUtil.sample_file_path_h264_mp4, c.AV_CODEC_ID_AAC, 22050 },
        .{ TestUtil.sample_file_path_h265_mkv, c.AV_CODEC_ID_OPUS, 48000 },
        .{ TestUtil.sample_file_path_vp9_webm, c.AV_CODEC_ID_OPUS, 48000 },
    }) |val| {
        const file_path = val.@"0";
        const expected_codec = val.@"1";
        const expected_sample_rate = val.@"2";
        var demuxer = try Demuxer.init(std.testing.allocator, file_path);
        defer demuxer.deinit();

        const codec_parameters = demuxer.audio_codec_parameters().?;
        try std.testing.expectEqual(@as(c_uint, expected_codec), codec_parameters.*.codec_id);
        try std.testing.expectEqual(expected_sample_rate, codec_parameters.*.sample_rate);
        try std.testing.expectEqual(1, codec_parameters.*.ch_layout.nb_channels);
    }
}

test "Demuxer - audio_time_base" {
    inline for (.{
        .{ TestUtil.sample_file_path_h264_mp4, 22050 },
        .{ TestUtil.sample_file_path_h265_mkv, 1000 },
        .{ TestUtil.sample_file_path_vp9_webm, 1000 },
    }) |val| {
        const file_path = val.@"0";
        const expected_time_base_den = val.@"1";
        var demuxer = try Demuxer.init(std.testing.allocator, file_path);
        defer demuxer.deinit();

        const time_base = demuxer.audio_time_base().?;
        try std.testing.expectEqual(1, time_base.num);
        try std.testing.expectEqual(expected_time_base_den, time_base.den);
    }
}

test "Demuxer - duration_ns" {
    inline for (.{
        .{ TestUtil.sample_file_path_h264_mp4, 71_599_773_000 },
        .{ TestUtil.sample_file_path_h265_mkv, 71_607_000_000 },
        .{ TestUtil.sample_file_path_vp9_webm, 71_607_000_000 },
    }) |val| {
        const file_path = val.@"0";
        const expected_duration_ns = val.@"1";
        var demuxer = try Demuxer.init(std.testing.allocator, file_path);
        defer demuxer.deinit();

        const duration_ns = demuxer.duration_ns().?;
        try std.testing.expectEqual(expected_duration_ns, duration_ns);
    }
}

test "Demuxer - start_time_ns" {
    inline for (.{
        TestUtil.sample_file_path_h264_mp4,
        TestUtil.sample_file_path_h265_mkv,
        TestUtil.sample_file_path_vp9_webm,
    }) |file_path| {
        var demuxer = try Demuxer.init(std.testing.allocator, file_path);
        defer demuxer.deinit();

        try std.testing.expectEqual(0, demuxer.start_time_ns());
    }
}

test "Demuxer - next_video_packet" {
    inline for (.{
        .{ TestUtil.sample_file_path_h264_mp4, 9_900_000_000 },
        .{ TestUtil.sample_file_path_h265_mkv, 9_800_000_000 },
        .{ TestUtil.sample_file_path_vp9_webm, 10_000_000_000 },
    }) |val| {
        const file_path = val.@"0";
        const expected_timestamp_ns = val.@"1";
        var demuxer = try Demuxer.init(std.testing.allocator, file_path);
        defer demuxer.deinit();

        var packet = (try demuxer.next_video_packet()).?;
        try std.testing.expectEqual(0, packet.*.stream_index);
        try std.testing.expect(packet.*.size > 0);
        var packet_timestamp_ns = c.av_rescale_q(packet.*.pts, demuxer.video_time_base().?, .{
            .num = 1,
            .den = std.time.ns_per_s,
        });
        try std.testing.expectEqual(0, packet_timestamp_ns);

        // Skip some packets and then check the timestamp again.
        for (0..100) |_| {
            packet = (try demuxer.next_video_packet()).?;
            packet_timestamp_ns = c.av_rescale_q(packet.*.pts, demuxer.video_time_base().?, .{
                .num = 1,
                .den = std.time.ns_per_s,
            });
        }
        try std.testing.expectEqual(expected_timestamp_ns, packet_timestamp_ns);
    }
}

test "Demuxer - next_audio_packet" {
    inline for (.{
        .{ TestUtil.sample_file_path_h264_mp4, -46_439_909, 4_597_551_020 },
        .{ TestUtil.sample_file_path_h265_mkv, -7_000_000, 1_994_000_000 },
        .{ TestUtil.sample_file_path_vp9_webm, -7_000_000, 1_994_000_000 },
    }) |val| {
        const file_path = val.@"0";
        const expected_first_timestamp_ns = val.@"1";
        const expected_timestamp_ns = val.@"2";
        var demuxer = try Demuxer.init(std.testing.allocator, file_path);
        defer demuxer.deinit();

        var packet = (try demuxer.next_audio_packet()).?;
        try std.testing.expectEqual(1, packet.*.stream_index);
        try std.testing.expect(packet.*.size > 0);
        var packet_timestamp_ns = c.av_rescale_q(packet.*.pts, demuxer.audio_time_base().?, .{
            .num = 1,
            .den = std.time.ns_per_s,
        });
        try std.testing.expectEqual(expected_first_timestamp_ns, packet_timestamp_ns);

        // Skip some packets and then check the timestamp again.
        for (0..100) |_| {
            packet = (try demuxer.next_audio_packet()).?;
            packet_timestamp_ns = c.av_rescale_q(packet.*.pts, demuxer.audio_time_base().?, .{
                .num = 1,
                .den = std.time.ns_per_s,
            });
        }
        try std.testing.expectEqual(expected_timestamp_ns, packet_timestamp_ns);
    }
}

test "Demuxer - seek_video" {
    inline for (.{
        .{ TestUtil.sample_file_path_h264_mp4, 6_300_000_000 },
        .{ TestUtil.sample_file_path_h265_mkv, 1_100_000_000 },
        .{ TestUtil.sample_file_path_vp9_webm, 0 },
    }) |val| {
        const file_path = val.@"0";
        const expected_timestamp_ns = val.@"1";
        var demuxer = try Demuxer.init(std.testing.allocator, file_path);
        defer demuxer.deinit();

        const seek_timestamp_ns = 10 * std.time.ns_per_s;
        try demuxer.seek_video(.{ .timestamp_ns = seek_timestamp_ns });
        const packet = (try demuxer.next_video_packet()).?;
        try std.testing.expectEqual(0, packet.*.stream_index);
        try std.testing.expect(packet.*.size > 0);
        try std.testing.expect(packet.*.pts != c.AV_NOPTS_VALUE);

        const packet_timestamp_ns = c.av_rescale_q(packet.*.pts, demuxer.video_time_base().?, .{
            .num = 1,
            .den = std.time.ns_per_s,
        });
        try std.testing.expect(packet_timestamp_ns <= seek_timestamp_ns);
        try std.testing.expectEqual(expected_timestamp_ns, packet_timestamp_ns);
    }
}

test "Demuxer - seek_audio" {
    inline for (.{
        .{ TestUtil.sample_file_path_h264_mp4, 9_984_580_499 },
        .{ TestUtil.sample_file_path_h265_mkv, 9_994_000_000 },
        .{ TestUtil.sample_file_path_vp9_webm, 9_994_000_000 },
    }) |val| {
        const file_path = val.@"0";
        const expected_timestamp_ns = val.@"1";
        var demuxer = try Demuxer.init(std.testing.allocator, file_path);
        defer demuxer.deinit();

        const seek_timestamp_ns = 10 * std.time.ns_per_s;
        try demuxer.seek_audio(.{ .timestamp_ns = seek_timestamp_ns });
        const packet = (try demuxer.next_audio_packet()).?;
        try std.testing.expectEqual(1, packet.*.stream_index);
        try std.testing.expect(packet.*.size > 0);
        try std.testing.expect(packet.*.pts != c.AV_NOPTS_VALUE);

        const packet_timestamp_ns = c.av_rescale_q(packet.*.pts, demuxer.audio_time_base().?, .{
            .num = 1,
            .den = std.time.ns_per_s,
        });
        try std.testing.expect(packet_timestamp_ns <= seek_timestamp_ns);
        try std.testing.expectEqual(expected_timestamp_ns, packet_timestamp_ns);
    }
}
