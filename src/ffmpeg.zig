const std = @import("std");

const log = std.log.scoped(.ffmpeg);

pub const ffmpeg = @cImport({
    @cInclude("libavutil/opt.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
});

pub fn checkErr(ret: c_int) !void {
    if (ret < 0) {
        var errbuf = std.mem.zeroes([64]u8);
        const errbuf_p: [*c]u8 = @ptrCast(&errbuf);
        _ = ffmpeg.av_strerror(ret, errbuf_p, errbuf.len);
        log.err("FFmpeg error ({any}): {s}", .{ ret, errbuf_p });
        return error.FFmpegError;
    }
}
