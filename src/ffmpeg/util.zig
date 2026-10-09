const std = @import("std");
const c = @import("ffmpeg_c");
const imguiz = @import("imguiz").imguiz;

const log = std.log.scoped(.ffmpeg);

pub const ns_time_base = c.AVRational{ .num = 1, .den = std.time.ns_per_s };

pub fn file_size_bytes(context: ?*c.AVFormatContext) ?u64 {
    const format_context = context orelse return null;
    if (format_context.*.pb == null) {
        return null;
    }
    const size = c.avio_size(format_context.*.pb);
    return if (size >= 0) @intCast(size) else null;
}

pub fn video_file_format_name(context: *const c.AVFormatContext, file_path: []const u8) [:0]const u8 {
    const names = std.mem.span(context.iformat.*.name);
    const extension = std.fs.path.extension(file_path);
    const Container = struct { alias: []const u8, label: [:0]const u8 };
    const container_names = comptime std.StaticStringMapWithEql(
        Container,
        std.static_string_map.eqlAsciiIgnoreCase,
    ).initComptime(.{
        .{ ".mp4", Container{ .alias = "mp4", .label = "MP4" } },
        .{ ".mov", Container{ .alias = "mov", .label = "MOV" } },
        .{ ".mkv", Container{ .alias = "matroska", .label = "MKV" } },
        .{ ".webm", Container{ .alias = "webm", .label = "WebM" } },
        .{ ".avi", Container{ .alias = "avi", .label = "AVI" } },
    });
    if (container_names.get(extension)) |container| {
        var aliases = std.mem.tokenizeScalar(u8, names, ',');
        while (aliases.next()) |alias| {
            if (std.mem.eql(u8, alias, container.alias)) {
                return container.label;
            }
        }
    }
    return names;
}

pub fn frame_rate(context: *const c.AVFormatContext, stream_index: ?c_int) ?f64 {
    const index = stream_index orelse return null;
    const stream = context.streams[@intCast(index)];
    for ([_]c.AVRational{ stream.*.avg_frame_rate, stream.*.r_frame_rate }) |rate| {
        if (rate.num > 0 and rate.den > 0) {
            return @as(f64, @floatFromInt(rate.num)) / @as(f64, @floatFromInt(rate.den));
        }
    }
    return null;
}

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
    return c.av_rescale_q(frame.*.best_effort_timestamp, time_base, ns_time_base);
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

test "ffmpeg/util - video_file_format_name matches extensions against detected format aliases" {
    const Case = struct {
        format_name: [:0]const u8,
        file_path: []const u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .format_name = "mov,mp4,m4a,3gp,3g2,mj2", .file_path = "video.mp4", .expected = "MP4" },
        .{ .format_name = "mov,mp4,m4a,3gp,3g2,mj2", .file_path = "video.mov", .expected = "MOV" },
        .{ .format_name = "matroska,webm", .file_path = "video.mkv", .expected = "MKV" },
        .{ .format_name = "matroska,webm", .file_path = "video.webm", .expected = "WebM" },
        .{ .format_name = "avi", .file_path = "video.avi", .expected = "AVI" },
        .{ .format_name = "mov,mp4,m4a,3gp,3g2,mj2", .file_path = "video.Mp4", .expected = "MP4" },
        .{ .format_name = "matroska,webm", .file_path = "video.WEBM", .expected = "WebM" },
        .{ .format_name = "matroska,webm", .file_path = "video.mp4", .expected = "matroska,webm" },
        .{ .format_name = "notmp4", .file_path = "video.mp4", .expected = "notmp4" },
        .{ .format_name = "matroska,webm", .file_path = "video.unknown", .expected = "matroska,webm" },
        .{ .format_name = "matroska,webm", .file_path = "folder.mp4/video", .expected = "matroska,webm" },
        .{ .format_name = "avi", .file_path = "video.", .expected = "avi" },
    };
    for (cases) |case| {
        var input_format = std.mem.zeroes(c.AVInputFormat);
        input_format.name = case.format_name.ptr;
        var context = std.mem.zeroes(c.AVFormatContext);
        context.iformat = &input_format;
        try std.testing.expectEqualStrings(case.expected, video_file_format_name(&context, case.file_path));
    }
}
