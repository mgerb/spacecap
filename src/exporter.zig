//! Contains functions to export audio, video, images, etc.

const std = @import("std");
const VideoReplayBuffer = @import("./video/video_replay_buffer.zig").VideoReplayBuffer;
const AudioReplayBuffer = @import("./audio/audio_replay_buffer.zig");
const SampleWindow = @import("./audio/audio_timeline.zig").SampleWindow;
const Util = @import("util.zig");
const ffmpeg = @import("./ffmpeg/main.zig");
const Png = ffmpeg.Png;
const Muxer = ffmpeg.Muxer;
const FileRemuxer = ffmpeg.FileRemuxer;
const CodecContextInfo = ffmpeg.AudioEncoder.CodecContextInfo;

const log = std.log.scoped(.exporter);

/// Remux a keyframe-aligned editor selection into the video output directory.
/// Caller owns the returned path.
pub fn export_trimmed_video(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_path: []const u8,
    trim_start_ns: i64,
    trim_end_ns: i64,
    output_directory: []const u8,
) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(io, output_directory);

    const input_name = std.fs.path.basename(input_path);
    const extension = std.fs.path.extension(input_name);
    if (extension.len < 1) {
        return error.MissingVideoFileExtension;
    }
    const input_stem = input_name[0 .. input_name.len - extension.len];
    const output_name = try std.fmt.allocPrint(allocator, "{s}_trimmed{s}", .{ input_stem, extension });
    defer allocator.free(output_name);

    const unique_name = try Util.get_unique_file_name(allocator, io, output_directory, output_name);
    defer allocator.free(unique_name);
    const output_path = try std.fs.path.join(allocator, &.{ output_directory, unique_name });
    errdefer allocator.free(output_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, output_path) catch {};

    var file_remuxer = try FileRemuxer.init(allocator, input_path, output_path);
    defer file_remuxer.deinit();
    try file_remuxer.remux(trim_start_ns, trim_end_ns);

    return output_path;
}

/// Export audio/video to a file.
pub fn export_replay_buffers(
    allocator: std.mem.Allocator,
    io: std.Io,
    width: u32,
    height: u32,
    fps: u32,
    video_replay_buffer: *VideoReplayBuffer,
    audio_replay_buffer: ?*AudioReplayBuffer,
    output_directory: []const u8,
) !void {
    if (video_replay_buffer.len <= 0) {
        log.warn("[export_replay_buffers] video replay buffer is empty", .{});
        return;
    }

    // The final output is based on the captured video. We still need to align
    // audio against the replay window after the first valid IDR frame is known.
    video_replay_buffer.ensure_first_frame_is_idr();
    const replay_window = video_replay_buffer.get_replay_window() orelse {
        log.warn("[export_replay_buffers] replay window is not valid", .{});
        return;
    };

    var audio_codec_context: ?CodecContextInfo = null;
    var audio_sample_window: ?SampleWindow = null;
    if (audio_replay_buffer) |_audio_replay_buffer| {
        audio_sample_window = _audio_replay_buffer.timeline.get_unclamped_sample_window(replay_window.start_ns, replay_window.end_ns);
        if (_audio_replay_buffer.has_packets() and audio_sample_window != null) {
            audio_codec_context = _audio_replay_buffer.timeline.get_codec_context();
        }
    }

    var muxer = try Muxer.init(
        allocator,
        io,
        "replay",
        video_replay_buffer.header_frame.items,
        audio_codec_context,
        width,
        height,
        fps,
        output_directory,
    );
    defer muxer.deinit();

    while (try video_replay_buffer.pop_first_owned()) |node| {
        const video_frame = node.data;
        errdefer node.deinit();
        // TODO: Refactor video_frame.data into []const u8 and then
        // this code here so that we don't have to do this extra copy.
        try muxer.write_video_packet(allocator, try allocator.dupe(u8, video_frame.data.items), video_frame.timestamp_ns, video_frame.is_idr);
        node.deinit();
    }
    try muxer.flush_video();

    if (audio_replay_buffer) |_audio_replay_buffer| {
        if (audio_sample_window) |sample_window| {
            muxer.set_audio_sample_window(sample_window.start_sample, sample_window.end_sample);
            _ = try muxer.write_audio_packets(&_audio_replay_buffer.packets);
        }
    }

    try muxer.finish();
}

/// Encode raw BGRA image data and save to a file. Currently only supports PNG.
pub fn export_image_to_file(
    allocator: std.mem.Allocator,
    io: std.Io,
    width: u32,
    height: u32,
    bgra: []const u8,
    output_directory: []const u8,
) ![]u8 {
    const expected_len: usize = width * height * 4;
    if (bgra.len != expected_len) return error.InvalidScreenshotPixelData;

    const rgba = try allocator.alloc(u8, bgra.len);
    defer allocator.free(rgba);

    // Convert to RGBA
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        rgba[i] = bgra[i + 2];
        rgba[i + 1] = bgra[i + 1];
        rgba[i + 2] = bgra[i];
        rgba[i + 3] = 255;
    }

    const encoded_data = try Png.encode(allocator, width, height, rgba);
    defer allocator.free(encoded_data);

    try std.Io.Dir.cwd().createDirPath(io, output_directory);

    const file_name = try Util.format_file_name(allocator, io, .{
        .prefix = "screenshot",
        .extension = "png",
    });
    defer allocator.free(file_name);

    const file_path = try std.fs.path.join(allocator, &.{ output_directory, file_name });
    errdefer allocator.free(file_path);

    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .exclusive = true });
    defer file.close(io);

    try file.writeStreamingAll(io, encoded_data);
    log.info("[export_image_to_file] wrote {s}", .{file_path});
    return file_path;
}

test "Exporter - export_image_to_file writes to the output directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var tmp_dir_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &tmp_dir_path_buffer);
    const output_directory = try std.fs.path.join(allocator, &.{ tmp_dir_path_buffer[0..tmp_dir_path_len], "screenshots" });
    defer allocator.free(output_directory);

    const file_path = try export_image_to_file(
        allocator,
        io,
        1,
        1,
        &.{ 0x11, 0x22, 0x33, 0xff },
        output_directory,
    );
    defer allocator.free(file_path);

    try std.testing.expectEqualStrings(output_directory, std.fs.path.dirname(file_path).?);
    const file = try std.Io.Dir.openFileAbsolute(io, file_path, .{});
    defer file.close(io);
    try std.testing.expect((try file.stat(io)).size > 0);
}

test "Exporter - export_trimmed_video preserves the source container" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var tmp_dir_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &tmp_dir_path_buffer);
    const output_directory = tmp_dir_path_buffer[0..tmp_dir_path_len];

    const file_path = try export_trimmed_video(
        allocator,
        io,
        "./test/sample_video_1_h264.mp4",
        1_200_000_000,
        30_000_000_000,
        output_directory,
    );
    defer allocator.free(file_path);

    try std.testing.expectEqualStrings(output_directory, std.fs.path.dirname(file_path).?);
    try std.testing.expectEqualStrings(
        "sample_video_1_h264_trimmed.mp4",
        std.fs.path.basename(file_path),
    );
    const file = try std.Io.Dir.openFileAbsolute(io, file_path, .{});
    defer file.close(io);
    try std.testing.expect((try file.stat(io)).size > 0);

    const duplicate_file_path = try export_trimmed_video(
        allocator,
        io,
        "./test/sample_video_1_h264.mp4",
        1_200_000_000,
        30_000_000_000,
        output_directory,
    );
    defer allocator.free(duplicate_file_path);
    try std.testing.expectEqualStrings(
        "sample_video_1_h264_trimmed_1.mp4",
        std.fs.path.basename(duplicate_file_path),
    );
}

// TODO:
test "Exporter - export_replay_buffers writes to the output directory" {}
