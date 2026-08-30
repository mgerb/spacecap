const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("imguiz").imguiz;
const dockspace = @import("./dockspace.zig");
const Store = @import("../store/store.zig").Store;
const UIStorage = @import("./ui_storage.zig").UIStorage;
const draw_capture_controls = @import("./draw_capture_controls.zig").draw_capture_controls;
const draw_editor_controls = @import("./draw_editor_controls.zig").draw_editor_controls;

pub fn draw_controls_panel(
    allocator: Allocator,
    ui_storage: *UIStorage,
    store: *Store,
    state: *Store.State,
) !void {
    _ = c.ImGui_Begin(dockspace.BOTTOM_WINDOW_NAME, null, c.ImGuiWindowFlags_None);
    defer c.ImGui_End();

    if (state.video_editor.active_session_id) |session_id| {
        draw_editor_controls(ui_storage, store, state, session_id);
    } else {
        ui_storage.clear_editor_drag();
        try draw_capture_controls(allocator, ui_storage, store, state);
    }
}
