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
    self.removeData(.{ .timestamp_ns = 0, .remove_all = true }) catch |err| {
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

fn removeData(self: *Self, args: struct {
    remove_all: bool = false,
    timestamp_ns: i128,
}) !void {
    const oldest_ns = args.timestamp_ns - (@as(i128, @intCast(self.replay_seconds + 1)) * std.time.ns_per_s);

    var iter = self.buffer_map.iterator();
    var keys_to_remove = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
    defer keys_to_remove.deinit(self.allocator);

    while (iter.next()) |entry| {
        const linked_list = entry.value_ptr;
        var node = linked_list.first;

        while (node) |current| {
            const next = current.next;
            const audio_capture_data: *AudioCaptureData = @alignCast(@fieldParentPtr("node", current));
            const should_remove = args.remove_all or audio_capture_data.timestamp < oldest_ns;

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

    if (args.remove_all) {
        self.buffer_map.clearRetainingCapacity();
    }
}
