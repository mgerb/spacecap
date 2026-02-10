const std = @import("std");
const assert = std.debug.assert;
const ReplayWindow = @import("types.zig").ReplayWindow;
const AudioReplayBuffer = @import("./capture/audio/audio_replay_buffer.zig");
const AudioCaptureData = @import("./capture/audio/audio_capture_data.zig");

const log = std.log.scoped(.audio_mixer);

/// Mix audio from an audio replay buffer.
pub fn mixAudio(
    allocator: std.mem.Allocator,
    audio_replay_buffer: *AudioReplayBuffer,
    window: ReplayWindow,
    sample_rate: u32,
    channels: u32,
) !?std.ArrayList(f32) {
    const duration_ns = window.end_ns - window.start_ns;
    const total_frames = nsToFrames(duration_ns, sample_rate);
    if (total_frames == 0) {
        log.warn("[mixReplayAudioForWindow] total frames was 0", .{});
        return null;
    }
    const total_samples: usize = total_frames * channels;

    var mixed_samples = try std.ArrayList(f32).initCapacity(allocator, total_samples);
    errdefer mixed_samples.deinit(allocator);
    try mixed_samples.resize(allocator, total_samples);
    @memset(mixed_samples.items, @as(f32, 0.0));

    var iter = audio_replay_buffer.buffer_map.iterator();
    while (iter.next()) |entry| {
        const stream = entry.value_ptr;

        // Per-stream timeline state:
        // - expected_next_start_ns smooths tiny capture timestamp jitter.
        // - next_writable_out_frame prevents any output-frame overlap for this stream.
        var expected_next_start_ns: ?i128 = null;
        var next_writable_out_frame: usize = 0;
        const jitter_threshold_ns: i128 = 10 * std.time.ns_per_ms; // 10 ms

        var node = stream.first;
        while (node) |current| : (node = current.next) {
            const chunk: *AudioCaptureData = @alignCast(@fieldParentPtr("node", current));
            const src_channels: usize = @intCast(chunk.channels);
            assert(src_channels > 0);
            const src_total_frames = chunk.pcm_data.len / src_channels;
            assert(src_total_frames > 0);

            const raw_chunk_start_ns = chunk.start_ns();
            const raw_chunk_end_ns = chunk.end_ns();
            const chunk_duration_ns = raw_chunk_end_ns - raw_chunk_start_ns;
            var chunk_start_ns = raw_chunk_start_ns;
            // Snap to the expected time if within +/- of jitter_threshold_ns.
            if (expected_next_start_ns) |expected| {
                const delta_ns = chunk_start_ns - expected;
                if (delta_ns >= -jitter_threshold_ns and delta_ns <= jitter_threshold_ns) {
                    chunk_start_ns = expected;
                }
            }
            const chunk_end_ns = chunk_start_ns + chunk_duration_ns;
            expected_next_start_ns = chunk_end_ns;

            // Intersect this chunk's timeline with the replay window.
            const overlap_start_ns = @max(window.start_ns, chunk_start_ns);
            const overlap_end_ns = @min(window.end_ns, chunk_end_ns);
            if (overlap_start_ns >= overlap_end_ns) continue;

            // Floor start / ceil end preserves full overlap coverage.
            var out_start_frame = nsToSampleIndex(overlap_start_ns, window.start_ns, sample_rate);
            var in_start_frame = nsToSampleIndex(overlap_start_ns, chunk_start_ns, chunk.sample_rate);
            const out_end_frame = nsToSampleIndexCeil(overlap_end_ns, window.start_ns, sample_rate);
            const in_end_frame = nsToSampleIndexCeil(overlap_end_ns, chunk_start_ns, chunk.sample_rate);
            if (out_end_frame <= out_start_frame or in_end_frame <= in_start_frame) continue;

            // Never write the same output frame twice for one stream.
            if (out_start_frame < next_writable_out_frame) {
                const trim = next_writable_out_frame - out_start_frame;
                const out_frames = out_end_frame - out_start_frame;
                const in_frames = in_end_frame - in_start_frame;
                if (trim >= out_frames or trim >= in_frames) {
                    continue;
                }
                out_start_frame += trim;
                in_start_frame += trim;
            }

            // Clamp copy length to input/output bounds.
            var frames_to_mix = out_end_frame - out_start_frame;
            const in_frames_available = in_end_frame - in_start_frame;
            if (frames_to_mix > in_frames_available) {
                frames_to_mix = in_frames_available;
            }

            const out_frames_available = total_frames - out_start_frame;
            if (frames_to_mix > out_frames_available) {
                frames_to_mix = out_frames_available;
            }

            if (in_start_frame >= src_total_frames) {
                continue;
            }

            const src_frames_available = src_total_frames - in_start_frame;
            if (frames_to_mix > src_frames_available) {
                frames_to_mix = src_frames_available;
            }

            if (frames_to_mix == 0) {
                continue;
            }

            next_writable_out_frame = out_start_frame + frames_to_mix;

            for (0..frames_to_mix) |frame_idx| {
                const out_base = (out_start_frame + frame_idx) * channels;
                const in_base = (in_start_frame + frame_idx) * src_channels;
                for (0..channels) |ch| {
                    mixed_samples.items[out_base + ch] += chunk.pcm_data[in_base + ch] * chunk.gain;
                }
            }
        }
    }

    return mixed_samples;
}

fn nsToFrames(ns: i128, sample_rate: u32) usize {
    if (ns <= 0 or sample_rate == 0) return 0;
    return @intCast(@divFloor(ns * @as(i128, @intCast(sample_rate)), @as(i128, std.time.ns_per_s)));
}

fn nsToSampleIndex(
    ns: i128,
    start_ns: i128,
    sample_rate: u32,
) usize {
    const delta_ns = ns - start_ns;
    const num: i128 = delta_ns * sample_rate;
    const idx: i128 = @divFloor(num, std.time.ns_per_s);
    return @intCast(idx);
}

fn nsToSampleIndexCeil(
    ns: i128,
    start_ns: i128,
    sample_rate: u32,
) usize {
    const delta_ns = ns - start_ns;
    if (delta_ns <= 0) return 0;
    const num: i128 = delta_ns * sample_rate;
    const den: i128 = std.time.ns_per_s;
    const idx: i128 = @divFloor(num + den - 1, den);
    return @intCast(idx);
}

test "nsToSampleIndex" {
    const start_ns: i128 = 1_000_000_000;
    const sample_rate: u32 = 48_000;

    // Exact alignment at start.
    try std.testing.expectEqual(
        0,
        nsToSampleIndex(start_ns, start_ns, sample_rate),
    );

    // One full second after start maps to 48k samples.
    try std.testing.expectEqual(
        48_000,
        nsToSampleIndex(start_ns + std.time.ns_per_s, start_ns, sample_rate),
    );

    // One nanosecond before a full second should floor to 47,999.
    try std.testing.expectEqual(
        47_999,
        nsToSampleIndex(start_ns + std.time.ns_per_s - 1, start_ns, sample_rate),
    );

    // Fractional sample boundary: 20,833 ns is still sample 0 at 48kHz.
    try std.testing.expectEqual(
        0,
        nsToSampleIndex(start_ns + 20_833, start_ns, sample_rate),
    );

    // One nanosecond past that boundary becomes sample 1.
    try std.testing.expectEqual(
        1,
        nsToSampleIndex(start_ns + 20_834, start_ns, sample_rate),
    );
}

test "nsToSampleIndexCeil" {
    const start_ns: i128 = 1_000_000_000;
    const sample_rate: u32 = 48_000;

    // Exact alignment at start.
    try std.testing.expectEqual(
        0,
        nsToSampleIndexCeil(start_ns, start_ns, sample_rate),
    );

    // Any timestamp before start clamps to 0.
    try std.testing.expectEqual(
        0,
        nsToSampleIndexCeil(start_ns - 1, start_ns, sample_rate),
    );

    // One full second after start maps to 48k samples.
    try std.testing.expectEqual(
        sample_rate,
        nsToSampleIndexCeil(start_ns + std.time.ns_per_s, start_ns, sample_rate),
    );

    // One nanosecond before a full second should ceil to 48,000.
    try std.testing.expectEqual(
        sample_rate,
        nsToSampleIndexCeil(start_ns + std.time.ns_per_s - 1, start_ns, sample_rate),
    );

    // Fractional sample boundary: 20,833 ns rounds up to sample 1 at 48kHz.
    try std.testing.expectEqual(
        1,
        nsToSampleIndexCeil(start_ns + 20_833, start_ns, sample_rate),
    );

    // One nanosecond past that boundary rounds up to sample 2.
    try std.testing.expectEqual(
        2,
        nsToSampleIndexCeil(start_ns + 20_834, start_ns, sample_rate),
    );
}

test "mixReplayAudioForWindow mixes a single aligned stream" {
    const allocator = std.testing.allocator;
    var audio_replay_buffer = try AudioReplayBuffer.init(allocator, 10);
    defer audio_replay_buffer.deinit();

    const sample_rate: u32 = 1000;
    const channels: u32 = 1;
    const start_ns: i128 = std.time.nanoTimestamp();
    const pcm = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 };

    const audio_capture_data = try AudioCaptureData.init(
        allocator,
        "mic",
        &pcm,
        start_ns,
        sample_rate,
        channels,
    );
    try audio_replay_buffer.addData(audio_capture_data);

    const window: ReplayWindow = .{
        .start_ns = start_ns,
        .end_ns = start_ns + 5 * std.time.ns_per_ms,
    };

    const mixed_opt = try mixAudio(
        allocator,
        audio_replay_buffer,
        window,
        sample_rate,
        channels,
    );
    try std.testing.expect(mixed_opt != null);

    var mixed = mixed_opt.?;
    defer mixed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, pcm.len), mixed.items.len);
    for (pcm, 0..) |expected, idx| {
        try std.testing.expectEqual(expected, mixed.items[idx]);
    }
}

test "mixReplayAudioForWindow mixes a single aligned stereo stream" {
    const allocator = std.testing.allocator;
    var audio_replay_buffer = try AudioReplayBuffer.init(allocator, 10);
    defer audio_replay_buffer.deinit();

    const sample_rate: u32 = 1000;
    const channels: u32 = 2;
    const start_ns: i128 = std.time.nanoTimestamp();
    const pcm = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };

    const audio_capture_data = try AudioCaptureData.init(
        allocator,
        "stereo",
        &pcm,
        start_ns,
        sample_rate,
        channels,
    );
    try audio_replay_buffer.addData(audio_capture_data);

    const window: ReplayWindow = .{
        .start_ns = start_ns,
        .end_ns = start_ns + 3 * std.time.ns_per_ms,
    };

    const mixed_opt = try mixAudio(
        allocator,
        audio_replay_buffer,
        window,
        sample_rate,
        channels,
    );
    try std.testing.expect(mixed_opt != null);

    var mixed = mixed_opt.?;
    defer mixed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, pcm.len), mixed.items.len);
    for (pcm, 0..) |expected, idx| {
        try std.testing.expectEqual(expected, mixed.items[idx]);
    }
}

test "mixReplayAudioForWindow applies capture gain" {
    const allocator = std.testing.allocator;
    var audio_replay_buffer = try AudioReplayBuffer.init(allocator, 10);
    defer audio_replay_buffer.deinit();

    const sample_rate: u32 = 1000;
    const channels: u32 = 1;
    const start_ns: i128 = std.time.nanoTimestamp();
    const pcm = [_]f32{ 1.0, 0.5, 0.25 };

    const audio_capture_data = try AudioCaptureData.init(
        allocator,
        "mic",
        &pcm,
        start_ns,
        sample_rate,
        channels,
    );
    audio_capture_data.gain = 0.5;
    try audio_replay_buffer.addData(audio_capture_data);

    const window: ReplayWindow = .{
        .start_ns = start_ns,
        .end_ns = start_ns + 3 * std.time.ns_per_ms,
    };

    const mixed_opt = try mixAudio(
        allocator,
        audio_replay_buffer,
        window,
        sample_rate,
        channels,
    );
    try std.testing.expect(mixed_opt != null);

    var mixed = mixed_opt.?;
    defer mixed.deinit(allocator);

    const expected = [_]f32{ 0.5, 0.25, 0.125 };
    try std.testing.expectEqual(@as(usize, expected.len), mixed.items.len);
    for (expected, 0..) |sample, idx| {
        try std.testing.expectApproxEqAbs(sample, mixed.items[idx], 0.0001);
    }
}

test "mixReplayAudioForWindow smooths small timestamp jitter between chunks" {
    const allocator = std.testing.allocator;
    var audio_replay_buffer = try AudioReplayBuffer.init(allocator, 10);
    defer audio_replay_buffer.deinit();

    const sample_rate: u32 = 1000; // 1 frame per ms
    const channels: u32 = 1;
    const start_ns: i128 = 1_000_000_000;

    const first = [_]f32{ 1.0, 2.0, 3.0 };
    const second = [_]f32{ 4.0, 5.0, 6.0 };

    const chunk1 = try AudioCaptureData.init(
        allocator,
        "mic",
        &first,
        start_ns,
        sample_rate,
        channels,
    );
    try audio_replay_buffer.addData(chunk1);

    // Expected next chunk start is start_ns + 3ms. We inject +5ms jitter,
    // which is within the 10ms threshold and should be snapped.
    const chunk2 = try AudioCaptureData.init(
        allocator,
        "mic",
        &second,
        start_ns + 8 * std.time.ns_per_ms,
        sample_rate,
        channels,
    );
    try audio_replay_buffer.addData(chunk2);

    const window: ReplayWindow = .{
        .start_ns = start_ns,
        .end_ns = start_ns + 6 * std.time.ns_per_ms,
    };

    const mixed_opt = try mixAudio(
        allocator,
        audio_replay_buffer,
        window,
        sample_rate,
        channels,
    );
    try std.testing.expect(mixed_opt != null);

    var mixed = mixed_opt.?;
    defer mixed.deinit(allocator);

    const expected = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    try std.testing.expectEqual(@as(usize, expected.len), mixed.items.len);
    for (expected, 0..) |sample, idx| {
        try std.testing.expectApproxEqAbs(sample, mixed.items[idx], 0.0001);
    }
}
