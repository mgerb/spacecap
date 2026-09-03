const std = @import("std");
const c = @import("ffmpeg_c");
const imguiz = @import("imguiz").imguiz;

const log = std.log.scoped(.ffmpeg);

pub fn check_err(ret: c_int) !void {
    if (ret < 0) {
        var errbuf = std.mem.zeroes([64]u8);
        const errbuf_p: [*c]u8 = @ptrCast(&errbuf);
        _ = c.av_strerror(ret, errbuf_p, errbuf.len);
        log.err("FFmpeg error ({any}): {s}", .{ ret, errbuf_p });
        return error.FFmpegError;
    }
}

/// Get the presentation timestamp (nanoseconds) of a frame based on a stream's time base.
pub fn frame_pts_ns(frame: *const c.AVFrame, time_base: c.AVRational) !i64 {
    if (frame.*.best_effort_timestamp == c.AV_NOPTS_VALUE) {
        return error.MissingFrameTimestamp;
    }
    return c.av_rescale_q(frame.*.best_effort_timestamp, time_base, .{
        .num = 1,
        .den = std.time.ns_per_s,
    });
}

pub fn frame_to_sdl_audio_spec(frame: *const c.AVFrame) !imguiz.SDL_AudioSpec {
    if (frame.*.sample_rate <= 0 or frame.*.ch_layout.nb_channels <= 0) {
        return error.InvalidAudioFrame;
    }
    return .{
        .format = try sample_to_sdl_audio_format(frame.*.format),
        .channels = frame.*.ch_layout.nb_channels,
        .freq = frame.*.sample_rate,
    };
}

pub fn sample_to_sdl_audio_format(sample_format: c.enum_AVSampleFormat) !imguiz.SDL_AudioFormat {
    return @intCast(switch (sample_format) {
        c.AV_SAMPLE_FMT_U8, c.AV_SAMPLE_FMT_U8P => imguiz.SDL_AUDIO_U8,
        c.AV_SAMPLE_FMT_S16, c.AV_SAMPLE_FMT_S16P => imguiz.SDL_AUDIO_S16,
        c.AV_SAMPLE_FMT_S32, c.AV_SAMPLE_FMT_S32P => imguiz.SDL_AUDIO_S32,
        c.AV_SAMPLE_FMT_FLT, c.AV_SAMPLE_FMT_FLTP => imguiz.SDL_AUDIO_F32,
        else => return error.UnsupportedAudioSampleFormat,
    });
}
