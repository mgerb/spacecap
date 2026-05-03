const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("./store.zig").Store;
const Message = @import("./store.zig").Message;
const State = @import("./store.zig").State;
const UserSettings = @import("./user_settings.zig").UserSettings;
const ActionPayload = @import("./action_payload.zig").ActionPayload;
const String = @import("../string.zig").String;

const log = std.log.scoped(.user_settings_store);

pub const UserSettingsMessage = union(enum) {
    set_video_output_directory: *ActionPayload(struct {
        video_output_directory: []u8,

        pub fn init(
            arena: *std.heap.ArenaAllocator,
            args: struct { video_output_directory: []const u8 },
        ) !@This() {
            return .{
                .video_output_directory = try arena.allocator().dupe(u8, args.video_output_directory),
            };
        }
    }),
    set_audio_device_settings: *ActionPayload(struct {
        device_id: []u8,
        selected: bool,
        gain: f32,

        pub fn init(
            arena: *std.heap.ArenaAllocator,
            args: struct { device_id: []u8, selected: bool, gain: f32 },
        ) !@This() {
            return .{
                .device_id = try arena.allocator().dupe(u8, args.device_id),
                .selected = args.selected,
                .gain = args.gain,
            };
        }
    }),

    pub const effects = .{
        .set_video_output_directory = effect_sync_settings_to_file,
        .set_audio_device_settings = effect_sync_settings_to_file,
    };
};

pub const UserSettingsState = struct {
    allocator: Allocator,
    user_settings: UserSettings,

    pub fn init(allocator: Allocator) !@This() {
        return .{
            .allocator = allocator,
            .user_settings = try .init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.user_settings.deinit(self.allocator);
    }
};

pub fn update(allocator: Allocator, msg: Message, state: *State) !void {
    switch (msg) {
        .user_settings => |user_settings_msg| {
            switch (user_settings_msg) {
                .set_video_output_directory => |payload| {
                    defer payload.deinit();
                    try state.user_settings.user_settings
                        .set_video_output_directory(try String.from(allocator, payload.payload.video_output_directory));
                },
                .set_audio_device_settings => |payload| {
                    defer payload.deinit();
                    const _payload = payload.payload;

                    try state.user_settings.user_settings.update_audio_device_settings(
                        allocator,
                        _payload.device_id,
                        _payload.selected,
                        _payload.gain,
                    );
                },
            }
        },
        else => {},
    }
}

fn effect_sync_settings_to_file(store: *Store, _: anytype) void {
    var user_settings_snapshot = blk: {
        const locked_state = store.state.lock();
        defer locked_state.unlock();
        const state = locked_state.unwrap_ptr();
        break :blk state.user_settings.user_settings.clone(store.allocator) catch return;
    };
    defer user_settings_snapshot.deinit(store.allocator);

    user_settings_snapshot.save(store.allocator) catch |err| {
        log.err("[effect_sync_settings_to_file] save error: {}", .{err});
    };
}
