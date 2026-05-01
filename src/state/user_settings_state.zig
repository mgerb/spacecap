const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Actor = @import("./actor.zig").Actor;
const ActionPayload = @import("./action_payload.zig").ActionPayload;
const FilePickerError = @import("../file_picker/file_picker.zig").FilePickerError;
const util = @import("../util.zig");
const Actions = @import("./actor.zig").Actions;
const UserSettings = @import("./user_settings.zig").UserSettings;
const Mutex = @import("../mutex.zig").Mutex;
const String = @import("../string.zig").String;

const log = std.log.scoped(.user_settings_state);

pub const UserSettingsActions = union(enum) {
    select_output_directory,
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
    set_capture_fps: u32,
    set_capture_bit_rate: u64,
    set_replay_seconds: u32,
    set_restore_capture_source_on_startup: bool,
    set_start_replay_buffer_on_startup: bool,
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
};

pub const UserSettingsState = struct {
    const Self = @This();

    allocator: Allocator,
    settings: Mutex(UserSettings),
    output_directory_picker_running: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: Allocator) !Self {
        return .{
            .allocator = allocator,
            .settings = .init(try .init(allocator)),
        };
    }

    pub fn deinit(self: *Self) void {
        var settings_locked = self.settings.lock();
        defer settings_locked.unlock();
        const settings = settings_locked.unwrap_ptr();
        settings.deinit(self.allocator);
    }

    pub fn handle_action(self: *Self, actor: *Actor, action: Actions) !void {
        switch (action) {
            .user_settings => |user_settings_action| {
                switch (user_settings_action) {
                    .set_video_output_directory => |_action| {
                        defer _action.deinit();
                        try self.set_video_output_directory(actor, _action.payload.video_output_directory);
                    },
                    .set_capture_fps => |capture_fps| {
                        try self.set_state(actor, "capture_fps", capture_fps);
                        try actor.video_capture.update_fps(capture_fps);
                    },
                    .set_capture_bit_rate => |capture_bit_rate| {
                        try self.set_state(actor, "capture_bit_rate", capture_bit_rate);
                    },
                    .set_replay_seconds => |replay_seconds| {
                        try self.set_state(actor, "replay_seconds", replay_seconds);
                    },
                    .set_start_replay_buffer_on_startup => |start_replay_buffer_on_startup| {
                        try self.set_state(actor, "start_replay_buffer_on_startup", start_replay_buffer_on_startup);
                    },
                    .set_restore_capture_source_on_startup => |restore_capture_source_on_startup| {
                        try self.set_state(actor, "restore_capture_source_on_startup", restore_capture_source_on_startup);
                    },
                    .set_audio_device_settings => |_action| {
                        defer _action.deinit();
                        const payload = _action.payload;
                        var settings_snapshot: UserSettings = undefined;
                        {
                            const settings_locked = actor.state.user_settings.settings.lock();
                            defer settings_locked.unlock();
                            const settings = settings_locked.unwrap_ptr();
                            try settings.update_audio_device_settings(
                                self.allocator,
                                payload.device_id,
                                payload.selected,
                                payload.gain,
                            );
                            settings_snapshot = try settings.clone(self.allocator);
                        }
                        defer settings_snapshot.deinit(self.allocator);
                        try settings_snapshot.save(self.allocator);
                    },
                    .select_output_directory => {
                        if (self.output_directory_picker_running.swap(true, .acq_rel)) {
                            return;
                        }
                        defer self.output_directory_picker_running.store(false, .release);

                        var initial_directory = blk: {
                            const settings_locked = actor.state.user_settings.settings.lock();
                            defer settings_locked.unlock();
                            const settings = settings_locked.unwrap_ptr();
                            if (settings.video_output_directory) |*directory| {
                                break :blk try directory.clone(self.allocator);
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
                        const selected_directory = actor.file_picker.open_directory_picker(self.allocator, directory) catch |err| {
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
                        defer self.allocator.free(selected_directory);

                        try self.set_video_output_directory(actor, selected_directory);
                    },
                }
            },
            else => {},
        }
    }

    /// Helper function to set a value on the state.
    ///
    /// Locks the UI mutex.
    /// Updates the field.
    /// Deep copy the settings.
    /// Then save (write to disk).
    ///
    /// `field_name` a field on the UserSettings type.
    fn set_state(
        self: *Self,
        actor: *Actor,
        comptime field_name: []const u8,
        value: anytype,
    ) !void {
        var settings_snapshot: UserSettings = blk: {
            const settings_locked = actor.state.user_settings.settings.lock();
            defer settings_locked.unlock();
            const settings = settings_locked.unwrap_ptr();
            @field(settings, field_name) = value;
            break :blk try settings.clone(self.allocator);
        };
        defer settings_snapshot.deinit(self.allocator);
        try settings_snapshot.save(self.allocator);
    }

    fn set_video_output_directory(
        self: *Self,
        actor: *Actor,
        video_output_directory: []const u8,
    ) !void {
        var settings_snapshot: UserSettings = blk: {
            const settings_locked = actor.state.user_settings.settings.lock();
            defer settings_locked.unlock();
            const settings = settings_locked.unwrap_ptr();
            try settings.set_video_output_directory(try String.from(self.allocator, video_output_directory));
            break :blk try settings.clone(self.allocator);
        };
        defer settings_snapshot.deinit(self.allocator);
        try settings_snapshot.save(self.allocator);
    }
};
