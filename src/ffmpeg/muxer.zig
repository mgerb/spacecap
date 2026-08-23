const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Util = @import("../util.zig");
const LinkedListIterator = Util.LinkedListIterator;
const c = @import("ffmpeg_c");
const check_err = @import("./util.zig").check_err;
const AudioEncoder = @import("./audio_encoder.zig").AudioEncoder;

pub const Muxer = struct {
    const Self = @This();

    const PendingVideoPacket = struct {
        allocator: Allocator,
        data: []const u8,
        is_idr: bool,

        // Create new video packet. Takes ownership of data.
        fn init(allocator: Allocator, data: []const u8, is_idr: bool) !@This() {
            return .{
                .allocator = allocator,
                .data = data,
                .is_idr = is_idr,
            };
        }

        fn deinit(self: *@This()) void {
            self.allocator.free(self.data);
        }
    };

    allocator: Allocator,
    io: std.Io,
    fps: u32,
    format_context: *c.AVFormatContext,
    file_name: [:0]u8,
    video_stream: *c.AVStream,
    audio_stream: ?*c.AVStream,
    first_video_time_ns: ?i128 = null,
    audio_start_sample: ?i64 = null,
    audio_end_sample: ?i64 = null,
    pending_video: ?PendingVideoPacket = null,
    previous_pts: i64 = 0,
    last_delta: i64 = 0,
    wrote_trailer: bool = false,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        file_name_prefix: []const u8,
        header_frame: []const u8,
        audio_codec_context: ?AudioEncoder.CodecContextInfo,
        width: u32,
        height: u32,
        fps: u32,
        output_directory: []const u8,
    ) !Self {
        var format_context: *c.AVFormatContext = undefined;
        try std.Io.Dir.cwd().createDirPath(io, output_directory);
        const file_name = try get_output_file_name(allocator, io, file_name_prefix, output_directory);
        errdefer allocator.free(file_name);

        var ret = c.avformat_alloc_output_context2(@ptrCast(&format_context), null, "mp4", file_name);
        try check_err(ret);
        errdefer {
            if (format_context.pb != null) {
                _ = c.avio_closep(&format_context.pb);
            }
            c.avformat_free_context(format_context);
        }

        // Configure the H264 video stream as passthrough of the encoded bitstream.
        const video_stream = c.avformat_new_stream(format_context, null) orelse return error.FFmpegError;

        const video_codecpar = video_stream.*.codecpar;
        video_codecpar.*.codec_id = c.AV_CODEC_ID_H264;
        video_codecpar.*.codec_type = c.AVMEDIA_TYPE_VIDEO;
        video_codecpar.*.width = @intCast(width);
        video_codecpar.*.height = @intCast(height);

        // ffmpeg frees this memory when it's done so we need to copy it.
        const extradata: [*c]u8 = @ptrCast(c.av_malloc(header_frame.len));
        if (extradata == null) {
            return error.OutOfMemory;
        }
        @memcpy(extradata[0..header_frame.len], header_frame);

        video_codecpar.*.extradata = extradata;
        video_codecpar.*.extradata_size = @intCast(header_frame.len);

        // Convert nanosecond capture timestamps to a muxer-friendly video time base.
        video_stream.*.time_base = c.AVRational{ .num = 1, .den = 90_000 };
        video_stream.*.avg_frame_rate = c.AVRational{ .num = @intCast(fps), .den = 1 };
        video_stream.*.r_frame_rate = c.AVRational{ .num = @intCast(fps), .den = 1 };

        var audio_stream: ?*c.AVStream = null;
        if (audio_codec_context) |codec_context| {
            const stream = c.avformat_new_stream(format_context, null) orelse return error.FFmpegError;
            try check_err(c.avcodec_parameters_from_context(stream.*.codecpar, codec_context.audio_codec_ctx));
            stream.*.time_base = codec_context.time_base;
            audio_stream = stream;
        }

        if (format_context.oformat.*.flags & c.AVFMT_NOFILE == 0) {
            ret = c.avio_open(&format_context.pb, file_name, c.AVIO_FLAG_WRITE);
            try check_err(ret);
        }

        // Write container headers once streams are configured.
        ret = c.avformat_write_header(format_context, null);
        try check_err(ret);

        return .{
            .allocator = allocator,
            .io = io,
            .fps = fps,
            .format_context = format_context,
            .file_name = file_name,
            .video_stream = video_stream,
            .audio_stream = audio_stream,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.pending_video) |*pending| {
            pending.deinit();
        }
        if (self.format_context.pb != null) {
            _ = c.avio_closep(&self.format_context.pb);
        }
        c.avformat_free_context(self.format_context);
        self.allocator.free(self.file_name);
    }

    fn write_video_packet_data(
        self: *Self,
        video_pkt: [*c]c.AVPacket,
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
            video_pkt.*.flags |= c.AV_PKT_FLAG_KEY;
        } else {
            video_pkt.*.flags &= ~c.AV_PKT_FLAG_KEY;
        }

        const ret = c.av_interleaved_write_frame(self.format_context, video_pkt);
        c.av_packet_unref(video_pkt);
        try check_err(ret);
    }

    fn write_audio_packet(self: *Self, pkt: [*c]c.AVPacket, packet_node: *AudioEncoder.EncodedAudioPacketNode, start_sample: i64) !void {
        assert(self.audio_stream != null);
        try check_err(c.av_packet_ref(pkt, @constCast(packet_node.data)));
        pkt.*.stream_index = self.audio_stream.?.*.index;
        pkt.*.pts = packet_node.data.*.pts - start_sample;
        pkt.*.dts = packet_node.data.*.dts - start_sample;
        pkt.*.duration = packet_node.data.*.duration;
        pkt.*.flags = packet_node.data.*.flags;

        const ret = c.av_interleaved_write_frame(self.format_context, pkt);
        c.av_packet_unref(pkt);
        try check_err(ret);
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

    pub fn set_audio_sample_window(self: *Self, start: i64, end: i64) void {
        self.audio_start_sample = start;
        self.audio_end_sample = end;
    }

    /// NOTE: Takes ownership of data.
    pub fn write_video_packet(self: *Self, allocator: Allocator, data: []const u8, frame_time_ns: i128, is_idr: bool) !void {
        errdefer allocator.free(data);

        const max_mux_duration: i64 = std.math.maxInt(i32);

        if (self.first_video_time_ns == null) {
            if (!is_idr) {
                allocator.free(data);
                return;
            }
            self.first_video_time_ns = frame_time_ns;
        }

        const ns_time_base = c.AVRational{ .num = 1, .den = 1_000_000_000 };
        const frame_duration_pts = if (self.fps > 0)
            @max(c.av_rescale_q(1, .{ .num = 1, .den = @intCast(self.fps) }, self.video_stream.time_base), 1)
        else
            0;
        const jitter_tolerance_pts = if (self.fps > 0)
            @max(@divTrunc(frame_duration_pts * 3, 4), 1)
        else
            0;

        const pts_ns = frame_time_ns - self.first_video_time_ns.?;
        const raw_current_pts: i64 = c.av_rescale_q(@intCast(pts_ns), ns_time_base, self.video_stream.time_base);
        const current_pts = apply_jitter_correction_to_pts(
            raw_current_pts,
            if (self.pending_video != null) self.previous_pts else null,
            frame_duration_pts,
            jitter_tolerance_pts,
        );

        if (self.pending_video) |*pending| {
            const duration = if (current_pts > self.previous_pts) current_pts - self.previous_pts else 0;
            const safe_duration = if (duration > max_mux_duration) max_mux_duration else duration;
            var video_pkt = c.av_packet_alloc() orelse return error.FFmpegError;
            defer c.av_packet_free(&video_pkt);
            try self.write_video_packet_data(video_pkt, pending.data, pending.is_idr, self.previous_pts, safe_duration);
            self.last_delta = safe_duration;
            pending.deinit();
            self.pending_video = null;
        }

        self.pending_video = try PendingVideoPacket.init(allocator, data, is_idr);
        self.previous_pts = current_pts;
    }

    pub fn write_audio_packets(self: *Self, packets: *std.DoublyLinkedList) !u64 {
        var total_bytes: u64 = 0;

        if (self.audio_stream == null) {
            return 0;
        }

        const start_sample = self.audio_start_sample orelse return 0;

        var pkt = c.av_packet_alloc() orelse return error.FFmpegError;
        defer c.av_packet_free(&pkt);

        var iter = LinkedListIterator(AudioEncoder.EncodedAudioPacketNode).init(packets);
        while (iter.next()) |packet_node| {
            const packet_start = packet_node.data.*.pts;
            const packet_end = packet_start + packet_node.data.*.duration;
            if (packet_end <= start_sample) continue;
            if (self.audio_end_sample) |end_sample| {
                if (packet_start >= end_sample) break;
            }
            try self.write_audio_packet(pkt, packet_node, start_sample);
            total_bytes += @as(u64, @intCast(packet_node.data.*.size));
        }
        return total_bytes;
    }

    pub fn flush_video(self: *Self) !void {
        if (self.pending_video) |*pending| {
            var video_pkt = c.av_packet_alloc() orelse return error.FFmpegError;
            defer c.av_packet_free(&video_pkt);
            try self.write_video_packet_data(video_pkt, pending.data, pending.is_idr, self.previous_pts, self.last_delta);
            pending.deinit();
            self.pending_video = null;
        }
    }

    pub fn finish(self: *Self) !void {
        try self.flush_video();
        try self.write_trailer();
    }

    fn write_trailer(self: *Self) !void {
        if (self.wrote_trailer) return;
        const ret = c.av_write_trailer(self.format_context);
        try check_err(ret);
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

    fn get_output_file_name(
        allocator: Allocator,
        io: std.Io,
        file_name_prefix: []const u8,
        output_directory: []const u8,
    ) ![:0]u8 {
        const base_name = try Util.format_file_name(allocator, io, .{
            .prefix = file_name_prefix,
            .extension = "mp4",
        });
        defer allocator.free(base_name);

        const path = try std.fs.path.join(allocator, &.{ output_directory, base_name });
        defer allocator.free(path);
        return allocator.dupeSentinel(u8, path, 0);
    }
};

test "Muxer - apply_jitter_correction_to_pts snaps small jitter to expected cadence" {
    const expected = 3_000;
    const previous = 2_000;
    const frame_duration = 1_000;
    const jitter_tolerance = 250;

    try std.testing.expectEqual(
        expected,
        Muxer.apply_jitter_correction_to_pts(expected + 100, previous, frame_duration, jitter_tolerance),
    );
}

test "Muxer - apply_jitter_correction_to_pts preserves large capture gaps" {
    const previous = 2_000;
    const frame_duration = 1_000;
    const jitter_tolerance = 250;
    const raw_current = 5_000;

    try std.testing.expectEqual(
        raw_current,
        Muxer.apply_jitter_correction_to_pts(raw_current, previous, frame_duration, jitter_tolerance),
    );
}
