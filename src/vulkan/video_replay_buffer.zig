const std = @import("std");
const assert = std.debug.assert;
const ReplayWindow = @import("../types.zig").ReplayWindow;

pub const VideoReplayBufferFrame = struct {
    timestamp_ns: i128,
    data: std.ArrayList(u8),
    is_idr: bool,
};

pub const VideoReplayBufferNode = struct {
    data: VideoReplayBufferFrame,
    node: std.DoublyLinkedList.Node = .{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *@This()) void {
        self.data.data.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

pub const VideoReplayBuffer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    frames: std.DoublyLinkedList,
    /// The total size of all the data in the buffer
    size: u64,
    /// The length of the linked list
    len: u32 = 0,
    header_frame: std.ArrayList(u8),
    replay_seconds: u32,

    /// replay_seconds - total time in seconds to retain
    /// Caller owns memory
    pub fn init(
        allocator: std.mem.Allocator,
        replay_seconds: u32,
        header_frame_data: []const u8,
    ) !*Self {
        const frames = std.DoublyLinkedList{};

        var header_frame = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer header_frame.deinit(allocator);
        try header_frame.appendSlice(allocator, header_frame_data);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .frames = frames,
            .size = 0,
            .header_frame = header_frame,
            .replay_seconds = replay_seconds,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.header_frame.deinit(self.allocator);
        while (self.frames.popFirst()) |node| {
            const l: *VideoReplayBufferNode = @alignCast(@fieldParentPtr("node", node));
            l.data.data.deinit(self.allocator);
            self.allocator.destroy(l);
        }
        self.allocator.destroy(self);
    }

    pub fn addFrame(self: *Self, data: []const u8, frame_time_ns: i128, is_idr: bool) !void {
        var data_list = try std.ArrayList(u8).initCapacity(self.allocator, data.len);
        try data_list.appendSlice(self.allocator, data);

        var node = try self.allocator.create(VideoReplayBufferNode);
        errdefer self.allocator.destroy(self);

        node.* = .{
            .data = .{
                .timestamp_ns = frame_time_ns,
                .data = data_list,
                .is_idr = is_idr,
            },
            .allocator = self.allocator,
        };

        // Remove all frames before the replay window.
        // TODO: Double check if we need this now. Replays have been refactored since this.
        // Add 1 second buffer - this makes the video time more accurate in a player
        const oldest_ns = frame_time_ns - (@as(i128, @intCast(self.replay_seconds + 1)) * std.time.ns_per_s);
        while (true) {
            if (self.frames.first) |first| {
                const first_node: *VideoReplayBufferNode = @alignCast(@fieldParentPtr("node", first));
                if (first_node.data.timestamp_ns < oldest_ns) {
                    self.removeFirstFrame();
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        self.frames.append(&node.node);
        self.len += 1;
        self.size += data.len;
    }

    pub fn getSeconds(self: *const Self) u32 {
        if (self.frames.first) |first| {
            const first_node: *VideoReplayBufferNode = @alignCast(@fieldParentPtr("node", first));
            if (self.frames.last) |last| {
                const last_node: *VideoReplayBufferNode = @alignCast(@fieldParentPtr("node", last));

                if (first_node != last_node) {
                    const total_time = last_node.data.timestamp_ns - first_node.data.timestamp_ns;
                    const total_seconds: u32 = @intCast(@divFloor(total_time, std.time.ns_per_s));
                    return total_seconds;
                }
            }
        }
        return 0;
    }

    /// Remove and deallocate first frame
    fn removeFirstFrame(self: *Self) void {
        if (self.frames.popFirst()) |first| {
            const node: *VideoReplayBufferNode = @alignCast(@fieldParentPtr("node", first));
            self.size -= node.data.data.items.len;
            node.deinit();
            self.len -= 1;
        }
    }

    /// Pop and return the first node. Caller owns the memory.
    pub fn popFirstOwned(self: *Self) !?*VideoReplayBufferNode {
        if (self.frames.popFirst()) |first| {
            self.len -= 1;
            return @alignCast(@fieldParentPtr("node", first));
        }

        return null;
    }

    /// Remove all frames from the start until an IDR frame is reached.
    pub fn ensureFirstFrameIsIdr(self: *Self) void {
        var node = self.frames.first;
        while (node) |current| : (node = current.next) {
            const frame_node: *VideoReplayBufferNode = @alignCast(@fieldParentPtr("node", current));
            if (!frame_node.data.is_idr) {
                self.removeFirstFrame();
            } else {
                break;
            }
        }
    }

    /// Get timestamps of the first/last frames.
    pub fn getReplayWindow(self: *Self) ?ReplayWindow {
        if (self.frames.first) |first_node| {
            if (self.frames.last) |last_node| {
                const first_frame_node: *VideoReplayBufferNode = @alignCast(@fieldParentPtr("node", first_node));
                const last_frame_node: *VideoReplayBufferNode = @alignCast(@fieldParentPtr("node", last_node));
                assert(first_frame_node.data.timestamp_ns <= last_frame_node.data.timestamp_ns);
                return .{ .start_ns = first_frame_node.data.timestamp_ns, .end_ns = last_frame_node.data.timestamp_ns };
            }
        }

        return null;
    }
};

test "addFrame - should add a frame with 3 bytes" {
    var replay_buffer = try VideoReplayBuffer.init(std.testing.allocator, 30, &.{});
    defer replay_buffer.deinit();
    try replay_buffer.addFrame(&[_]u8{ 1, 2, 3 }, 0, false);
    try std.testing.expectEqual(@as(u64, 3), replay_buffer.size);
    try std.testing.expectEqual(@as(u32, 1), replay_buffer.len);
}

test "addFrame - should trim frames outside replay window" {
    const replay_seconds = 2;
    // The implementation keeps replay_seconds + 1 seconds of data.
    const max_seconds_retained = replay_seconds + 1;
    const max_frames = max_seconds_retained + 1;
    var replay_buffer = try VideoReplayBuffer.init(std.testing.allocator, replay_seconds, &.{});
    defer replay_buffer.deinit();

    for (0..10) |i| {
        const ts_ns = @as(i128, @intCast(i)) * std.time.ns_per_s;
        try replay_buffer.addFrame(&[_]u8{1}, ts_ns, false);

        const expected_len_u = if (i + 1 > max_frames) max_frames else i + 1;
        const expected_len: u32 = @intCast(expected_len_u);
        try std.testing.expectEqual(expected_len, replay_buffer.len);
        try std.testing.expectEqual(@as(u64, expected_len), replay_buffer.size);
    }

    try std.testing.expectEqual(max_seconds_retained, replay_buffer.getSeconds());
}

test "getReplayWindow - returns null when empty and first/last timestamps when populated" {
    var replay_buffer = try VideoReplayBuffer.init(std.testing.allocator, 10, &.{});
    defer replay_buffer.deinit();

    try std.testing.expect(replay_buffer.getReplayWindow() == null);

    try replay_buffer.addFrame(&[_]u8{ 0xAA }, 11, false);
    try replay_buffer.addFrame(&[_]u8{ 0xBB }, 22, false);
    try replay_buffer.addFrame(&[_]u8{ 0xCC }, 33, true);

    const window = replay_buffer.getReplayWindow() orelse return error.ExpectedReplayWindow;
    try std.testing.expectEqual(@as(i128, 11), window.start_ns);
    try std.testing.expectEqual(@as(i128, 33), window.end_ns);
}
