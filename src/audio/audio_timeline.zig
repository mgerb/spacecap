const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const AudioCaptureData = @import("../capture/audio/audio_capture_data.zig");
const AudioMixer = @import("./audio_mixer.zig").AudioMixer;
const AudioEncoder = @import("./audio_encoder.zig").AudioEncoder;
const EncodedAudioPacketNode = @import("./audio_encoder.zig").EncodedAudioPacketNode;
const deinitPacketList = @import("./audio_encoder.zig").deinit_packet_list;
const ffmpeg = @import("../ffmpeg.zig").ffmpeg;

/// Pending per-device PCM chunk that has not yet been fully mixed into the
/// finalized audio timeline.
pub const PendingChunkNode = struct {
    data: *AudioCaptureData,
    start_frame: i64,
    end_frame: i64,
    node: std.DoublyLinkedList.Node = .{},
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        data: *AudioCaptureData,
        start_sample: i64,
        end_sample: i64,
    ) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{
            .data = data,
            .start_frame = start_sample,
            .end_frame = end_sample,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.data.deinit();
        self.allocator.destroy(self);
    }
};

pub const DeviceState = struct {
    /// Linked list of PendingChunkNode.
    chunks: std.DoublyLinkedList = .{},
    // Used to smooth timestamp jitter per capture device.
    expected_next_start_sample: ?i64 = null,
};

/// Sample indexes relative to the timeline orgin.
pub const SampleWindow = struct {
    start_sample: i64,
    end_sample: i64,
};

pub const CodecContextInfo = struct {
    audio_codec_ctx: [*c]ffmpeg.AVCodecContext,
    time_base: ffmpeg.AVRational,
};

/// Mixes and encodes audio data.
pub const AudioTimeline = struct {
    const Self = @This();

    allocator: Allocator,
    /// One pending chunk list per capture device.
    device_map: std.StringHashMap(DeviceState),
    /// Packets that have been mix/encoded.
    ready_packets: std.DoublyLinkedList = .{},
    sample_rate: u32,
    channels: u32,
    /// The timestamp of the first received audio chunk.
    timeline_origin_ns: ?i128 = null,
    // All sample positions before this boundary have already been mixed and
    // handed to the encoder, so they no longer need to remain in `device_map`.
    encoded_until_sample: i64 = 0,
    // Furthest timestamp we have seen from any device after normalization.
    // This is used with a safety delay to decide how much of the timeline is
    // stable enough to encode.
    max_seen_end_sample: i64 = 0,
    encoder: AudioEncoder,

    pub fn init(
        allocator: Allocator,
        sample_rate: u32,
        channels: u32,
    ) !Self {
        var encoder = try AudioEncoder.init(allocator, sample_rate, channels);
        errdefer encoder.deinit(allocator);

        return .{
            .allocator = allocator,
            .device_map = .init(allocator),
            .sample_rate = sample_rate,
            .channels = channels,
            .encoder = encoder,
        };
    }

    pub fn deinit(self: *Self) void {
        // The device map owns the keys and the chunk data, so clean up both here.
        var iter = self.device_map.iterator();
        while (iter.next()) |entry| {
            while (entry.value_ptr.chunks.popFirst()) |node| {
                const chunk_node: *PendingChunkNode = @fieldParentPtr("node", node);
                chunk_node.deinit();
            }
            self.allocator.free(entry.key_ptr.*);
        }
        self.device_map.deinit();

        deinitPacketList(&self.ready_packets);
        self.encoder.deinit(self.allocator);
    }

    pub fn add_data(self: *Self, data: *AudioCaptureData) !void {
        if (data.sample_rate != self.sample_rate or data.channels != self.channels) {
            return error.UnsupportedAudioFormat;
        }

        if (self.timeline_origin_ns == null) {
            // Reserve a little headroom so the first device we hear from does
            // not lock the replay origin too tightly. A later chunk that is
            // only slightly earlier still fits into the same positive sample
            // timeline.
            self.timeline_origin_ns = data.start_ns() - self.processing_delay_ns();
        }

        const device = try self.device_map.getOrPut(data.id);
        if (!device.found_existing) {
            const key_copy = try self.allocator.dupe(u8, data.id);
            errdefer self.allocator.free(key_copy);
            device.key_ptr.* = key_copy;
            device.value_ptr.* = .{};
        }

        var start_sample = self.timestamp_to_sample_floor(data.start_ns());

        // Chunks don't always arrive at exactly the timestamps they are
        // expected to. Small jitter here can cause static once multiple devices
        // are mixed, so snap near-misses to the next expected sample position.
        const jitter_samples = self.jitter_threshold_samples();
        if (device.value_ptr.expected_next_start_sample) |expected| {
            const delta = start_sample - expected;
            if (@abs(delta) <= jitter_samples) {
                start_sample = expected;
            }
        }

        const end_sample = start_sample + @as(i64, @intCast(data.pcm_data.len / data.channels));
        device.value_ptr.expected_next_start_sample = end_sample;

        const node = try PendingChunkNode.init(self.allocator, data, start_sample, end_sample);
        device.value_ptr.chunks.append(&node.node);

        self.max_seen_end_sample = @max(end_sample, self.max_seen_end_sample);

        try self.process_ready_timeline(false);
    }

    pub fn finalize(self: *Self) !void {
        if (self.timeline_origin_ns == null) {
            return;
        }

        try self.process_ready_timeline(true);

        var flush_result = try self.encoder.flush(self.allocator);
        errdefer deinitPacketList(&flush_result);
        self.append_ready_packets(&flush_result);
    }

    /// Transfer ownership of all packets that have become ready.
    pub fn take_ready_packets(self: *Self) std.DoublyLinkedList {
        const packets = self.ready_packets;
        self.ready_packets = .{};
        return packets;
    }

    pub fn get_codec_context(self: *Self) CodecContextInfo {
        return .{
            .audio_codec_ctx = self.encoder.audio_codec_ctx,
            .time_base = self.encoder.audio_codec_ctx.*.time_base,
        };
    }

    pub fn get_sample_window(self: *Self, start_time_ns: i128, end_time_ns: i128) ?SampleWindow {
        if (self.timeline_origin_ns == null) return null;
        return .{
            .start_sample = self.timestamp_to_sample_floor(start_time_ns),
            .end_sample = self.timestamp_to_sample_ceil(end_time_ns),
        };
    }

    /// Export alignment sometimes needs a window that begins before the first
    /// captured audio sample. Keep that offset negative so muxing preserves the
    /// initial gap instead of shifting audio earlier to time zero. This can occur
    /// if audio capture starts late upon app startup.
    pub fn get_unclamped_sample_window(self: *Self, start_time_ns: i128, end_time_ns: i128) ?SampleWindow {
        if (self.timeline_origin_ns == null) return null;
        return .{
            .start_sample = self.timestamp_to_sample_floor_unclamped(start_time_ns),
            .end_sample = self.timestamp_to_sample_ceil_unclamped(end_time_ns),
        };
    }

    fn process_ready_timeline(self: *Self, flush_all: bool) !void {
        assert(self.timeline_origin_ns != null);

        const delay_samples = if (flush_all) 0 else self.processing_delay_samples();
        const ready_end_sample = self.max_seen_end_sample - delay_samples;
        if (ready_end_sample <= self.encoded_until_sample) {
            return;
        }

        const max_window_samples: i64 = @intCast(self.sample_rate);
        while (ready_end_sample > self.encoded_until_sample) {
            // Encode only the stable portion of the timeline so slightly late
            // chunks can still be merged into the correct place before audio is
            // finalized into packets.
            const window_end_sample = @min(ready_end_sample, self.encoded_until_sample + max_window_samples);
            var mixed_pcm = try AudioMixer.mix(
                self.allocator,
                &self.device_map,
                self.channels,
                self.encoded_until_sample,
                window_end_sample,
            );
            defer mixed_pcm.deinit(self.allocator);

            var packets = try self.encoder.encode_chunk(self.allocator, self.encoded_until_sample, mixed_pcm.items);
            if (packets) |*owned_packets| {
                errdefer deinitPacketList(owned_packets);
                self.append_ready_packets(owned_packets);
            }

            self.encoded_until_sample = window_end_sample;
            self.remove_consumed_chunks();
        }
    }

    fn append_ready_packets(self: *Self, packets: *std.DoublyLinkedList) void {
        while (packets.popFirst()) |current| {
            self.ready_packets.append(current);
        }
    }

    /// Once a chunk ends before `encoded_until_sample`, every sample position
    /// it covers has already been mixed into encoded output and can be dropped.
    fn remove_consumed_chunks(self: *Self) void {
        var iter = self.device_map.iterator();
        while (iter.next()) |entry| {
            var node = entry.value_ptr.chunks.first;
            while (node) |current| {
                const next = current.next;
                const chunk_node: *PendingChunkNode = @fieldParentPtr("node", current);
                if (chunk_node.end_frame <= self.encoded_until_sample) {
                    entry.value_ptr.chunks.remove(current);
                    chunk_node.deinit();
                }
                node = next;
            }
        }
    }

    /// Returns the number of samples for 10ms.
    fn jitter_threshold_samples(self: *Self) i64 {
        return @max(1, @divFloor(self.sample_rate * 10, std.time.ms_per_s));
    }

    /// Returns the number of samples for 50ms.
    fn processing_delay_samples(self: *Self) i64 {
        return @max(1, @divFloor(self.sample_rate * 50, std.time.ms_per_s));
    }

    fn processing_delay_ns(self: *Self) i128 {
        return @divFloor(
            self.processing_delay_samples() * std.time.ns_per_s,
            self.sample_rate,
        );
    }

    /// Floor is used for starts so a chunk never begins after its true time.
    fn timestamp_to_sample_floor(self: *Self, timestamp_ns: i128) i64 {
        return @max(self.timestamp_to_sample_floor_unclamped(timestamp_ns), 0);
    }

    fn timestamp_to_sample_floor_unclamped(self: *Self, timestamp_ns: i128) i64 {
        assert(self.timeline_origin_ns != null);
        const delta_ns = timestamp_ns - self.timeline_origin_ns.?;
        return @intCast(@divFloor(delta_ns * self.sample_rate, std.time.ns_per_s));
    }

    /// Ceil is used for ends so the requested window fully covers the desired
    /// duration even when timestamps fall between exact sample boundaries.
    fn timestamp_to_sample_ceil(self: *Self, timestamp_ns: i128) i64 {
        return @max(self.timestamp_to_sample_ceil_unclamped(timestamp_ns), 0);
    }

    fn timestamp_to_sample_ceil_unclamped(self: *Self, timestamp_ns: i128) i64 {
        assert(self.timeline_origin_ns != null);
        const delta_ns = timestamp_ns - self.timeline_origin_ns.?;
        const numerator = delta_ns * self.sample_rate;
        const sample = -@divFloor(-numerator, std.time.ns_per_s);
        return @intCast(sample);
    }
};

test "timestampToSampleFloor" {
    const allocator = std.testing.allocator;
    var timeline = try AudioTimeline.init(allocator, 48_000, 2);
    defer timeline.deinit();

    const start_ns: i128 = 1_000_000_000;
    timeline.timeline_origin_ns = start_ns;

    try std.testing.expectEqual(0, timeline.timestamp_to_sample_floor(start_ns));
    try std.testing.expectEqual(48_000, timeline.timestamp_to_sample_floor(start_ns + std.time.ns_per_s));
    try std.testing.expectEqual(47_999, timeline.timestamp_to_sample_floor(start_ns + std.time.ns_per_s - 1));
    try std.testing.expectEqual(0, timeline.timestamp_to_sample_floor(start_ns + 20_833));
    try std.testing.expectEqual(1, timeline.timestamp_to_sample_floor(start_ns + 20_834));
}

test "timestampToSampleCeil" {
    const allocator = std.testing.allocator;
    var timeline = try AudioTimeline.init(allocator, 48_000, 2);
    defer timeline.deinit();

    const start_ns: i128 = 1_000_000_000;
    timeline.timeline_origin_ns = start_ns;

    try std.testing.expectEqual(0, timeline.timestamp_to_sample_ceil(start_ns));
    try std.testing.expectEqual(0, timeline.timestamp_to_sample_ceil(start_ns - 1));
    try std.testing.expectEqual(48_000, timeline.timestamp_to_sample_ceil(start_ns + std.time.ns_per_s));
    try std.testing.expectEqual(48_000, timeline.timestamp_to_sample_ceil(start_ns + std.time.ns_per_s - 1));
    try std.testing.expectEqual(1, timeline.timestamp_to_sample_ceil(start_ns + 20_833));
    try std.testing.expectEqual(2, timeline.timestamp_to_sample_ceil(start_ns + 20_834));
}

test "getUnclampedSampleWindow preserves leading offset before first audio sample" {
    const allocator = std.testing.allocator;
    var timeline = try AudioTimeline.init(allocator, 48_000, 2);
    defer timeline.deinit();

    const origin_ns: i128 = 2 * std.time.ns_per_s;
    timeline.timeline_origin_ns = origin_ns;

    const window = timeline.get_unclamped_sample_window(
        origin_ns - std.time.ns_per_s,
        origin_ns + std.time.ns_per_s,
    ) orelse return error.ExpectedSampleWindow;

    try std.testing.expectEqual(-48_000, window.start_sample);
    try std.testing.expectEqual(48_000, window.end_sample);
}

test "addData smooths small timestamp jitter between chunks" {
    const allocator = std.testing.allocator;
    var timeline = try AudioTimeline.init(allocator, 48_000, 2);
    defer timeline.deinit();

    const start_ns: i128 = 1_000_000_000;
    const samples: usize = 3;
    const first = [_]f32{ 1.0, 1.0, 2.0, 2.0, 3.0, 3.0 };
    const second = [_]f32{ 4.0, 4.0, 5.0, 5.0, 6.0, 6.0 };

    const chunk1 = try AudioCaptureData.init(allocator, "mic", &first, start_ns, 48_000, 2);
    try timeline.add_data(chunk1);

    const second_delta_ns = @divFloor(
        @as(i128, 8) * std.time.ns_per_s + @as(i128, 48_000) - 1,
        @as(i128, 48_000),
    );
    const chunk2 = try AudioCaptureData.init(allocator, "mic", &second, start_ns + second_delta_ns, 48_000, 2);
    try timeline.add_data(chunk2);

    const device = timeline.device_map.get("mic") orelse return error.ExpectedDeviceState;
    const expected_end_sample = timeline.processing_delay_samples() + @as(i64, @intCast(samples * 2));
    try std.testing.expectEqual(expected_end_sample, device.expected_next_start_sample.?);
    try std.testing.expectEqual(expected_end_sample, timeline.max_seen_end_sample);
}
