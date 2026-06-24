const std = @import("std");

const Allocator = std.mem.Allocator;

/// Owns UI only values that need to survive across frames. All state local to
/// the UI should be stored in here. Values in here are for presentation only
/// and not application state.
pub const UIStorage = struct {
    const Self = @This();

    allocator: Allocator,
    audio_level_display_by_id: std.StringHashMap(f32),

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .audio_level_display_by_id = .init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.audio_level_display_by_id.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.audio_level_display_by_id.deinit();
    }

    pub fn get_audio_level_display(self: *Self, device_id: []const u8) !?f32 {
        return self.audio_level_display_by_id.get(device_id);
    }

    pub fn put_audio_level_display(self: *Self, device_id: []const u8, level: f32) !void {
        const gop = try self.audio_level_display_by_id.getOrPut(device_id);
        if (gop.found_existing) {
            gop.value_ptr.* = level;
        } else {
            const new_id = try self.allocator.dupe(u8, device_id);
            errdefer self.allocator.free(new_id);
            gop.key_ptr.* = new_id;
            gop.value_ptr.* = level;
        }
    }

    pub fn clear_audio_level_display(self: *Self, device_id: []const u8) void {
        if (self.audio_level_display_by_id.fetchRemove(device_id)) |entry| {
            self.allocator.free(entry.key);
        }
    }
};
