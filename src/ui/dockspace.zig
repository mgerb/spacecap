const c = @import("imguiz").imguiz;

pub const LEFT_WINDOW_NAME = "left column";
pub const VIDEO_WINDOW_NAME = "video preview";
pub const BOTTOM_WINDOW_NAME = "bottom panel";

const DOCKSPACE_WINDOW_NAME = "SpacecapDockSpace";
const DOCKSPACE_ID = "spacecap-dockspace";

// Flags
const DOCK_NODE_FLAGS_DOCK_SPACE: c.ImGuiDockNodeFlags = 1 << 10;
const DOCK_NODE_FLAGS_NO_TAB_BAR: c.ImGuiDockNodeFlags = 1 << 12;
const DOCK_NODE_FLAGS_NO_WINDOW_MENU_BUTTON: c.ImGuiDockNodeFlags = 1 << 14;
const PANE_DOCK_NODE_FLAGS = c.ImGuiDockNodeFlags_NoUndocking |
    DOCK_NODE_FLAGS_NO_TAB_BAR |
    DOCK_NODE_FLAGS_NO_WINDOW_MENU_BUTTON;

// ----------------------------------------------------------------------------
// These are not provided by imguiz because they are internal ImGui functions.
// The docking API is still not final and these are subject to change.
//
// https://github.com/ocornut/imgui/wiki/Docking#programmatically-setting-up-docking-layout-dockbuider-api
// ----------------------------------------------------------------------------
extern fn ImGui_DockBuilderGetNode(node_id: c.ImGuiID) ?*anyopaque;
extern fn ImGui_DockBuilderRemoveNode(node_id: c.ImGuiID) void;
extern fn ImGui_DockBuilderAddNodeEx(node_id: c.ImGuiID, flags: c.ImGuiDockNodeFlags) c.ImGuiID;
extern fn ImGui_DockBuilderSetNodePos(node_id: c.ImGuiID, pos: c.ImVec2) void;
extern fn ImGui_DockBuilderSetNodeSize(node_id: c.ImGuiID, size: c.ImVec2) void;
extern fn ImGui_DockBuilderSplitNode(
    node_id: c.ImGuiID,
    split_dir: c.ImGuiDir,
    size_ratio_for_node_at_dir: f32,
    out_id_at_dir: *c.ImGuiID,
    out_id_at_opposite_dir: *c.ImGuiID,
) c.ImGuiID;
extern fn ImGui_DockBuilderDockWindow(window_name: [*c]const u8, node_id: c.ImGuiID) void;
extern fn ImGui_DockBuilderFinish(node_id: c.ImGuiID) void;
// ----------------------------------------------------------------------------

pub fn draw_dockspace() void {
    const viewport = c.ImGui_GetMainViewport();
    c.ImGui_SetNextWindowPos(viewport.*.Pos, 0);
    c.ImGui_SetNextWindowSize(viewport.*.Size, 0);
    c.ImGui_SetNextWindowViewport(viewport.*.ID);

    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0.0, .y = 0.0 });
    _ = c.ImGui_Begin(DOCKSPACE_WINDOW_NAME, null, c.ImGuiWindowFlags_NoTitleBar |
        c.ImGuiWindowFlags_NoCollapse |
        c.ImGuiWindowFlags_NoResize |
        c.ImGuiWindowFlags_NoMove |
        c.ImGuiWindowFlags_NoBringToFrontOnFocus |
        c.ImGuiWindowFlags_NoNavFocus |
        c.ImGuiWindowFlags_NoDocking);
    defer c.ImGui_PopStyleVarEx(1);
    defer c.ImGui_End();

    const dockspace_id = c.ImGui_GetID(DOCKSPACE_ID);
    // Only execute once at app startup.
    if (ImGui_DockBuilderGetNode(dockspace_id) == null) {
        build_default_layout(dockspace_id, viewport);
    }

    _ = c.ImGui_DockSpaceEx(
        dockspace_id,
        .{ .x = 0.0, .y = 0.0 },
        PANE_DOCK_NODE_FLAGS,
        null,
    );
}

fn build_default_layout(dockspace_id: c.ImGuiID, viewport: *const c.ImGuiViewport) void {
    ImGui_DockBuilderRemoveNode(dockspace_id);
    _ = ImGui_DockBuilderAddNodeEx(
        dockspace_id,
        DOCK_NODE_FLAGS_DOCK_SPACE |
            PANE_DOCK_NODE_FLAGS,
    );
    ImGui_DockBuilderSetNodePos(dockspace_id, viewport.Pos);
    ImGui_DockBuilderSetNodeSize(dockspace_id, viewport.Size);

    var left_id: c.ImGuiID = 0;
    var right_id: c.ImGuiID = 0;
    _ = ImGui_DockBuilderSplitNode(dockspace_id, c.ImGuiDir_Left, 0.24, &left_id, &right_id);

    var video_id: c.ImGuiID = 0;
    var bottom_id: c.ImGuiID = 0;
    _ = ImGui_DockBuilderSplitNode(right_id, c.ImGuiDir_Down, 0.50, &bottom_id, &video_id);

    ImGui_DockBuilderDockWindow(LEFT_WINDOW_NAME, left_id);
    ImGui_DockBuilderDockWindow(VIDEO_WINDOW_NAME, video_id);
    ImGui_DockBuilderDockWindow(BOTTOM_WINDOW_NAME, bottom_id);
    ImGui_DockBuilderFinish(dockspace_id);
}
