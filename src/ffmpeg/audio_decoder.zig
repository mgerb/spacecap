const std = @import("std");
const c = @import("ffmpeg_c");
const check_err = @import("./util.zig").check_err;

pub const AudioDecoder = struct {
    const Self = @This();
    const log = std.log.scoped(.audio_decoder);

    codec_context: [*c]c.AVCodecContext,
    frame: [*c]c.AVFrame,
    flushing: bool = false,

    pub fn init(codec_parameters: *const c.AVCodecParameters) !Self {
        const codec = c.avcodec_find_decoder(codec_parameters.*.codec_id) orelse {
            log.err("[init] failed to find audio decoder for codec id: {}", .{codec_parameters.*.codec_id});
            return error.FFmpegError;
        };

        var codec_context = c.avcodec_alloc_context3(codec) orelse return error.FFmpegError;
        errdefer c.avcodec_free_context(&codec_context);

        try check_err(c.avcodec_parameters_to_context(codec_context, codec_parameters));
        try check_err(c.avcodec_open2(codec_context, codec, null));

        const frame = c.av_frame_alloc() orelse return error.FFmpegError;

        return .{
            .codec_context = codec_context,
            .frame = frame,
        };
    }

    pub fn deinit(self: *Self) void {
        c.av_frame_free(&self.frame);
        c.avcodec_free_context(&self.codec_context);
    }

    /// Returns a decoder owned frame that remains valid
    /// until the next call to decode_frame or deinit.
    /// Returns error.NeedsPacket when more input is needed
    /// and null at the end of the stream.
    pub fn decode_frame(self: *Self) !?*const c.AVFrame {
        c.av_frame_unref(self.frame);
        const receive_ret = c.avcodec_receive_frame(self.codec_context, self.frame);

        if (receive_ret >= 0) {
            return self.frame;
        }

        if (receive_ret == c.AVERROR_EOF or (receive_ret == c.AVERROR(c.EAGAIN) and self.flushing)) {
            return null;
        }

        if (receive_ret == c.AVERROR(c.EAGAIN)) {
            return error.NeedsPacket;
        }

        try check_err(receive_ret);

        @panic("[decode_frame] unexpected FFmpeg success result");
    }

    pub fn send_packet(self: *Self, packet: [*c]const c.AVPacket) !void {
        try check_err(c.avcodec_send_packet(self.codec_context, packet));
        if (packet == null) {
            self.flushing = true;
        }
    }

    pub fn flush(self: *Self) void {
        c.avcodec_flush_buffers(self.codec_context);
        c.av_frame_unref(self.frame);
        self.flushing = false;
    }
};
