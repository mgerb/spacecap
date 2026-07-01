const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("./store.zig").Store;
const UserSettings = @import("./user_settings.zig").UserSettings;
const String = @import("../string.zig").String;
const FilePickerError = @import("../file_picker/file_picker.zig").FilePickerError;
const CaptureStore = @import("./capture_store.zig").CaptureStore;

const log = std.log.scoped(.user_settings_store);

pub const Message = union(enum) {
    const SetOutputDirectoryPayload = struct {
        allocator: Allocator,
        output_directory: UserSettings.OutputDirectory,
        directory: []u8,

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.directory);
        }
    };

    select_output_directory: UserSettings.OutputDirectory,
    set_capture_fps: u32,
    set_capture_bit_rate: u64,
    set_replay_seconds: u32,
    set_replay_max_bytes: u64,
    set_restore_capture_source_on_startup: bool,
    set_start_replay_buffer_on_startup: bool,
    set_output_directory: SetOutputDirectoryPayload,
    set_audio_device_settings: struct {
        allocator: Allocator,
        device_id: []u8,
        selected: bool,
        gain: f32,

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.device_id);
        }
    },

    pub const effects = .{
        .set_output_directory = .{effect_sync_settings_to_file},
        .set_audio_device_settings = .{effect_sync_settings_to_file},
        .set_capture_fps = .{ effect_sync_settings_to_file, CaptureStore.effect_update_video_capture_fps },
        .set_capture_bit_rate = .{effect_sync_settings_to_file},
        .set_replay_seconds = .{ effect_sync_settings_to_file, CaptureStore.effect_sync_replay_buffer_with_user_settings },
        .set_replay_max_bytes = .{ effect_sync_settings_to_file, CaptureStore.effect_sync_replay_buffer_max_bytes },
        .set_restore_capture_source_on_startup = .{effect_sync_settings_to_file},
        .set_start_replay_buffer_on_startup = .{effect_sync_settings_to_file},
        .select_output_directory = .{effect_select_output_directory},
    };

    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            .set_output_directory => |*payload| payload.deinit(),
            .set_audio_device_settings => |*payload| payload.deinit(),
            inline else => |payload| {
                if (@typeInfo(@TypeOf(payload)) == .@"struct" and
                    @hasDecl(@TypeOf(payload), "deinit"))
                {
                    @compileError("Payload with 'deinit' must be explicitly handled.");
                }
            },
        }
    }
};

pub const State = struct {
    allocator: Allocator,
    user_settings: UserSettings,

    pub fn init(allocator: Allocator, io: std.Io) !@This() {
        return .{
            .allocator = allocator,
            .user_settings = try .init(allocator, io),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.user_settings.deinit(self.allocator);
    }
};

pub fn update(allocator: Allocator, msg: Store.Message, state: *Store.State) !void {
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
                .set_replay_max_bytes => |payload| {
                    state.user_settings.user_settings.replay_max_bytes = payload;
                },
                .set_restore_capture_source_on_startup => |payload| {
                    state.user_settings.user_settings.restore_capture_source_on_startup = payload;
                },
                .set_start_replay_buffer_on_startup => |payload| {
                    state.user_settings.user_settings.start_replay_buffer_on_startup = payload;
                },
                .set_output_directory => |*payload| {
                    defer @constCast(payload).deinit();
                    try state.user_settings.user_settings
                        .set_output_directory(payload.output_directory, try String.init(allocator, payload.directory));
                },
                .set_audio_device_settings => |*payload| {
                    defer @constCast(payload).deinit();

                    try state.user_settings.user_settings.update_audio_device_settings(
                        allocator,
                        payload.device_id,
                        payload.selected,
                        payload.gain,
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
        const state_locked = store.state.lock();
        defer state_locked.unlock();
        const state = state_locked.unwrap_ptr();
        break :blk state.user_settings.user_settings.clone(store.allocator) catch return;
    };
    defer user_settings_snapshot.deinit(store.allocator);

    try user_settings_snapshot.save(store.allocator, store.io);
}

fn effect_select_output_directory(store: *Store, output_directory: UserSettings.OutputDirectory) !void {
    var initial_directory = blk: {
        const state_locked = store.state.lock();
        defer state_locked.unlock();
        const state = state_locked.unwrap_ptr();
        const directory = switch (output_directory) {
            .videos => state.user_settings.user_settings.video_output_directory,
            .screenshots => state.user_settings.user_settings.screenshot_output_directory,
        };
        if (directory) |value| {
            break :blk try value.clone(store.allocator);
        }
        break :blk null;
    };
    defer if (initial_directory) |*directory| directory.deinit();

    // Check if directory exists before trying to open it with
    // the file picker.
    const directory = blk: {
        if (initial_directory) |dir| {
            var opened_dir = std.Io.Dir.openDirAbsolute(store.io, dir.bytes, .{}) catch {
                break :blk null;
            };
            opened_dir.close(store.io);
            break :blk dir.bytes;
        }
        break :blk null;
    };
    const selected_directory = store.file_picker.open_directory_picker(store.allocator, store.io, directory) catch |err| {
        switch (err) {
            FilePickerError.PickerCancelled => {
                log.info("[effect_select_output_directory] output directory selection cancelled", .{});
            },
            else => {
                log.err("[effect_select_output_directory] failed to open output directory picker: {}", .{err});
            },
        }
        return;
    };
    defer store.allocator.free(selected_directory);

    store.dispatch(.{
        .user_settings = .{
            .set_output_directory = .{
                .allocator = store.allocator,
                .output_directory = output_directory,
                .directory = try store.allocator.dupe(u8, selected_directory),
            },
        },
    });
}
