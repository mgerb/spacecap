//// Contains functions to export audio/video.
//// e.g. Export from replay buffers.

const std = @import("std");
const assert = std.debug.assert;
const VideoReplayBuffer = @import("./vulkan/video_replay_buffer.zig").VideoReplayBuffer;
const VideoReplayBufferNode = @import("./vulkan/video_replay_buffer.zig").VideoReplayBufferNode;
const AudioReplayBuffer = @import("./capture/audio/audio_replay_buffer.zig");
const AudioEncoder = @import("./audio_encoder.zig").AudioEncoder;
const audio_mixer = @import("./audio_mixer.zig");
const mixAudio = audio_mixer.mixAudio;
const ffmpeg = @import("./ffmpeg.zig").ffmpeg;
const checkErr = @import("./ffmpeg.zig").checkErr;
const Muxer = @import("./muxer.zig").Muxer;

const log = std.log.scoped(.exporter);
pub const AudioSourceGain = audio_mixer.AudioSourceGain;

/// Export audio/video to a file.
/// NOTE: This takes ownership of audio_replay_buffer/video_replay_buffer.
pub fn exportReplayBuffers(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    fps: u32,
    video_replay_buffer: *VideoReplayBuffer,
    audio_replay_buffer: *AudioReplayBuffer,
    audio_sample_rate: u32,
    audio_channels: u32,
    source_gains: []const AudioSourceGain,
) !void {
    assert(audio_sample_rate > 0);
    assert(audio_channels > 0);
    defer audio_replay_buffer.deinit();
    defer video_replay_buffer.deinit();

    if (video_replay_buffer.len <= 0) {
        log.warn("[exportReplayBuffers] video replay buffer is empty", .{});
        return;
    }

    // The final output is based on the captured video. We first need to
    // prepare the video before we do any audio processing.
    video_replay_buffer.ensureFirstFrameIsIdr();
    const replay_window = video_replay_buffer.getReplayWindow() orelse {
        log.warn("[exportReplayBuffers] replay window is not valid", .{});
        return;
    };

    var mixed_audio_samples = try mixAudio(
        allocator,
        audio_replay_buffer,
        replay_window,
        audio_sample_rate,
        audio_channels,
        source_gains,
    ) orelse {
        log.warn("[exportReplayBuffers] unable to mix audio", .{});
        return;
    };
    defer mixed_audio_samples.deinit(allocator);

    // NOTE: This is for testing purposes. Write only audio file. Eventually this can be used
    // for audio only recording.
    // try writeAudioToFile(allocator, sample_rate, channels, audio_samples.items);

    var muxer = try Muxer.init(
        allocator,
        video_replay_buffer,
        width,
        height,
        fps,
        mixed_audio_samples.items,
        audio_sample_rate,
        audio_channels,
        "replay",
    );
    defer muxer.deinit();
    try muxer.muxAudioVideo();
}

/// Export only audio to file.
pub fn exportAudio(allocator: std.mem.Allocator, sample_rate: u32, channels: u32, samples: []const f32) !void {
    if (samples.len == 0) return error.NoAudioSamples;

    var format_context: *ffmpeg.AVFormatContext = undefined;

    const file_name = try std.fmt.allocPrintSentinel(allocator, "audio_{}.wav", .{std.time.nanoTimestamp()}, 0);
    defer allocator.free(file_name);

    var ret = ffmpeg.avformat_alloc_output_context2(@ptrCast(&format_context), null, "wav", file_name);
    try checkErr(ret);

    defer ffmpeg.avformat_free_context(format_context);

    const out_stream = ffmpeg.avformat_new_stream(format_context, null) orelse return error.FFmpegError;
    const stream_idx = out_stream.*.index;

    const codecpar = out_stream.*.codecpar;
    codecpar.*.codec_id = ffmpeg.AV_CODEC_ID_PCM_F32LE;
    codecpar.*.codec_type = ffmpeg.AVMEDIA_TYPE_AUDIO;
    codecpar.*.format = ffmpeg.AV_SAMPLE_FMT_FLT;
    codecpar.*.sample_rate = @intCast(sample_rate);
    ffmpeg.av_channel_layout_default(&codecpar.*.ch_layout, @intCast(channels));
    codecpar.*.bits_per_coded_sample = 32;
    codecpar.*.bits_per_raw_sample = 32;
    codecpar.*.block_align = @intCast(channels * @sizeOf(f32));
    codecpar.*.bit_rate = @intCast(sample_rate * channels * 32);

    out_stream.*.time_base = ffmpeg.AVRational{ .num = 1, .den = @intCast(sample_rate) };

    if (format_context.oformat.*.flags & ffmpeg.AVFMT_NOFILE == 0) {
        ret = ffmpeg.avio_open(&format_context.pb, file_name, ffmpeg.AVIO_FLAG_WRITE);
        try checkErr(ret);
    }
    defer {
        if (format_context.pb != null) {
            _ = ffmpeg.avio_closep(&format_context.pb);
        }
    }

    ret = ffmpeg.avformat_write_header(format_context, null);
    try checkErr(ret);

    var pkt = ffmpeg.av_packet_alloc() orelse return error.FFmpegError;
    defer ffmpeg.av_packet_free(&pkt);

    const bytes = std.mem.sliceAsBytes(samples);
    ret = ffmpeg.av_new_packet(pkt, @intCast(bytes.len));
    try checkErr(ret);
    @memcpy(pkt.*.data[0..bytes.len], bytes);

    const frames: usize = if (channels > 0) samples.len / @as(usize, @intCast(channels)) else 0;
    pkt.*.stream_index = stream_idx;
    pkt.*.pts = 0;
    pkt.*.dts = 0;
    pkt.*.duration = @intCast(frames);
    pkt.*.flags = 0;

    ret = ffmpeg.av_interleaved_write_frame(format_context, pkt);
    ffmpeg.av_packet_unref(pkt);
    try checkErr(ret);

    ret = ffmpeg.av_write_trailer(format_context);
    try checkErr(ret);
}
