const std = @import("std");

allocator: std.mem.Allocator,
/// A unique name to identify the source of the audio data.
/// e.g. speaker/mic id
id: []const u8,
pcm_data: []const f32,
timestamp: i128,
sample_rate: u32,
channels: u32,
/// A number between 0 and 2. The gain is adjusted in the user settings
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
) !*@This() {
    const self = try allocator.create(@This());
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, id),
        .pcm_data = try allocator.dupe(f32, pcm_data),
        .timestamp = timestamp,
        .sample_rate = sample_rate,
        .channels = channels,
    };

    return self;
}

pub fn deinit(self: *@This()) void {
    self.allocator.free(self.id);
    self.allocator.free(self.pcm_data);
    self.allocator.destroy(self);
}

pub fn start_ns(self: *@This()) i128 {
    return self.timestamp;
}

pub fn end_ns(self: *@This()) i128 {
    const ns_per_sample = @divFloor(std.time.ns_per_s, self.sample_rate);
    const frames: usize = self.pcm_data.len / @as(usize, @intCast(self.channels));
    return self.timestamp + (@as(i128, @intCast(frames)) * ns_per_sample);
}

test "AudioCaptureData.end_ns stereo" {
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

test "AudioCaptureData.end_ns mono" {
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
