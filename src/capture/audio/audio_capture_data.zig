const std = @import("std");

allocator: std.mem.Allocator,
/// A unique name to identify the source of the audio data.
/// e.g. speaker/mic id
id: []const u8,
pcm_data: []const f32,
/// Largest finite absolute sample value in `pcm_data`, before gain is applied.
peak_level: f32,
timestamp: i128,
sample_rate: u32,
channels: u32,
/// Linear gain multiplier.
gain: f32 = 1.0,
/// Required so this can be used in a linked list.
node: std.DoublyLinkedList.Node = .{},

/// pcm_data is copied into AudioCaptureData.
pub fn init(
    allocator: std.mem.Allocator,
    id: []const u8,
    pcm_data: []const f32,
    timestamp: i128,
    sample_rate: u32,
    channels: u32,
) !@This() {
    const id_copy = try allocator.dupe(u8, id);
    errdefer allocator.free(id_copy);

    const pcm_copy = try allocator.alloc(f32, pcm_data.len);
    errdefer allocator.free(pcm_copy);

    var peak_level: f32 = 0.0;
    for (pcm_data, pcm_copy) |sample, *dest| {
        dest.* = sample;
        if (!std.math.isFinite(sample)) {
            continue;
        }
        peak_level = @max(peak_level, @abs(sample));
    }

    return .{
        .allocator = allocator,
        .id = id_copy,
        .pcm_data = pcm_copy,
        .peak_level = peak_level,
        .timestamp = timestamp,
        .sample_rate = sample_rate,
        .channels = channels,
    };
}

pub fn deinit(self: *const @This()) void {
    self.allocator.free(self.id);
    self.allocator.free(self.pcm_data);
}

pub fn clone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
    const id_copy = try allocator.dupe(u8, self.id);
    errdefer allocator.free(id_copy);

    const pcm_copy = try allocator.dupe(f32, self.pcm_data);
    errdefer allocator.free(pcm_copy);

    var cloned_self = @This(){
        .allocator = allocator,
        .id = id_copy,
        .pcm_data = pcm_copy,
        .peak_level = self.peak_level,
        .timestamp = self.timestamp,
        .sample_rate = self.sample_rate,
        .channels = self.channels,
    };
    cloned_self.gain = self.gain;
    return cloned_self;
}

pub fn start_ns(self: *const @This()) i128 {
    return self.timestamp;
}

pub fn end_ns(self: *const @This()) i128 {
    const ns_per_sample = @divFloor(std.time.ns_per_s, self.sample_rate);
    const frames: usize = self.pcm_data.len / @as(usize, @intCast(self.channels));
    return self.timestamp + (@as(i128, @intCast(frames)) * ns_per_sample);
}

test "AudioCaptureData - end_ns stereo" {
    const allocator = std.testing.allocator;
    const sample_rate: u32 = 1000;
    const channels: u32 = 2;
    const start_timestamp_ns: i128 = 1234;
    const pcm = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 };

    const data = try @This().init(allocator, "stereo", &pcm, start_timestamp_ns, sample_rate, channels);
    defer data.deinit();

    const ns_per_sample = @divFloor(std.time.ns_per_s, sample_rate);
    const expected_frames: usize = pcm.len / @as(usize, @intCast(channels));
    const expected_end = start_timestamp_ns + (@as(i128, @intCast(expected_frames)) * ns_per_sample);
    try std.testing.expectEqual(expected_end, data.end_ns());
}

test "AudioCaptureData - end_ns mono" {
    const allocator = std.testing.allocator;
    const sample_rate: u32 = 1000;
    const channels: u32 = 1;
    const start_timestamp_ns: i128 = 1234;
    const pcm = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 };

    const data = try @This().init(allocator, "mono", &pcm, start_timestamp_ns, sample_rate, channels);
    defer data.deinit();

    const ns_per_sample = @divFloor(std.time.ns_per_s, sample_rate);
    const expected_frames: usize = pcm.len / @as(usize, @intCast(channels));
    const expected_end = start_timestamp_ns + (@as(i128, @intCast(expected_frames)) * ns_per_sample);
    try std.testing.expectEqual(expected_end, data.end_ns());
}

test "AudioCaptureData - init stores peak level" {
    const allocator = std.testing.allocator;
    const pcm = [_]f32{ 0.1, -0.75, std.math.inf(f32), 0.5 };

    const data = try @This().init(allocator, "mic", &pcm, 0, 48_000, 1);
    defer data.deinit();

    try std.testing.expectEqual(@as(f32, 0.75), data.peak_level);
}

test "AudioCaptureData - clone preserves peak level" {
    const allocator = std.testing.allocator;
    const pcm = [_]f32{ 0.25, -0.5 };

    const data = try @This().init(allocator, "mic", &pcm, 0, 48_000, 1);
    defer data.deinit();

    const cloned = try data.clone(allocator);
    defer cloned.deinit();

    try std.testing.expectEqual(data.peak_level, cloned.peak_level);
}
