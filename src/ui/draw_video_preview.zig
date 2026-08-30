const std = @import("std");
const c = @import("imguiz").imguiz;
const dockspace = @import("./dockspace.zig");
const Store = @import("../store/store.zig").Store;
const VideoEditorState = @import("../store/video_editor_store.zig").VideoEditorStore.State;

pub const VideoPreviewArgs = union(enum) {
    // The empty state renders a black background even when a capture source
    // isn't available.
    empty,
    capture_not_supported,
    capture_preview: struct {
        texture: c.ImTextureRef,
        width: u32,
        height: u32,
    },
};

pub const PlayerPreview = struct {
    texture: c.ImTextureRef,
    width: u32,
    height: u32,
};

pub fn draw_video_preview(
    store: *Store,
    args: VideoPreviewArgs,
    video_editor_state: *VideoEditorState,
    player_preview: ?PlayerPreview,
    select_player: bool,
) !void {
    c.ImGui_PushStyleColor(c.ImGuiCol_WindowBg, c.IM_COL32(0, 0, 0, 255));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 0);

    _ = c.ImGui_Begin(dockspace.VIDEO_WINDOW_NAME, null, c.ImGuiWindowFlags_None);
    defer c.ImGui_End();

    c.ImGui_PopStyleColor();
    c.ImGui_PopStyleVarEx(2);

    if (c.ImGui_BeginTabBar("video_preview_tabs", c.ImGuiTabBarFlags_None)) {
        defer c.ImGui_EndTabBar();

        if (c.ImGui_BeginTabItem("Capture", null, c.ImGuiTabItemFlags_None)) {
            defer c.ImGui_EndTabItem();
            if (video_editor_state.active_session_id != null) {
                store.dispatch(.{ .video_editor = .clear_active_session });
            }

            _ = c.ImGui_BeginChild(
                "capture_preview_content",
                .{ .x = 0, .y = 0 },
                c.ImGuiChildFlags_None,
                c.ImGuiWindowFlags_None,
            );
            defer c.ImGui_EndChild();

            try draw_capture_preview(store, args);
        }

        var session_iterator = video_editor_state.sessions.iterator();
        while (session_iterator.next()) |entry| {
            const session_id = entry.key_ptr.*;
            const file_path = entry.value_ptr.as_ptr().file_path.bytes;

            var tab_label_buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
            const tab_label = try std.fmt.bufPrintSentinel(
                &tab_label_buffer,
                "{s}##{}",
                .{ std.fs.path.basename(file_path), @backingInt(session_id) },
                0,
            );
            const is_active = video_editor_state.active_session_id == session_id;
            const player_flags = if (select_player and is_active)
                c.ImGuiTabItemFlags_SetSelected
            else
                c.ImGuiTabItemFlags_None;
            var tab_open = true;
            if (c.ImGui_BeginTabItem(tab_label.ptr, &tab_open, player_flags)) {
                defer c.ImGui_EndTabItem();
                if (!is_active) {
                    store.dispatch(.{ .video_editor = .{ .set_active_session = session_id } });
                }

                _ = c.ImGui_BeginChild(
                    "player_preview_content",
                    .{ .x = 0, .y = 0 },
                    c.ImGuiChildFlags_None,
                    c.ImGuiWindowFlags_None,
                );
                defer c.ImGui_EndChild();

                if (is_active) {
                    if (player_preview) |preview| {
                        draw_preview_image(preview.texture, preview.width, preview.height);
                    }
                }
            }
            if (!tab_open) {
                store.dispatch(.{ .video_editor = .{ .close_session = session_id } });
            }
        }
    }
}

fn draw_capture_preview(store: *Store, args: VideoPreviewArgs) !void {
    const container_size = c.ImGui_GetContentRegionAvail();
    const container_width = container_size.x;
    const container_height = container_size.y;

    switch (args) {
        .empty => {
            const button_width: f32 = 200;
            const button_height = c.ImGui_GetFrameHeight();
            const cursor_x = (container_width - button_width) / 2;
            const cursor_y = (container_height - button_height) / 2;
            c.ImGui_SetCursorPos(.{ .x = cursor_x, .y = cursor_y });
            if (c.ImGui_ButtonEx("󰦳 Select Source", .{ .x = button_width, .y = button_height })) {
                store.dispatch(.{ .capture = .{ .select_video_source = .{ .source_type = .all } } });
            }
        },
        .capture_preview => |capture_preview| {
            draw_preview_image(
                capture_preview.texture,
                capture_preview.width,
                capture_preview.height,
            );
        },
        .capture_not_supported => {
            const message = "Video capture is unavailable on your current hardware, or your video drivers may be out of date.";
            const wrap_width = container_width * 0.8;
            const text_size = c.ImGui_CalcTextSizeEx(message, null, false, wrap_width);
            const cursor_x = (container_width - text_size.x) / 2;
            const cursor_y = (container_height - text_size.y) / 2;
            c.ImGui_SetCursorPos(.{ .x = cursor_x, .y = cursor_y });
            c.ImGui_PushTextWrapPos(cursor_x + wrap_width);
            c.ImGui_TextWrapped(message);
            c.ImGui_PopTextWrapPos();
        },
    }
}

fn draw_preview_image(texture: c.ImTextureRef, width: u32, height: u32) void {
    const container_size = c.ImGui_GetContentRegionAvail();
    const image_width: f32 = @floatFromInt(width);
    const image_height: f32 = @floatFromInt(height);
    const aspect_ratio = image_width / image_height;

    var render_width = container_size.x;
    var render_height = render_width / aspect_ratio;
    if (render_height > container_size.y) {
        render_height = container_size.y;
        render_width = render_height * aspect_ratio;
    }

    c.ImGui_SetCursorPos(.{
        .x = (container_size.x - render_width) / 2,
        .y = (container_size.y - render_height) / 2,
    });
    c.ImGui_Image(texture, .{ .x = render_width, .y = render_height });
}
