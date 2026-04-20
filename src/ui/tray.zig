const std = @import("std");
const assert = std.debug.assert;

const imguiz = @import("imguiz").imguiz;
const Actor = @import("../state/actor.zig").Actor;
const AppIcon = @import("./app_icon.zig").AppIcon;

const APP_ICON_TOOLTIP = "Spacecap";
const APP_ICON_RECORDING_TOOLTIP = "Spacecap - Replay Buffer Recording";

/// Use the SDL3 API to interact with the system tray.
/// NOTE: Interactions must be on the UI thread.
pub const Tray = struct {
    const log = std.log.scoped(.tray);
    const Self = @This();

    pub const State = struct {
        is_recording: bool,
        is_capturing: bool,
    };

    actor: *Actor,
    app_icon: *AppIcon,
    tray: *imguiz.SDL_Tray,
    start_replay_buffer_entry: *imguiz.SDL_TrayEntry,
    stop_replay_buffer_entry: *imguiz.SDL_TrayEntry,
    save_replay_entry: *imguiz.SDL_TrayEntry,
    state: State = .{
        .is_recording = false,
        .is_capturing = false,
    },

    pub fn init(actor: *Actor, app_icon: *AppIcon) !Self {
        const tray = imguiz.SDL_CreateTray(app_icon.app_icon_surface_blue, "Spacecap") orelse return error.TrayInitCreateTray;
        errdefer {
            imguiz.SDL_DestroyTray(tray);
        }
        const menu = imguiz.SDL_CreateTrayMenu(tray) orelse {
            log.warn("[init_sdl_tray] failed to create tray menu: {s}", .{imguiz.SDL_GetError()});
            return error.TrayInitMenu;
        };

        const start_record_entry = try insert_tray_entry(menu, "Start Replay Buffer");
        imguiz.SDL_SetTrayEntryCallback(start_record_entry, start_record_callback, actor);

        const stop_record_entry = try insert_tray_entry(menu, "Stop Replay Buffer");
        imguiz.SDL_SetTrayEntryCallback(stop_record_entry, stop_record_callback, actor);

        const save_replay_entry = try insert_tray_entry(menu, "Save Replay");
        imguiz.SDL_SetTrayEntryCallback(save_replay_entry, save_replay_callback, actor);

        const quit_entry = imguiz.SDL_InsertTrayEntryAt(menu, -1, "Quit", imguiz.SDL_TRAYENTRY_BUTTON) orelse {
            log.warn("[init_sdl_tray] failed to create tray quit entry", .{});
            return error.TrayInitInsertQuitEntry;
        };
        imguiz.SDL_SetTrayEntryCallback(quit_entry, quit_callback, null);

        return .{
            .actor = actor,
            .app_icon = app_icon,
            .tray = tray,
            .start_replay_buffer_entry = start_record_entry,
            .stop_replay_buffer_entry = stop_record_entry,
            .save_replay_entry = save_replay_entry,
        };
    }

    pub fn deinit(self: *Self) void {
        imguiz.SDL_DestroyTray(self.tray);
    }

    // Update the state of the tray menu entries.
    // WARNING: Not thread safe. Must be called from the UI thread.
    pub fn set_state(self: *Self, state: State) void {
        if (std.meta.eql(self.state, state)) {
            return;
        }

        if (self.state.is_recording != state.is_recording) {
            imguiz.SDL_SetTrayIcon(self.tray, self.get_icon_surface_for_state(state.is_recording));
            imguiz.SDL_SetTrayTooltip(self.tray, get_tooltip_for_state(state.is_recording));
        }

        imguiz.SDL_SetTrayEntryEnabled(self.start_replay_buffer_entry, !state.is_recording and state.is_capturing);
        imguiz.SDL_SetTrayEntryEnabled(self.stop_replay_buffer_entry, state.is_recording);
        imguiz.SDL_SetTrayEntryEnabled(self.save_replay_entry, state.is_recording);

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

    fn get_icon_surface_for_state(self: *Self, is_recording: bool) ?*imguiz.SDL_Surface {
        return if (is_recording)
            self.app_icon.app_icon_surface_red
        else
            self.app_icon.app_icon_surface_blue;
    }

    fn get_tooltip_for_state(is_recording: bool) [*c]const u8 {
        return if (is_recording)
            APP_ICON_RECORDING_TOOLTIP
        else
            APP_ICON_TOOLTIP;
    }

    fn start_record_callback(userdata: ?*anyopaque, _: ?*imguiz.SDL_TrayEntry) callconv(.c) void {
        assert(userdata != null);
        const actor: *Actor = @ptrCast(@alignCast(userdata));
        actor.dispatch(.start_record) catch unreachable;
    }

    fn stop_record_callback(userdata: ?*anyopaque, _: ?*imguiz.SDL_TrayEntry) callconv(.c) void {
        assert(userdata != null);
        const actor: *Actor = @ptrCast(@alignCast(userdata));
        actor.dispatch(.stop_record) catch unreachable;
    }

    fn save_replay_callback(userdata: ?*anyopaque, _: ?*imguiz.SDL_TrayEntry) callconv(.c) void {
        assert(userdata != null);
        const actor: *Actor = @ptrCast(@alignCast(userdata));
        actor.dispatch(.save_replay) catch unreachable;
    }

    fn quit_callback(_: ?*anyopaque, _: ?*imguiz.SDL_TrayEntry) callconv(.c) void {
        var event: imguiz.SDL_Event = std.mem.zeroes(imguiz.SDL_Event);
        event.type = imguiz.SDL_EVENT_QUIT;
        if (!imguiz.SDL_PushEvent(&event)) {
            log.warn("[quit_callback] failed to push quit event: {s}", .{imguiz.SDL_GetError()});
        }
    }
};
