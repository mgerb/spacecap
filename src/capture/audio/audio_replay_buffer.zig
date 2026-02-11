const std = @import("std");
const Allocator = std.mem.Allocator;
const AudioCaptureData = @import("./audio_capture_data.zig");

const log = std.log.scoped(.AudioReplayBuffer);
const Self = @This();

allocator: std.mem.Allocator,
/// Linked list of AudioCaptureData
buffer_map: std.StringHashMap(std.DoublyLinkedList),
replay_seconds: u32,

pub fn init(allocator: Allocator, replay_seconds: u32) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .buffer_map = .init(allocator),
        .replay_seconds = replay_seconds,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    self.removeData(.remove_all) catch |err| {
        log.err("[deinit] remove Data error: {}", .{err});
    };
    self.buffer_map.deinit();
    self.allocator.destroy(self);
}

/// Add data to the audio replay buffer. Audio replay buffer now owns the data.
pub fn addData(self: *Self, data: *AudioCaptureData) error{OutOfMemory}!void {
    const gop = try self.buffer_map.getOrPut(data.id);
    if (!gop.found_existing) {
        errdefer _ = self.buffer_map.remove(data.id);
        const key_copy = try self.allocator.dupe(u8, data.id);
        gop.key_ptr.* = key_copy;
        gop.value_ptr.* = .{};
    }
    const linked_list = gop.value_ptr;
    linked_list.append(@constCast(&data.node));

    try self.removeData(.{ .timestamp_ns = data.start_ns() });
}

fn removeData(self: *Self, args: union(enum) {
    remove_all,
    timestamp_ns: i128,
}) !void {
    const oldest_ns = switch (args) {
        .timestamp_ns => |timestamp_ns| timestamp_ns - (@as(i128, @intCast(self.replay_seconds + 1)) * std.time.ns_per_s),
        .remove_all => 0,
    };

    var iter = self.buffer_map.iterator();
    var keys_to_remove = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
    defer keys_to_remove.deinit(self.allocator);

    while (iter.next()) |entry| {
        const linked_list = entry.value_ptr;
        var node = linked_list.first;

        while (node) |current| {
            const next = current.next;
            const audio_capture_data: *AudioCaptureData = @alignCast(@fieldParentPtr("node", current));
            const should_remove = switch (args) {
                .remove_all => true,
                .timestamp_ns => audio_capture_data.timestamp < oldest_ns,
            };

            if (should_remove) {
                linked_list.remove(current);
                audio_capture_data.deinit();
            }

            node = next;
        }

        // Remove the keys after the loop, otherwise we mess with the iterator.
        if (linked_list.first == null) {
            try keys_to_remove.append(self.allocator, entry.key_ptr.*);
        }
    }

    for (keys_to_remove.items) |key| {
        _ = self.buffer_map.remove(key);
        self.allocator.free(key);
    }

    if (args == .remove_all) {
        self.buffer_map.clearRetainingCapacity();
    }
}

fn listLen(list: *const std.DoublyLinkedList) u32 {
    var len: u32 = 0;
    var node = list.first;
    while (node) |current| : (node = current.next) {
        len += 1;
    }
    return len;
}

test "addData - stores data grouped by id in append order" {
    const allocator = std.testing.allocator;
    const device_a = "device_a";
    const device_b = "device_b";

    var replay_buffer = try Self.init(std.testing.allocator, 10);
    defer replay_buffer.deinit();

    const ns = std.time.ns_per_s;
    const pcm_a0 = [_]f32{0.1};
    const pcm_a1 = [_]f32{0.2};
    const pcm_b0 = [_]f32{0.3};

    try replay_buffer.addData(try AudioCaptureData.init(allocator, device_a, &pcm_a0, 1 * ns, 48000, 1));
    try replay_buffer.addData(try AudioCaptureData.init(allocator, device_a, &pcm_a1, 2 * ns, 48000, 1));
    try replay_buffer.addData(try AudioCaptureData.init(allocator, device_b, &pcm_b0, 3 * ns, 48000, 1));

    try std.testing.expectEqual(2, replay_buffer.buffer_map.count());

    const list_a = replay_buffer.buffer_map.getPtr(device_a) orelse return error.ExpectedDeviceAList;
    try std.testing.expectEqual(2, listLen(list_a));

    const first_a = list_a.first orelse return error.ExpectedDeviceAFirst;
    const first_a_data: *AudioCaptureData = @alignCast(@fieldParentPtr("node", first_a));
    try std.testing.expectEqual(1 * ns, first_a_data.timestamp);

    const last_a = list_a.last orelse return error.ExpectedDeviceALast;
    const last_a_data: *AudioCaptureData = @alignCast(@fieldParentPtr("node", last_a));
    try std.testing.expectEqual(2 * ns, last_a_data.timestamp);

    const list_b = replay_buffer.buffer_map.getPtr(device_b) orelse return error.ExpectedDeviceBList;
    try std.testing.expectEqual(1, listLen(list_b));
}

test "addData - trims entries outside replay window and removes empty ids" {
    const allocator = std.testing.allocator;
    const device_a = "device_a";
    const device_b = "device_b";

    var replay_buffer = try Self.init(allocator, 1);
    defer replay_buffer.deinit();

    const ns = std.time.ns_per_s;
    const pcm_old_a = [_]f32{0.1};
    const pcm_old_b = [_]f32{0.2};
    const pcm_new_a = [_]f32{0.3};

    try replay_buffer.addData(try AudioCaptureData.init(allocator, device_a, &pcm_old_a, 0, 48000, 1));
    try replay_buffer.addData(try AudioCaptureData.init(allocator, device_b, &pcm_old_b, 0, 48000, 1));
    try std.testing.expect(replay_buffer.buffer_map.getPtr(device_b) != null);
    try replay_buffer.addData(try AudioCaptureData.init(allocator, device_a, &pcm_new_a, 3 * ns, 48000, 1));

    try std.testing.expectEqual(1, replay_buffer.buffer_map.count());
    try std.testing.expect(replay_buffer.buffer_map.getPtr(device_b) == null);

    const list_a = replay_buffer.buffer_map.getPtr(device_a) orelse return error.ExpectedDeviceAList;
    try std.testing.expectEqual(1, listLen(list_a));

    const first_a = list_a.first orelse return error.ExpectedDeviceAFirst;
    const first_a_data: *AudioCaptureData = @alignCast(@fieldParentPtr("node", first_a));
    try std.testing.expectEqual(3 * ns, first_a_data.timestamp);

    // device_b should be gone from the replay buffer.
    try std.testing.expectEqual(replay_buffer.buffer_map.getPtr(device_b), null);
}

test "removeData - remove_all clears all entries and keys" {
    const allocator = std.testing.allocator;
    const device_a = "device_a";
    const device_b = "device_b";

    var replay_buffer = try Self.init(allocator, 10);
    defer replay_buffer.deinit();

    const ns = std.time.ns_per_s;
    const pcm = [_]f32{0.1};

    try replay_buffer.addData(try AudioCaptureData.init(allocator, device_a, &pcm, 1 * ns, 48000, 1));
    try replay_buffer.addData(try AudioCaptureData.init(allocator, device_a, &pcm, 2 * ns, 48000, 1));
    try replay_buffer.addData(try AudioCaptureData.init(allocator, device_b, &pcm, 3 * ns, 48000, 1));
    try std.testing.expectEqual(2, replay_buffer.buffer_map.count());
    try std.testing.expect(replay_buffer.buffer_map.getPtr(device_a) != null);
    try std.testing.expect(replay_buffer.buffer_map.getPtr(device_b) != null);

    try replay_buffer.removeData(.remove_all);

    try std.testing.expectEqual(0, replay_buffer.buffer_map.count());
    try std.testing.expectEqual(replay_buffer.buffer_map.getPtr(device_a), null);
    try std.testing.expectEqual(replay_buffer.buffer_map.getPtr(device_b), null);
}
