const std = @import("std");
const c = @cImport({
    @cInclude("libavutil/adler32.h");
    @cInclude("libavutil/channel_layout.h");
    @cInclude("libavutil/samplefmt.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
});

const replay_buffer_mod = @import("./vulkan/replay_buffer.zig");
const ReplayBuffer = replay_buffer_mod.ReplayBuffer;
const ReplayBufferNode = replay_buffer_mod.ReplayBufferNode;

pub fn writeAudioToFile(allocator: std.mem.Allocator, sample_rate: u32, channels: u32, samples: []const f32) !void {
    if (samples.len == 0) return error.NoAudioSamples;

    var format_context: *c.AVFormatContext = undefined;

    const file_name = try std.fmt.allocPrintSentinel(allocator, "audio_{}.wav", .{std.time.nanoTimestamp()}, 0);
    defer allocator.free(file_name);

    var ret = c.avformat_alloc_output_context2(@ptrCast(&format_context), null, "wav", file_name);
    try checkErr(ret);

    defer c.avformat_free_context(format_context);

    const out_stream = c.avformat_new_stream(format_context, null) orelse return error.FFmpegError;
    const stream_idx = out_stream.*.index;

    const codecpar = out_stream.*.codecpar;
    codecpar.*.codec_id = c.AV_CODEC_ID_PCM_F32LE;
    codecpar.*.codec_type = c.AVMEDIA_TYPE_AUDIO;
    codecpar.*.format = c.AV_SAMPLE_FMT_FLT;
    codecpar.*.sample_rate = @intCast(sample_rate);
    c.av_channel_layout_default(&codecpar.*.ch_layout, @intCast(channels));
    codecpar.*.bits_per_coded_sample = 32;
    codecpar.*.bits_per_raw_sample = 32;
    codecpar.*.block_align = @intCast(channels * @sizeOf(f32));
    codecpar.*.bit_rate = @intCast(sample_rate * channels * 32);

    out_stream.*.time_base = c.AVRational{ .num = 1, .den = @intCast(sample_rate) };

    if (format_context.oformat.*.flags & c.AVFMT_NOFILE == 0) {
        ret = c.avio_open(&format_context.pb, file_name, c.AVIO_FLAG_WRITE);
        try checkErr(ret);
    }
    defer {
        if (format_context.pb != null) {
            _ = c.avio_closep(&format_context.pb);
        }
    }

    ret = c.avformat_write_header(format_context, null);
    try checkErr(ret);

    var pkt = c.av_packet_alloc() orelse return error.FFmpegError;
    defer c.av_packet_free(&pkt);

    const bytes = std.mem.sliceAsBytes(samples);
    ret = c.av_new_packet(pkt, @intCast(bytes.len));
    try checkErr(ret);
    @memcpy(pkt.*.data[0..bytes.len], bytes);

    const frames: usize = if (channels > 0) samples.len / @as(usize, @intCast(channels)) else 0;
    pkt.*.stream_index = stream_idx;
    pkt.*.pts = 0;
    pkt.*.dts = 0;
    pkt.*.duration = @intCast(frames);
    pkt.*.flags = 0;

    ret = c.av_interleaved_write_frame(format_context, pkt);
    c.av_packet_unref(pkt);
    try checkErr(ret);

    ret = c.av_write_trailer(format_context);
    try checkErr(ret);
}

/// Write replay_buffer to a file.
/// NOTE: This consumes the replay_buffer and takes ownership of the memory.
pub fn writeToFile(allocator: std.mem.Allocator, width: u32, height: u32, fps: u32, replay_buffer: *ReplayBuffer) !void {
    defer replay_buffer.deinit();

    var format_context: *c.AVFormatContext = undefined;

    // TODO: date format
    const file_name = try std.fmt.allocPrintSentinel(allocator, "replay_{}.mp4", .{std.time.nanoTimestamp()}, 0);
    defer allocator.free(file_name);

    var ret = c.avformat_alloc_output_context2(@ptrCast(&format_context), null, null, file_name);
    try checkErr(ret);

    defer c.avformat_free_context(format_context);

    const out_fmt = format_context.oformat;
    const out_stream = c.avformat_new_stream(format_context, null);
    const stream_idx = out_stream.*.index;

    const codecpar = out_stream.*.codecpar;
    codecpar.*.codec_id = c.AV_CODEC_ID_H264;
    codecpar.*.codec_type = c.AVMEDIA_TYPE_VIDEO;
    codecpar.*.width = @intCast(width);
    codecpar.*.height = @intCast(height);

    // ffmpeg frees this memory when it's done so we need to copy it.
    const extradata: [*c]u8 = @ptrCast(c.av_malloc(replay_buffer.header_frame.items.len));
    @memcpy(extradata[0..replay_buffer.header_frame.items.len], replay_buffer.header_frame.items);

    codecpar.*.extradata = extradata;
    codecpar.*.extradata_size = @intCast(replay_buffer.header_frame.items.len);

    // Use nanosecond time base so we can map capture timestamps directly.
    const ns_time_base = c.AVRational{ .num = 1, .den = 1_000_000_000 };
    out_stream.*.time_base = ns_time_base;
    out_stream.*.avg_frame_rate = c.AVRational{ .num = @intCast(fps), .den = 1 };
    out_stream.*.r_frame_rate = c.AVRational{ .num = @intCast(fps), .den = 1 };

    if (out_fmt.*.flags & c.AVFMT_NOFILE == 0) {
        ret = c.avio_open(&format_context.pb, file_name, c.AVIO_FLAG_WRITE);
        try checkErr(ret);
    }
    defer {
        if (format_context.pb != null) {
            _ = c.avio_closep(&format_context.pb);
        }
    }

    c.av_dump_format(format_context, 0, "dumped_format.txt", 1);

    ret = c.avformat_write_header(format_context, null);
    try checkErr(ret);

    var pkt = c.av_packet_alloc();
    defer c.av_packet_free(&pkt);

    var first_frame_time_ns: ?i128 = null;
    var pending_node: ?*ReplayBufferNode = null;
    var pending_pts: i64 = 0;
    var last_delta: i64 = 0;

    while (try replay_buffer.popFirstOwned()) |data| {
        const frame = data.data;

        if (first_frame_time_ns == null) {
            // Make sure that the first frame is always an IDR frame.
            if (!frame.is_idr) {
                data.deinit();
                continue;
            }
            first_frame_time_ns = frame.frame_time;
        }

        const pts_ns = frame.frame_time - first_frame_time_ns.?;
        const current_pts: i64 = c.av_rescale_q(@intCast(pts_ns), ns_time_base, out_stream.*.time_base);

        if (pending_node) |pending| {
            // We now have the next PTS, so we can set duration on the pending packet.
            const duration = if (current_pts > pending_pts) current_pts - pending_pts else 0;

            pkt.*.data = pending.data.data.items.ptr;
            pkt.*.size = @intCast(pending.data.data.items.len);
            pkt.*.stream_index = stream_idx;
            pkt.*.pts = pending_pts;
            pkt.*.dts = pkt.*.pts;
            pkt.*.duration = duration;
            if (pending.data.is_idr) {
                pkt.*.flags |= c.AV_PKT_FLAG_KEY;
            } else {
                pkt.*.flags &= ~@as(c_int, c.AV_PKT_FLAG_KEY);
            }

            ret = c.av_interleaved_write_frame(format_context, pkt);
            c.av_packet_unref(pkt);
            try checkErr(ret);

            last_delta = duration;
            pending.deinit();
        }

        pending_node = data;
        pending_pts = current_pts;
    }

    if (pending_node) |pending| {
        // Write the final packet with the last known delta (or zero if only one frame).
        pkt.*.data = pending.data.data.items.ptr;
        pkt.*.size = @intCast(pending.data.data.items.len);
        pkt.*.stream_index = stream_idx;
        pkt.*.pts = pending_pts;
        pkt.*.dts = pkt.*.pts;
        pkt.*.duration = if (last_delta > 0) last_delta else 0;
        if (pending.data.is_idr) {
            pkt.*.flags |= c.AV_PKT_FLAG_KEY;
        } else {
            pkt.*.flags &= ~@as(c_int, c.AV_PKT_FLAG_KEY);
        }

        ret = c.av_interleaved_write_frame(format_context, pkt);
        c.av_packet_unref(pkt);
        try checkErr(ret);

        pending.deinit();
    }

    ret = c.av_write_trailer(format_context);
    try checkErr(ret);
}

fn checkErr(ret: c_int) !void {
    if (ret < 0) {
        var errbuf = std.mem.zeroes([64]u8);
        const errbuf_p: [*c]u8 = @ptrCast(&errbuf);
        _ = c.av_strerror(ret, errbuf_p, errbuf.len);
        std.log.err("FFmpeg error ({any}): {s}", .{ ret, errbuf_p });
        return error.FFmpegError;
    }
}
