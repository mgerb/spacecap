const std = @import("std");
const Allocator = std.mem.Allocator;
const AudioCaptureData = @import("../capture/audio/audio_capture_data.zig");
const PendingChunkNode = @import("./audio_timeline.zig").PendingChunkNode;
const DeviceState = @import("./audio_timeline.zig").DeviceState;
const Arc = @import("../arc.zig").Arc;

pub const AudioMixer = struct {
    /// Mix all device audio within the requested sample positions.
    pub fn mix(
        allocator: Allocator,
        device_map: *std.StringHashMap(DeviceState),
        channels: u32,
        start_sample: i64,
        end_sample: i64,
    ) !std.ArrayList(f32) {
        const total_samples: usize = @intCast(end_sample - start_sample);

        var mixed_pcm = try std.ArrayList(f32).initCapacity(allocator, total_samples * channels);
        errdefer mixed_pcm.deinit(allocator);
        try mixed_pcm.resize(allocator, total_samples * channels);
        @memset(mixed_pcm.items, 0.0);

        var iter = device_map.iterator();
        while (iter.next()) |entry| {
            var node = entry.value_ptr.chunks.first;
            while (node) |current| : (node = current.next) {
                const chunk_node: *PendingChunkNode = @alignCast(@fieldParentPtr("node", current));
                const chunk_start_sample = chunk_node.start_sample;
                const chunk_end_sample = chunk_node.end_sample;

                const overlap_start_sample = @max(start_sample, chunk_start_sample);
                const overlap_end_sample = @min(end_sample, chunk_end_sample);
                if (overlap_start_sample >= overlap_end_sample) {
                    continue;
                }

                const data_ptr = chunk_node.data.as_ptr();
                // No need to iterate if the device gain is 0.
                if (data_ptr.gain == 0.0) {
                    continue;
                }

                var i: usize = 0;
                const vector_len = std.simd.suggestVectorLength(f32) orelse 1;
                const Vector = @Vector(vector_len, f32);
                const gain_vector: Vector = @splat(data_ptr.gain);

                const output_start: usize = @intCast((overlap_start_sample - start_sample) * channels);
                const input_start: usize = @intCast((overlap_start_sample - chunk_start_sample) * channels);
                const samples_to_mix: usize = @intCast((overlap_end_sample - overlap_start_sample) * channels);

                const output = mixed_pcm.items[output_start..][0..samples_to_mix];
                const input = data_ptr.pcm_data[input_start..][0..samples_to_mix];

                // Mix with SIMD.
                while (i + vector_len <= output.len) : (i += vector_len) {
                    const output_vec: Vector = output[i..][0..vector_len].*;
                    const input_vec: Vector = input[i..][0..vector_len].*;
                    output[i..][0..vector_len].* = output_vec + (gain_vector * input_vec);
                }

                // Mix the remaining scalers.
                while (i < output.len) : (i += 1) {
                    output[i] += input[i] * data_ptr.gain;
                }
            }
        }

        return mixed_pcm;
    }
};

const TestUtil = struct {
    const SAMPLE_RATE = 48_000;
    const vector_len = std.simd.suggestVectorLength(f32) orelse 1;

    fn add_test_chunk(
        allocator: Allocator,
        device_map: *std.StringHashMap(DeviceState),
        id: []const u8,
        pcm: []const f32,
        start_sample: i64,
        channels: u32,
        gain: f32,
    ) !void {
        const entry = try device_map.getOrPut(id);
        if (!entry.found_existing) {
            entry.key_ptr.* = try allocator.dupe(u8, id);
            entry.value_ptr.* = .{};
        }

        var audio_capture_data = try AudioCaptureData.init(
            allocator,
            id,
            pcm,
            0,
            SAMPLE_RATE,
            channels,
        );
        errdefer audio_capture_data.deinit();

        const data = try Arc(AudioCaptureData).init(allocator, audio_capture_data);
        data.as_ptr().gain = gain;

        const sample_positions: i64 = @intCast(pcm.len / @as(usize, @intCast(channels)));
        const node = try PendingChunkNode.init(allocator, data, start_sample, start_sample + sample_positions);
        entry.value_ptr.chunks.append(&node.node);
    }

    fn deinit_test_device_map(allocator: Allocator, device_map: *std.StringHashMap(DeviceState)) void {
        var iter = device_map.iterator();
        while (iter.next()) |entry| {
            while (entry.value_ptr.chunks.popFirst()) |node| {
                const chunk_node: *PendingChunkNode = @alignCast(@fieldParentPtr("node", node));
                chunk_node.deinit();
            }
            allocator.free(entry.key_ptr.*);
        }
        device_map.deinit();
    }
};

test "AudioMixer - mix mixes a single aligned mono chunk" {
    const allocator = std.testing.allocator;
    var device_map = std.StringHashMap(DeviceState).init(allocator);
    defer TestUtil.deinit_test_device_map(allocator, &device_map);

    const sample_count = (TestUtil.vector_len * 100) + 1;
    var pcm: [sample_count]f32 = undefined;
    for (&pcm, 0..) |*sample, i| {
        sample.* = @floatFromInt((i % 100) / 100);
    }
    try TestUtil.add_test_chunk(allocator, &device_map, "mic", &pcm, 0, 1, 1.0);

    var mixed = try AudioMixer.mix(allocator, &device_map, 1, 0, pcm.len);
    defer mixed.deinit(allocator);

    try std.testing.expectEqual(pcm.len, mixed.items.len);
    for (pcm, 0..) |expected, i| {
        try std.testing.expectEqual(expected, mixed.items[i]);
    }
}

test "AudioMixer - mix mixes a single aligned stereo chunk" {
    const allocator = std.testing.allocator;
    var device_map = std.StringHashMap(DeviceState).init(allocator);
    defer TestUtil.deinit_test_device_map(allocator, &device_map);

    const sample_count = (TestUtil.vector_len * 100) + 1;
    var pcm: [sample_count * 2]f32 = undefined;
    for (&pcm, 0..) |*sample, i| {
        sample.* = @floatFromInt((i % 100) / 100);
    }
    try TestUtil.add_test_chunk(allocator, &device_map, "stereo", &pcm, 0, 2, 1.0);

    var mixed = try AudioMixer.mix(allocator, &device_map, 2, 0, sample_count);
    defer mixed.deinit(allocator);

    try std.testing.expectEqual(pcm.len, mixed.items.len);
    for (pcm, 0..) |expected, i| {
        try std.testing.expectEqual(expected, mixed.items[i]);
    }
}

test "AudioMixer - mix applies capture gain" {
    const allocator = std.testing.allocator;
    var device_map = std.StringHashMap(DeviceState).init(allocator);
    defer TestUtil.deinit_test_device_map(allocator, &device_map);

    const sample_count = (TestUtil.vector_len * 100) + 1;
    var pcm: [sample_count]f32 = undefined;
    for (&pcm, 0..) |*sample, i| {
        sample.* = @floatFromInt((i % 100) / 100);
    }
    const gain: f32 = 0.5;
    try TestUtil.add_test_chunk(allocator, &device_map, "mic", &pcm, 0, 1, gain);

    var mixed = try AudioMixer.mix(allocator, &device_map, 1, 0, pcm.len);
    defer mixed.deinit(allocator);

    try std.testing.expectEqual(pcm.len, mixed.items.len);
    for (pcm, 0..) |sample, i| {
        try std.testing.expectApproxEqAbs(sample * gain, mixed.items[i], 0.0001);
    }
}

test "AudioMixer - mix accumulates overlapping chunks with capture gain" {
    const allocator = std.testing.allocator;
    var device_map = std.StringHashMap(DeviceState).init(allocator);
    defer TestUtil.deinit_test_device_map(allocator, &device_map);

    const sample_count = (TestUtil.vector_len * 100) + 1;
    var first_pcm: [sample_count]f32 = undefined;
    var second_pcm: [sample_count]f32 = undefined;
    for (&first_pcm, &second_pcm, 0..) |*first_sample, *second_sample, i| {
        first_sample.* = @floatFromInt((i % 100) / 100);
        second_sample.* = @floatFromInt((i % 25) / 25);
    }

    const first_gain: f32 = 0.5;
    const second_gain: f32 = 0.25;
    try TestUtil.add_test_chunk(allocator, &device_map, "mic", &first_pcm, 0, 1, first_gain);
    try TestUtil.add_test_chunk(allocator, &device_map, "desktop", &second_pcm, 0, 1, second_gain);

    var mixed = try AudioMixer.mix(allocator, &device_map, 1, 0, sample_count);
    defer mixed.deinit(allocator);

    try std.testing.expectEqual(sample_count, mixed.items.len);
    for (first_pcm, second_pcm, 0..) |first_sample, second_sample, i| {
        const expected = first_sample * first_gain + second_sample * second_gain;
        try std.testing.expectApproxEqAbs(expected, mixed.items[i], 0.0001);
    }
}
