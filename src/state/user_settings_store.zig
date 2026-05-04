const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("./store.zig").Store;
const Message = @import("./store.zig").Message;
const State = @import("./store.zig").State;
const UserSettings = @import("./user_settings.zig").UserSettings;
const ActionPayload = @import("./action_payload.zig").ActionPayload;
const String = @import("../string.zig").String;
const FilePickerError = @import("../file_picker/file_picker.zig").FilePickerError;

const log = std.log.scoped(.user_settings_store);

pub const UserSettingsMessage = union(enum) {
    select_output_directory,
    set_capture_fps: u32,
    set_capture_bit_rate: u64,
    set_replay_seconds: u32,
    set_restore_capture_source_on_startup: bool,
    set_start_replay_buffer_on_startup: bool,
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
        .set_video_output_directory = .{effect_sync_settings_to_file},
        .set_audio_device_settings = .{effect_sync_settings_to_file},
        .set_capture_fps = .{effect_sync_settings_to_file},
        .set_capture_bit_rate = .{effect_sync_settings_to_file},
        .set_replay_seconds = .{effect_sync_settings_to_file},
        .set_restore_capture_source_on_startup = .{effect_sync_settings_to_file},
        .set_start_replay_buffer_on_startup = .{effect_sync_settings_to_file},
        .select_output_directory = .{effect_select_output_directory},
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
                .set_capture_bit_rate => |payload| {
                    state.user_settings.user_settings.capture_bit_rate = payload;
                },
                .set_capture_fps => |payload| {
                    state.user_settings.user_settings.capture_fps = payload;
                },
                .set_replay_seconds => |payload| {
                    state.user_settings.user_settings.replay_seconds = payload;
                },
                .set_restore_capture_source_on_startup => |payload| {
                    state.user_settings.user_settings.restore_capture_source_on_startup = payload;
                },
                .set_start_replay_buffer_on_startup => |payload| {
                    state.user_settings.user_settings.start_replay_buffer_on_startup = payload;
                },
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
                else => {},
            }
        },
        else => {},
    }
}

fn effect_sync_settings_to_file(store: *Store, _: anytype) !void {
    var user_settings_snapshot = blk: {
        const locked_state = store.state.lock();
        defer locked_state.unlock();
        const state = locked_state.unwrap_ptr();
        break :blk state.user_settings.user_settings.clone(store.allocator) catch return;
    };
    defer user_settings_snapshot.deinit(store.allocator);

    try user_settings_snapshot.save(store.allocator);
}

fn effect_select_output_directory(store: *Store, _: anytype) !void {
    // TODO:
    // if (self.output_directory_picker_running.swap(true, .acq_rel)) {
    //     return;
    // }
    // defer self.output_directory_picker_running.store(false, .release);

    var initial_directory = blk: {
        const state_locked = store.state.lock();
        defer state_locked.unlock();
        const state = state_locked.unwrap_ptr();
        if (state.user_settings.user_settings.video_output_directory) |video_output_directory| {
            break :blk try video_output_directory.clone(store.allocator);
        }
        break :blk null;
    };
    defer if (initial_directory) |*directory| directory.deinit();

    // Check if directory exists before trying to open it with
    // the file picker.
    const directory = blk: {
        if (initial_directory) |dir| {
            var opened_dir = std.fs.openDirAbsolute(dir.bytes, .{}) catch {
                break :blk null;
            };
            opened_dir.close();
            break :blk dir.bytes;
        }
        break :blk null;
    };
    const selected_directory = store.file_picker.open_directory_picker(store.allocator, directory) catch |err| {
        switch (err) {
            FilePickerError.PickerCancelled => {
                log.info("[select_output_directory] output directory selection cancelled", .{});
            },
            else => {
                log.err("[select_output_directory] failed to open output directory picker: {}", .{err});
            },
        }
        return;
    };
    defer store.allocator.free(selected_directory);

    store.dispatch(.{
        .user_settings = .{
            .set_video_output_directory = try .init(store.allocator, .{ .video_output_directory = selected_directory }),
        },
    });
}
