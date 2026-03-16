const std = @import("std");
const Allocator = std.mem.Allocator;
const AudioCaptureData = @import("./audio_capture_data.zig");
const PendingChunkNode = @import("./audio_timeline.zig").PendingChunkNode;
const DeviceState = @import("./audio_timeline.zig").DeviceState;

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
                const chunk_node: *PendingChunkNode = @fieldParentPtr("node", current);
                const chunk_start_sample = chunk_node.start_frame;
                const chunk_end_sample = chunk_node.end_frame;

                const overlap_start_sample = @max(start_sample, chunk_start_sample);
                const overlap_end_sample = @min(end_sample, chunk_end_sample);
                if (overlap_start_sample >= overlap_end_sample) {
                    continue;
                }

                const sample_positions_to_mix: usize = @intCast(overlap_end_sample - overlap_start_sample);
                const input_start_sample: usize = @intCast(overlap_start_sample - chunk_start_sample);
                const output_start_sample: usize = @intCast(overlap_start_sample - start_sample);
                const src_channels: usize = @intCast(chunk_node.data.channels);

                for (0..sample_positions_to_mix) |sample_idx| {
                    const output_pcm_offset = (output_start_sample + sample_idx) * channels;
                    const input_pcm_offset = (input_start_sample + sample_idx) * src_channels;
                    for (0..channels) |channel_idx| {
                        mixed_pcm.items[output_pcm_offset + channel_idx] +=
                            chunk_node.data.pcm_data[input_pcm_offset + channel_idx] * chunk_node.data.gain;
                    }
                }
            }
        }

        return mixed_pcm;
    }
};

fn addTestChunk(
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

    const data = try AudioCaptureData.init(
        allocator,
        id,
        pcm,
        0,
        48_000,
        channels,
    );
    data.gain = gain;

    const sample_positions: i64 = @intCast(pcm.len / @as(usize, @intCast(channels)));
    const node = try PendingChunkNode.init(allocator, data, start_sample, start_sample + sample_positions);
    entry.value_ptr.chunks.append(&node.node);
}

fn deinitTestDeviceMap(allocator: Allocator, device_map: *std.StringHashMap(DeviceState)) void {
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

test "AudioMixer.mix mixes a single aligned mono chunk" {
    const allocator = std.testing.allocator;
    var device_map = std.StringHashMap(DeviceState).init(allocator);
    defer deinitTestDeviceMap(allocator, &device_map);

    const pcm = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 };
    try addTestChunk(allocator, &device_map, "mic", &pcm, 0, 1, 1.0);

    var mixed = try AudioMixer.mix(allocator, &device_map, 1, 0, 5);
    defer mixed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, pcm.len), mixed.items.len);
    for (pcm, 0..) |expected, idx| {
        try std.testing.expectEqual(expected, mixed.items[idx]);
    }
}

test "AudioMixer.mix mixes a single aligned stereo chunk" {
    const allocator = std.testing.allocator;
    var device_map = std.StringHashMap(DeviceState).init(allocator);
    defer deinitTestDeviceMap(allocator, &device_map);

    const pcm = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    try addTestChunk(allocator, &device_map, "stereo", &pcm, 0, 2, 1.0);

    var mixed = try AudioMixer.mix(allocator, &device_map, 2, 0, 3);
    defer mixed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, pcm.len), mixed.items.len);
    for (pcm, 0..) |expected, idx| {
        try std.testing.expectEqual(expected, mixed.items[idx]);
    }
}

test "AudioMixer.mix applies capture gain" {
    const allocator = std.testing.allocator;
    var device_map = std.StringHashMap(DeviceState).init(allocator);
    defer deinitTestDeviceMap(allocator, &device_map);

    const pcm = [_]f32{ 1.0, 0.5, 0.25 };
    try addTestChunk(allocator, &device_map, "mic", &pcm, 0, 1, 0.5);

    var mixed = try AudioMixer.mix(allocator, &device_map, 1, 0, 3);
    defer mixed.deinit(allocator);

    const expected = [_]f32{ 0.5, 0.25, 0.125 };
    try std.testing.expectEqual(@as(usize, expected.len), mixed.items.len);
    for (expected, 0..) |sample, idx| {
        try std.testing.expectApproxEqAbs(sample, mixed.items[idx], 0.0001);
    }
}
