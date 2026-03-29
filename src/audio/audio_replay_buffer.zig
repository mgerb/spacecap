const std = @import("std");
const Allocator = std.mem.Allocator;
const LinkedListIterator = @import("../util.zig").LinkedListIterator;
const AudioCaptureData = @import("../capture/audio/audio_capture_data.zig");
const AudioTimeline = @import("./audio_timeline.zig").AudioTimeline;
const CodecContextInfo = @import("./audio_timeline.zig").CodecContextInfo;
const SampleWindow = @import("./audio_timeline.zig").SampleWindow;
const EncodedAudioPacketNode = @import("./audio_encoder.zig").EncodedAudioPacketNode;
const deinitPacketList = @import("./audio_encoder.zig").deinit_packet_list;
const SAMPLE_RATE = @import("../capture/audio/audio_capture.zig").SAMPLE_RATE;
const CHANNELS = @import("../capture/audio/audio_capture.zig").CHANNELS;

const log = std.log.scoped(.AudioReplayBuffer);
const Self = @This();

allocator: Allocator,
/// Contains nodes of EncodedAudioPacketNode retained for replay/export.
packets: std.DoublyLinkedList,
/// Total encoded packet payload size retained in the replay window.
size: u64 = 0,
/// Number of encoded packets retained in the replay window.
len: u32 = 0,
replay_seconds: u32,
/// Owns timeline shaping, mixing, and handing contiguous PCM to the encoder.
timeline: AudioTimeline,

pub fn init(
    allocator: Allocator,
    replay_seconds: u32,
) !*Self {
    var timeline = try AudioTimeline.init(allocator, SAMPLE_RATE, CHANNELS);
    errdefer timeline.deinit();

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .packets = .{},
        .replay_seconds = replay_seconds,
        .timeline = timeline,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    deinitPacketList(&self.packets);
    self.timeline.deinit();
    self.allocator.destroy(self);
}

pub fn add_data(self: *Self, data: *AudioCaptureData) !void {
    self.timeline.add_data(data) catch |err| switch (err) {
        error.UnsupportedAudioFormat => {
            log.err("[add_data] unsopported format: sample rate: {}, channels: {}", .{ SAMPLE_RATE, CHANNELS });
            return error.UnsupportedAudioFormat;
        },
        else => return err,
    };

    var ready_packets = self.timeline.take_ready_packets();
    defer deinitPacketList(&ready_packets);
    self.append_packets(&ready_packets);
    self.trim_packets();
}

pub fn finalize(self: *Self) !void {
    try self.timeline.finalize();

    var ready_packets = self.timeline.take_ready_packets();
    defer deinitPacketList(&ready_packets);
    self.append_packets(&ready_packets);
    self.trim_packets();
}

pub fn set_replay_seconds(self: *Self, replay_seconds: u32) void {
    self.replay_seconds = replay_seconds;
    self.trim_packets();
}

pub fn packet_iterator(self: *Self) LinkedListIterator(EncodedAudioPacketNode) {
    return LinkedListIterator(EncodedAudioPacketNode).init(&self.packets);
}

pub fn has_packets(self: *Self) bool {
    return self.packets.first != null;
}

fn append_packets(self: *Self, packets: *std.DoublyLinkedList) void {
    while (packets.popFirst()) |current| {
        const packet_node: *EncodedAudioPacketNode = @fieldParentPtr("node", current);
        self.len += 1;
        self.size += @intCast(packet_node.data.*.size);
        self.packets.append(current);
    }
}

/// Remove packets that are older than the configured replay duration.
fn trim_packets(self: *Self) void {
    const retention_samples = self.replay_retention_samples();
    const oldest_sample = self.timeline.encoded_until_sample - retention_samples;

    while (self.packets.first) |first| {
        const packet_node: *EncodedAudioPacketNode = @fieldParentPtr("node", first);
        const packet_end = packet_node.data.*.pts + packet_node.data.*.duration;
        if (packet_end <= oldest_sample) {
            _ = self.packets.popFirst();
            self.len -= 1;
            self.size -= @intCast(packet_node.data.*.size);
            packet_node.deinit();
        } else {
            break;
        }
    }
}

fn replay_retention_samples(self: *Self) i64 {
    return self.replay_seconds * SAMPLE_RATE;
}

test "addData - encodes audio before export and exposes packet timing" {
    const allocator = std.testing.allocator;
    const sample_rate: u32 = 48_000;
    const channels: u32 = 2;
    const samples: usize = 2_048;

    var replay_buffer = try Self.init(allocator, 10);
    defer replay_buffer.deinit();

    const pcm = try allocator.alloc(f32, samples * channels);
    defer allocator.free(pcm);
    @memset(pcm, @as(f32, 0.25));

    const chunk = try AudioCaptureData.init(
        allocator,
        "speaker",
        pcm,
        std.time.ns_per_s,
        sample_rate,
        channels,
    );
    try replay_buffer.add_data(chunk);
    try replay_buffer.finalize();

    try std.testing.expect(replay_buffer.has_packets());
    const packet_window = replay_buffer.timeline.get_sample_window(
        std.time.ns_per_s,
        std.time.ns_per_s + std.time.ns_per_s / 10,
    ) orelse return error.ExpectedSampleWindow;
    try std.testing.expect(packet_window.end_sample > packet_window.start_sample);
}

test "trimPackets - drops encoded packets outside replay window" {
    const allocator = std.testing.allocator;
    const sample_rate: u32 = 48_000;
    const channels: u32 = 2;
    const samples_per_chunk: usize = sample_rate;

    var replay_buffer = try Self.init(allocator, 1);
    defer replay_buffer.deinit();

    const base_ns: i128 = 5 * std.time.ns_per_s;
    var second: usize = 0;
    while (second < 4) : (second += 1) {
        const pcm = try allocator.alloc(f32, samples_per_chunk * channels);
        defer allocator.free(pcm);
        @memset(pcm, @as(f32, 0.1));

        const chunk = try AudioCaptureData.init(
            allocator,
            "speaker",
            pcm,
            base_ns + @as(i128, @intCast(second)) * std.time.ns_per_s,
            sample_rate,
            channels,
        );
        try replay_buffer.add_data(chunk);
    }

    try replay_buffer.finalize();
    try std.testing.expect(replay_buffer.has_packets());

    const expected_min_start = replay_buffer.timeline.encoded_until_sample - replay_buffer.replay_retention_samples();
    var iter = replay_buffer.packet_iterator();
    const first_packet = iter.next() orelse return error.ExpectedEncodedPacket;
    try std.testing.expect(first_packet.data.*.pts + first_packet.data.*.duration > expected_min_start);
}
