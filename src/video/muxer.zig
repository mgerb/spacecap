const std = @import("std");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const CodecContextInfo = @import("../audio/audio_timeline.zig").CodecContextInfo;
const SampleWindow = @import("../audio/audio_timeline.zig").SampleWindow;
const EncodedAudioPacketNode = @import("../audio/audio_encoder.zig").EncodedAudioPacketNode;
const LinkedListIterator = @import("../util.zig").LinkedListIterator;
const ffmpeg = @import("../ffmpeg.zig").ffmpeg;
const checkErr = @import("../ffmpeg.zig").check_err;

pub const Muxer = struct {
    const Self = @This();

    const PendingVideoPacket = struct {
        data: std.ArrayList(u8),
        is_idr: bool,

        fn init(allocator: Allocator, data: []const u8, is_idr: bool) !@This() {
            var owned = try std.ArrayList(u8).initCapacity(allocator, data.len);
            errdefer owned.deinit(allocator);
            try owned.appendSlice(allocator, data);
            return .{ .data = owned, .is_idr = is_idr };
        }

        fn deinit(self: *@This(), allocator: Allocator) void {
            self.data.deinit(allocator);
        }
    };

    allocator: Allocator,
    fps: u32,
    format_context: *ffmpeg.AVFormatContext,
    file_name: [:0]u8,
    video_stream: *ffmpeg.AVStream,
    audio_stream: ?*ffmpeg.AVStream,
    first_video_time_ns: ?i128 = null,
    audio_start_sample: ?i64 = null,
    audio_end_sample: ?i64 = null,
    pending_video: ?PendingVideoPacket = null,
    previous_pts: i64 = 0,
    last_delta: i64 = 0,
    wrote_trailer: bool = false,

    pub fn init(
        allocator: Allocator,
        file_name_prefix: []const u8,
        header_frame: []const u8,
        audio_codec_context: ?CodecContextInfo,
        width: u32,
        height: u32,
        fps: u32,
        output_directory: []const u8,
    ) !Self {
        var format_context: *ffmpeg.AVFormatContext = undefined;
        try std.fs.cwd().makePath(output_directory);
        const file_name = try get_output_file_name(allocator, file_name_prefix, output_directory);
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
        const extradata: [*c]u8 = @ptrCast(ffmpeg.av_malloc(header_frame.len));
        if (extradata == null) {
            return error.OutOfMemory;
        }
        @memcpy(extradata[0..header_frame.len], header_frame);

        video_codecpar.*.extradata = extradata;
        video_codecpar.*.extradata_size = @intCast(header_frame.len);

        // Convert nanosecond capture timestamps to a muxer-friendly video time base.
        video_stream.*.time_base = ffmpeg.AVRational{ .num = 1, .den = 90_000 };
        video_stream.*.avg_frame_rate = ffmpeg.AVRational{ .num = @intCast(fps), .den = 1 };
        video_stream.*.r_frame_rate = ffmpeg.AVRational{ .num = @intCast(fps), .den = 1 };

        var audio_stream: ?*ffmpeg.AVStream = null;
        if (audio_codec_context) |codec_context| {
            const stream = ffmpeg.avformat_new_stream(format_context, null) orelse return error.FFmpegError;
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
            .fps = fps,
            .format_context = format_context,
            .file_name = file_name,
            .video_stream = video_stream,
            .audio_stream = audio_stream,
        };
    }

    pub fn destroy(self: *Self) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn deinit(self: *Self) void {
        if (self.pending_video) |*pending| {
            pending.deinit(self.allocator);
        }
        if (self.format_context.pb != null) {
            _ = ffmpeg.avio_closep(&self.format_context.pb);
        }
        ffmpeg.avformat_free_context(self.format_context);
        self.allocator.free(self.file_name);
    }

    fn write_video_packet_data(
        self: *Self,
        video_pkt: [*c]ffmpeg.AVPacket,
        data: []const u8,
        is_idr: bool,
        pts: i64,
        duration: i64,
    ) !void {
        video_pkt.*.data = @constCast(data.ptr);
        video_pkt.*.size = @intCast(data.len);
        video_pkt.*.stream_index = self.video_stream.index;
        video_pkt.*.pts = pts;
        video_pkt.*.dts = pts;
        video_pkt.*.duration = duration;
        if (is_idr) {
            video_pkt.*.flags |= ffmpeg.AV_PKT_FLAG_KEY;
        } else {
            video_pkt.*.flags &= ~ffmpeg.AV_PKT_FLAG_KEY;
        }

        const ret = ffmpeg.av_interleaved_write_frame(self.format_context, video_pkt);
        ffmpeg.av_packet_unref(video_pkt);
        try checkErr(ret);
    }

    fn write_audio_packet(self: *Self, pkt: [*c]ffmpeg.AVPacket, packet_node: *EncodedAudioPacketNode, start_sample: i64) !void {
        assert(self.audio_stream != null);
        try checkErr(ffmpeg.av_packet_ref(pkt, @constCast(packet_node.data)));
        pkt.*.stream_index = self.audio_stream.?.*.index;
        pkt.*.pts = packet_node.data.*.pts - start_sample;
        pkt.*.dts = packet_node.data.*.dts - start_sample;
        pkt.*.duration = packet_node.data.*.duration;
        pkt.*.flags = packet_node.data.*.flags;

        const ret = ffmpeg.av_interleaved_write_frame(self.format_context, pkt);
        ffmpeg.av_packet_unref(pkt);
        try checkErr(ret);
    }

    pub fn video_start_time_ns(self: *const Self) ?i128 {
        return self.first_video_time_ns;
    }

    pub fn needs_audio_start_sample(self: *const Self) bool {
        return self.audio_stream != null and self.audio_start_sample == null;
    }

    pub fn set_audio_start_sample(self: *Self, start_sample: i64) void {
        if (self.audio_start_sample == null) {
            self.audio_start_sample = start_sample;
        }
    }

    pub fn set_audio_sample_window(self: *Self, sample_window: SampleWindow) void {
        self.audio_start_sample = sample_window.start_sample;
        self.audio_end_sample = sample_window.end_sample;
    }

    pub fn write_video_packet(self: *Self, data: []const u8, frame_time_ns: i128, is_idr: bool) !void {
        const max_mux_duration: i64 = std.math.maxInt(i32);

        if (self.first_video_time_ns == null) {
            if (!is_idr) return;
            self.first_video_time_ns = frame_time_ns;
        }

        const ns_time_base = ffmpeg.AVRational{ .num = 1, .den = 1_000_000_000 };
        const frame_duration_pts = if (self.fps > 0)
            @max(ffmpeg.av_rescale_q(1, .{ .num = 1, .den = @intCast(self.fps) }, self.video_stream.time_base), 1)
        else
            0;
        const jitter_tolerance_pts = if (self.fps > 0)
            @max(ffmpeg.av_rescale_q(10 * std.time.ns_per_ms, ns_time_base, self.video_stream.time_base), 1)
        else
            0;

        const pts_ns = frame_time_ns - self.first_video_time_ns.?;
        const raw_current_pts: i64 = ffmpeg.av_rescale_q(@intCast(pts_ns), ns_time_base, self.video_stream.time_base);
        const current_pts = apply_jitter_correction_to_pts(
            raw_current_pts,
            if (self.pending_video != null) self.previous_pts else null,
            frame_duration_pts,
            jitter_tolerance_pts,
        );

        if (self.pending_video) |*pending| {
            const duration = if (current_pts > self.previous_pts) current_pts - self.previous_pts else 0;
            const safe_duration = if (duration > max_mux_duration) max_mux_duration else duration;
            var video_pkt = ffmpeg.av_packet_alloc() orelse return error.FFmpegError;
            defer ffmpeg.av_packet_free(&video_pkt);
            try self.write_video_packet_data(video_pkt, pending.data.items, pending.is_idr, self.previous_pts, safe_duration);
            self.last_delta = safe_duration;
            pending.deinit(self.allocator);
            self.pending_video = null;
        }

        self.pending_video = try PendingVideoPacket.init(self.allocator, data, is_idr);
        self.previous_pts = current_pts;
    }

    pub fn write_audio_packets(self: *Self, packets: *std.DoublyLinkedList) !void {
        if (self.audio_stream == null) return;
        const start_sample = self.audio_start_sample orelse return;

        var pkt = ffmpeg.av_packet_alloc() orelse return error.FFmpegError;
        defer ffmpeg.av_packet_free(&pkt);

        var iter = LinkedListIterator(EncodedAudioPacketNode).init(packets);
        while (iter.next()) |packet_node| {
            const packet_start = packet_node.data.*.pts;
            const packet_end = packet_start + packet_node.data.*.duration;
            if (packet_end <= start_sample) continue;
            if (self.audio_end_sample) |end_sample| {
                if (packet_start >= end_sample) break;
            }
            try self.write_audio_packet(pkt, packet_node, start_sample);
        }
    }

    pub fn flush_video(self: *Self) !void {
        if (self.pending_video) |*pending| {
            var video_pkt = ffmpeg.av_packet_alloc() orelse return error.FFmpegError;
            defer ffmpeg.av_packet_free(&video_pkt);
            try self.write_video_packet_data(video_pkt, pending.data.items, pending.is_idr, self.previous_pts, self.last_delta);
            pending.deinit(self.allocator);
            self.pending_video = null;
        }
    }

    pub fn finish(self: *Self) !void {
        try self.flush_video();
        try self.write_trailer();
    }

    fn write_trailer(self: *Self) !void {
        if (self.wrote_trailer) return;
        const ret = ffmpeg.av_write_trailer(self.format_context);
        try checkErr(ret);
        self.wrote_trailer = true;
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

fn get_output_file_name(
    allocator: Allocator,
    file_name_prefix: []const u8,
    output_directory: []const u8,
) ![:0]u8 {
    const base_name = try std.fmt.allocPrint(allocator, "{s}_{}.mp4", .{ file_name_prefix, std.time.nanoTimestamp() });
    defer allocator.free(base_name);

    const path = try std.fs.path.join(allocator, &.{ output_directory, base_name });
    defer allocator.free(path);
    return allocator.dupeZ(u8, path);
}

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
