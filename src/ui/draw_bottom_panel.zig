const c = @import("imguiz").imguiz;
const dockspace = @import("./dockspace.zig");

pub fn draw_bottom_panel() void {
    _ = c.ImGui_Begin(dockspace.BOTTOM_WINDOW_NAME, null, c.ImGuiWindowFlags_None);
    defer c.ImGui_End();
}
