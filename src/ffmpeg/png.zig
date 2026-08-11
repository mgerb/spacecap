const std = @import("std");
const c = @import("ffmpeg_c");
const check_err = @import("./util.zig").check_err;

pub const Png = struct {
    pub fn encode(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        rgba: []const u8,
    ) ![]u8 {
        const codec = c.avcodec_find_encoder(c.AV_CODEC_ID_PNG) orelse return error.MissingPngEncoder;
        var codec_ctx = c.avcodec_alloc_context3(codec) orelse return error.FFmpegError;
        defer c.avcodec_free_context(&codec_ctx);

        codec_ctx.*.width = @intCast(width);
        codec_ctx.*.height = @intCast(height);
        codec_ctx.*.pix_fmt = c.AV_PIX_FMT_RGBA; // Only rgba is supported by png.
        codec_ctx.*.time_base = c.AVRational{ .num = 1, .den = 1 };

        try check_err(c.avcodec_open2(codec_ctx, codec, null));

        var frame = c.av_frame_alloc() orelse return error.FFmpegError;
        defer c.av_frame_free(&frame);

        frame.*.format = codec_ctx.*.pix_fmt;
        frame.*.width = codec_ctx.*.width;
        frame.*.height = codec_ctx.*.height;
        try check_err(c.av_frame_get_buffer(frame, 1));
        try check_err(c.av_frame_make_writable(frame));

        const row_bytes: usize = @intCast(width * 4);
        const linesize: usize = @intCast(frame[0].linesize[0]);
        for (0..height) |row| {
            const src_start = row * row_bytes;
            const dst_start = row * linesize;
            @memcpy(frame[0].data[0][dst_start .. dst_start + row_bytes], rgba[src_start .. src_start + row_bytes]);
        }

        var pkt = c.av_packet_alloc() orelse return error.FFmpegError;
        defer c.av_packet_free(&pkt);

        try check_err(c.avcodec_send_frame(codec_ctx, frame));

        const ret = c.avcodec_receive_packet(codec_ctx, pkt);
        if (ret == c.AVERROR(c.EAGAIN) or ret == c.AVERROR_EOF) {
            return error.ScreenshotEncoderDidNotProducePacket;
        }
        try check_err(ret);

        return try allocator.dupe(u8, pkt.*.data[0..@intCast(pkt.*.size)]);
    }
};
