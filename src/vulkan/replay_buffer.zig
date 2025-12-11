const std = @import("std");

const ReplayBufferFrame = struct {
    frame_time: i128,
    data: std.ArrayList(u8),
    is_idr: bool,
};

const ReplayBufferNode = struct {
    data: ReplayBufferFrame,
    node: std.DoublyLinkedList.Node = .{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *@This()) void {
        self.data.data.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

pub const ReplayBuffer = struct {
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
        try header_frame.appendSlice(allocator, header_frame_data);

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .frames = frames,
            .size = 0,
            .header_frame = header_frame,
            .replay_seconds = replay_seconds,
        };

        return self;
    }

    pub fn addFrame(self: *Self, data: []const u8, frame_time_ns: i128, is_idr: bool) !void {
        var data_list = try std.ArrayList(u8).initCapacity(self.allocator, data.len);
        try data_list.appendSlice(self.allocator, data);

        var node = try self.allocator.create(ReplayBufferNode);
        node.* = .{
            .data = .{
                .frame_time = frame_time_ns,
                .data = data_list,
                .is_idr = is_idr,
            },
            .allocator = self.allocator,
        };

        // Remove all frames before the replay seconds
        while (true) {
            if (self.frames.first) |first| {
                const first_node: *ReplayBufferNode = @alignCast(@fieldParentPtr("node", first));
                const now = std.time.nanoTimestamp();
                // Add 1 second buffer - this makes the video time more accurate in a player
                if (first_node.data.frame_time < (now - (@as(i128, @intCast(self.replay_seconds + 1)) * std.time.ns_per_s))) {
                    try self.removeFirstFrame();
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

    /// TODO: unit test
    /// Get the total number of seconds currently occupying the buffer
    pub fn getSeconds(self: *const Self) u32 {
        if (self.frames.first) |first| {
            const first_node: *ReplayBufferNode = @alignCast(@fieldParentPtr("node", first));
            if (self.frames.last) |last| {
                const last_node: *ReplayBufferNode = @alignCast(@fieldParentPtr("node", last));

                if (first_node != last_node) {
                    const total_time = last_node.data.frame_time - first_node.data.frame_time;
                    const total_seconds: u32 = @intCast(@divFloor(total_time, std.time.ns_per_s));
                    return total_seconds;
                }
            }
        }
        return 0;
    }

    /// Remove and deallocate first frame
    fn removeFirstFrame(self: *Self) !void {
        if (self.frames.popFirst()) |first| {
            const node: *ReplayBufferNode = @alignCast(@fieldParentPtr("node", first));
            self.size -= node.data.data.items.len;
            node.deinit();
            self.len -= 1;
        }
    }

    /// Pop and return the first node. Caller owns the memory.
    pub fn popFirstOwned(self: *Self) !?*ReplayBufferNode {
        if (self.frames.popFirst()) |first| {
            return @alignCast(@fieldParentPtr("node", first));
        }

        return null;
    }

    pub fn deinit(self: *Self) void {
        self.header_frame.deinit(self.allocator);
        while (self.frames.popFirst()) |node| {
            const l: *ReplayBufferNode = @alignCast(@fieldParentPtr("node", node));
            l.data.data.deinit(self.allocator);
            self.allocator.destroy(l);
        }
        self.allocator.destroy(self);
    }
};

test "addFrame - should add a frame with 3 bytes" {
    var replay_buffer = ReplayBuffer.init(std.testing.allocator, 30, 60);
    defer replay_buffer.deinit();
    try replay_buffer.addFrame(&[_]u8{ 1, 2, 3 });
    try std.testing.expectEqual(replay_buffer.size, 3);
    try std.testing.expectEqual(replay_buffer.len, 1);
}

test "addFrame - should cap at capacity" {
    // max frames should be 1800 with 30 fps and 60 seconds
    const fps = 32;
    const replay_seconds = 60;
    const max_frames = fps * replay_seconds;
    var replay_buffer = ReplayBuffer.init(std.testing.allocator, fps, replay_seconds);
    defer replay_buffer.deinit();

    for (0..20000) |i| {
        try replay_buffer.addFrame(&[_]u8{1});
        try std.testing.expect(replay_buffer.size <= max_frames);
        const frame = i + 1;
        if (frame > max_frames) {
            try std.testing.expectEqual(replay_buffer.len, max_frames);
        } else {
            try std.testing.expectEqual(replay_buffer.len, frame);
        }
    }
}
