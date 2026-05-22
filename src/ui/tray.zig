const std = @import("std");
const assert = std.debug.assert;

const imguiz = @import("imguiz").imguiz;
const Store = @import("../store/store.zig").Store;
const AppIcon = @import("./app_icon.zig").AppIcon;

/// Use the SDL3 API to interact with the system tray.
/// NOTE: Interactions must be on the UI thread.
pub const Tray = struct {
    const log = std.log.scoped(.tray);
    const Self = @This();

    pub const State = struct {
        recording_to_disk: bool = false,
        replay_buffer_active: bool = false,
        video_capture_active: bool = false,
    };

    store: *Store,
    tray: *imguiz.SDL_Tray,
    replay_buffer_entry: *imguiz.SDL_TrayEntry,
    save_replay_entry: *imguiz.SDL_TrayEntry,
    recording_entry: *imguiz.SDL_TrayEntry,
    state: State = .{
        .recording_to_disk = false,
        .replay_buffer_active = false,
        .video_capture_active = false,
    },

    pub fn init(store: *Store, app_icon: *AppIcon) !Self {
        const tray = imguiz.SDL_CreateTray(app_icon.app_icon_surface_blue, "Spacecap") orelse return error.TrayInitCreateTray;
        errdefer {
            imguiz.SDL_DestroyTray(tray);
        }
        const menu = imguiz.SDL_CreateTrayMenu(tray) orelse {
            log.warn("[init_sdl_tray] failed to create tray menu: {s}", .{imguiz.SDL_GetError()});
            return error.TrayInitMenu;
        };

        const save_replay_entry = try insert_tray_entry(menu, "Save Replay");
        imguiz.SDL_SetTrayEntryCallback(save_replay_entry, save_replay_callback, store);

        try insert_tray_separator(menu);

        const replay_buffer_entry = try insert_tray_checkbox_entry(menu, "Replay Buffer");
        imguiz.SDL_SetTrayEntryCallback(replay_buffer_entry, replay_buffer_callback, store);

        const recording_entry = try insert_tray_checkbox_entry(menu, "Recording");
        imguiz.SDL_SetTrayEntryCallback(recording_entry, recording_callback, store);

        try insert_tray_separator(menu);

        const quit_entry = imguiz.SDL_InsertTrayEntryAt(menu, -1, "Quit", imguiz.SDL_TRAYENTRY_BUTTON) orelse {
            log.warn("[init_sdl_tray] failed to create tray quit entry", .{});
            return error.TrayInitInsertQuitEntry;
        };
        imguiz.SDL_SetTrayEntryCallback(quit_entry, quit_callback, null);

        return .{
            .store = store,
            .tray = tray,
            .replay_buffer_entry = replay_buffer_entry,
            .save_replay_entry = save_replay_entry,
            .recording_entry = recording_entry,
        };
    }

    pub fn deinit(self: *Self) void {
        imguiz.SDL_DestroyTray(self.tray);
    }

    // Update the state of the tray menu entries.
    // WARNING: Not thread safe. Must be called from the UI thread.
    pub fn set_state(self: *Self, state: State, app_icon: *AppIcon) void {
        // SDL toggles checkbox entries before invoking callbacks, but our callbacks
        // only enqueue async store actions. If the action fails, app state stays the
        // same and we still need to restore the native checkbox state, so that is why
        // we also need to compare with the tray state.
        if (std.meta.eql(self.state, state) and
            imguiz.SDL_GetTrayEntryChecked(self.replay_buffer_entry) == state.replay_buffer_active and
            imguiz.SDL_GetTrayEntryChecked(self.recording_entry) == state.recording_to_disk)
        {
            return;
        }

        if (self.state.replay_buffer_active != state.replay_buffer_active or
            self.state.recording_to_disk != state.recording_to_disk)
        {
            imguiz.SDL_SetTrayIcon(self.tray, get_surface_for_state(.{
                .recording_to_disk = state.recording_to_disk,
                .replay_buffer_active = state.replay_buffer_active,
            }, app_icon));
        }

        imguiz.SDL_SetTrayTooltip(self.tray, get_tooltip_for_state(state));

        imguiz.SDL_SetTrayEntryEnabled(self.save_replay_entry, state.replay_buffer_active);

        imguiz.SDL_SetTrayEntryChecked(self.replay_buffer_entry, state.replay_buffer_active);
        imguiz.SDL_SetTrayEntryEnabled(self.replay_buffer_entry, state.video_capture_active or state.replay_buffer_active);

        imguiz.SDL_SetTrayEntryChecked(self.recording_entry, state.recording_to_disk);
        imguiz.SDL_SetTrayEntryEnabled(self.recording_entry, state.video_capture_active or state.recording_to_disk);

        self.state = state;
    }

    fn insert_tray_entry(menu: *imguiz.SDL_TrayMenu, comptime name: [:0]const u8) !*imguiz.SDL_TrayEntry {
        const tray_entry = imguiz.SDL_InsertTrayEntryAt(menu, -1, name, imguiz.SDL_TRAYENTRY_BUTTON) orelse {
            log.warn("[init_sdl_tray] failed to create tray entry: " ++ name, .{});
            return error.TrayInitInsertStartRecordEntry;
        };
        imguiz.SDL_SetTrayEntryEnabled(tray_entry, false);
        return tray_entry;
    }

    fn insert_tray_checkbox_entry(menu: *imguiz.SDL_TrayMenu, comptime name: [:0]const u8) !*imguiz.SDL_TrayEntry {
        const tray_entry = imguiz.SDL_InsertTrayEntryAt(menu, -1, name, imguiz.SDL_TRAYENTRY_CHECKBOX) orelse {
            log.warn("[init_sdl_tray] failed to create tray checkbox entry: " ++ name, .{});
            return error.TrayInitInsertCheckboxEntry;
        };
        imguiz.SDL_SetTrayEntryEnabled(tray_entry, false);
        imguiz.SDL_SetTrayEntryChecked(tray_entry, false);
        return tray_entry;
    }

    fn insert_tray_separator(menu: *imguiz.SDL_TrayMenu) !void {
        _ = imguiz.SDL_InsertTrayEntryAt(menu, -1, null, 0) orelse {
            log.warn("[init_sdl_tray] failed to create tray separator", .{});
            return error.TrayInitInsertSeparator;
        };
    }

    pub fn get_surface_for_state(state: State, app_icon: *AppIcon) *imguiz.SDL_Surface {
        return if (state.recording_to_disk or state.replay_buffer_active)
            app_icon.app_icon_surface_red
        else
            app_icon.app_icon_surface_blue;
    }

    fn get_tooltip_for_state(state: State) [*c]const u8 {
        return if (state.replay_buffer_active and state.recording_to_disk)
            "Spacecap - Recording / Replay Buffer Active"
        else if (state.recording_to_disk)
            "Spacecap - Recording"
        else if (state.replay_buffer_active)
            "Spacecap - Replay Buffer Active"
        else
            "Spacecap";
    }

    fn save_replay_callback(userdata: ?*anyopaque, _: ?*imguiz.SDL_TrayEntry) callconv(.c) void {
        assert(userdata != null);
        const store: *Store = @ptrCast(@alignCast(userdata));
        store.dispatch(.{ .capture = .save_replay });
    }

    fn replay_buffer_callback(userdata: ?*anyopaque, _: ?*imguiz.SDL_TrayEntry) callconv(.c) void {
        assert(userdata != null);
        const store: *Store = @ptrCast(@alignCast(userdata));

        const is_replay_buffer_active = blk: {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            break :blk state_locked.unwrap_ptr().capture.replay_buffer_active;
        };

        if (is_replay_buffer_active) {
            store.dispatch(.{ .capture = .stop_replay_buffer });
        } else {
            store.dispatch(.{ .capture = .start_replay_buffer });
        }
    }

    fn recording_callback(userdata: ?*anyopaque, _: ?*imguiz.SDL_TrayEntry) callconv(.c) void {
        assert(userdata != null);
        const store: *Store = @ptrCast(@alignCast(userdata));

        const recording_to_disk = blk: {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            break :blk state_locked.unwrap_ptr().capture.recording_to_disk;
        };

        if (recording_to_disk) {
            store.dispatch(.{ .capture = .stop_recording_to_disk });
        } else {
            store.dispatch(.{ .capture = .start_recording_to_disk });
        }
    }

    fn quit_callback(_: ?*anyopaque, _: ?*imguiz.SDL_TrayEntry) callconv(.c) void {
        var event: imguiz.SDL_Event = std.mem.zeroes(imguiz.SDL_Event);
        event.type = imguiz.SDL_EVENT_QUIT;
        if (!imguiz.SDL_PushEvent(&event)) {
            log.warn("[quit_callback] failed to push quit event: {s}", .{imguiz.SDL_GetError()});
        }
    }
};
