const std = @import("std");
const c = @cImport({
    @cInclude("libavutil/adler32.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
});

const ReplayBuffer = @import("./vulkan/replay_buffer.zig").ReplayBuffer;

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

    out_stream.*.time_base = c.AVRational{ .num = 1, .den = 90000 };
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

    var first_frame_time: ?i128 = null;
    while (try replay_buffer.popFirstOwned()) |data| {
        defer data.deinit();
        const frame = data.data;

        if (first_frame_time == null) {
            // Make sure that the first frame is always an IDR frame.
            // This will occur after the first replay is saved, because
            // a new replay buffer is allocated, and then the encoder
            // just continues where it left off.
            if (!data.data.is_idr) {
                continue;
            }
            first_frame_time = frame.frame_time;
        }

        const current_pts: i64 = @intCast(frame.frame_time - first_frame_time.?);

        pkt.*.data = frame.data.items.ptr;
        pkt.*.size = @intCast(frame.data.items.len);
        pkt.*.stream_index = stream_idx;

        const your_pts_time_base = c.AVRational{ .num = 1, .den = 1_000_000_000 };
        pkt.*.pts = c.av_rescale_q(current_pts, your_pts_time_base, out_stream.*.time_base);
        pkt.*.dts = pkt.*.pts;

        if (frame.is_idr) {
            pkt.*.flags |= c.AV_PKT_FLAG_KEY;
        }

        ret = c.av_interleaved_write_frame(format_context, pkt);
        c.av_packet_unref(pkt);
        try checkErr(ret);
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
