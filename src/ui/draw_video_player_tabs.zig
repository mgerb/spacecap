const std = @import("std");
const c = @import("imguiz").imguiz;
const dockspace = @import("./dockspace.zig");
const imgui_util = @import("./imgui_util.zig");
const Store = @import("../store/store.zig").Store;
const Mutex = @import("../mutex.zig").Mutex;
const VulkanImageRingBuffer = @import("../vulkan/vulkan_image_ring_buffer.zig").VulkanImageRingBuffer;
const VulkanImageBuffer = @import("../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;
const Arc = @import("../arc.zig").Arc;
const Colors = @import("./theme.zig").Colors;

const SessionId = @import("../store/video_editor_session.zig").VideoEditorSession.SessionId;

pub const ActiveTab = union(enum) {
    none,
    capture,
    editor: SessionId,
};

pub const DrawResult = struct {
    display_frame_buffer: ?Arc(VulkanImageBuffer),
    active_tab: ActiveTab,
};

/// Used to select the tab when a video is opened or selected from the file
/// browser. See VideoEditorStore.State.tab_selection_generation_id for more
/// details.
var previous_tab_selection_generation_id: u64 = 0;

pub const CapturePreviewArgs = union(enum) {
    empty,
    capture_not_supported,
    display_frame: VulkanImageRingBuffer.DisplayFrame,
};

/// Draw the video player image, with tabs (capture preview or video editor).
/// Returns the active tab for drawing matching controls, and the image
/// buffer to keep alive until rendering finishes.
pub fn draw_video_player_tabs(
    store: *Store,
    state: *Store.State,
    capture_preview_ring_buffer: *Mutex(?*VulkanImageRingBuffer),
) !DrawResult {
    var active_tab: ActiveTab = .none;
    var display_frame_buffer: ?Arc(VulkanImageBuffer) = null;

    c.ImGui_PushStyleColor(c.ImGuiCol_WindowBg, c.IM_COL32(0, 0, 0, 255));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 0);

    _ = c.ImGui_Begin(dockspace.VIDEO_WINDOW_NAME, null, c.ImGuiWindowFlags_None);
    defer c.ImGui_End();

    c.ImGui_PopStyleColor();
    c.ImGui_PopStyleVarEx(2);

    if (c.ImGui_BeginTabBar("video_preview_tabs", c.ImGuiTabBarFlags_None)) {
        defer c.ImGui_EndTabBar();

        // ----------------------------------------------------------------------------
        // Capture preview tab.
        // ----------------------------------------------------------------------------

        const capture_active = state.capture.recording_to_disk or state.capture.replay_buffer_active;
        const capture_tab_selected = if (capture_active)
            imgui_util.begin_tab_item_with_colored_icon(
                "Capture",
                "󰑊",
                Colors.red.as_vec4(),
                null,
                c.ImGuiTabItemFlags_None,
            )
        else
            c.ImGui_BeginTabItem("Capture", null, c.ImGuiTabItemFlags_None);

        // When the tab is clicked.
        if (c.ImGui_IsItemActivated()) {
            store.dispatch(.{ .video_editor = .clear_active_session });
        }

        if (capture_tab_selected) {
            active_tab = .capture;
            defer c.ImGui_EndTabItem();

            _ = c.ImGui_BeginChild(
                "capture_tab_preview_content",
                .{ .x = 0, .y = 0 },
                c.ImGuiChildFlags_None,
                c.ImGuiWindowFlags_None,
            );
            defer c.ImGui_EndChild();

            const capture_preview_args: CapturePreviewArgs = blk: {
                if (!state.capture.is_video_capture_supported) {
                    break :blk .capture_not_supported;
                } else if (state.capture.video_capture_active) {
                    const capture_preview_ring_buffer_locked = capture_preview_ring_buffer.lock();
                    defer capture_preview_ring_buffer_locked.unlock();
                    if (capture_preview_ring_buffer_locked.unwrap()) |_capture_preview_ring_buffer| {
                        if (try _capture_preview_ring_buffer.get_latest_display_frame()) |display_frame| {
                            display_frame_buffer = display_frame.buffer;
                            break :blk .{ .display_frame = display_frame };
                        }
                    }
                }
                break :blk .empty;
            };

            try draw_capture_preview(store, capture_preview_args);
        }

        // ----------------------------------------------------------------------------
        // Video editor session tabs.
        // ----------------------------------------------------------------------------
        var session_iterator = state.video_editor.sessions.iterator();
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

            const is_active = state.video_editor.active_session_id == session_id;

            // When the tab generation ID does not match, it means that the active
            // tab needs to be selected.
            const new_tab_to_select = state.video_editor.active_session_id != null and
                state.video_editor.tab_selection_generation_id != previous_tab_selection_generation_id;

            const player_flags = if (new_tab_to_select and is_active)
                c.ImGuiTabItemFlags_SetSelected
            else
                c.ImGuiTabItemFlags_None;

            // This will be set to false only when the tab closes.
            var tab_open = true;
            const tab_selected = c.ImGui_BeginTabItem(tab_label.ptr, &tab_open, player_flags);
            if (tab_open and c.ImGui_IsItemActivated()) {
                store.dispatch(.{ .video_editor = .{ .set_active_session = session_id } });
            }
            if (tab_selected) {
                active_tab = .{ .editor = session_id };
                defer c.ImGui_EndTabItem();

                _ = c.ImGui_BeginChild(
                    "video_editor_display_frame",
                    .{ .x = 0, .y = 0 },
                    c.ImGuiChildFlags_None,
                    c.ImGuiWindowFlags_None,
                );
                defer c.ImGui_EndChild();

                if (display_frame_buffer == null) {
                    const display_frame: ?VulkanImageRingBuffer.DisplayFrame = blk: {
                        if (try entry.value_ptr.as_ptr().ring_buffer.get_latest_display_frame()) |display_frame| {
                            display_frame_buffer = display_frame.buffer;
                            break :blk display_frame;
                        }
                        break :blk null;
                    };
                    if (display_frame) |_display_frame| {
                        draw_display_frame(_display_frame);
                    }
                }
            }

            // Executes once when the tab is closed.
            if (!tab_open) {
                store.dispatch(.{ .video_editor = .{ .close_session = session_id } });
            }
        }

        previous_tab_selection_generation_id = state.video_editor.tab_selection_generation_id;
    }

    return .{
        .display_frame_buffer = display_frame_buffer,
        .active_tab = active_tab,
    };
}

fn draw_capture_preview(store: *Store, display_frame: CapturePreviewArgs) !void {
    const container_size = c.ImGui_GetContentRegionAvail();
    const container_width = container_size.x;
    const container_height = container_size.y;

    switch (display_frame) {
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
        .display_frame => |_display_frame| {
            draw_display_frame(_display_frame);
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

fn draw_display_frame(display_frame: VulkanImageRingBuffer.DisplayFrame) void {
    const container_size = c.ImGui_GetContentRegionAvail();
    const image_width: f32 = @floatFromInt(display_frame.width);
    const image_height: f32 = @floatFromInt(display_frame.height);
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
    c.ImGui_Image(display_frame.texture, .{ .x = render_width, .y = render_height });
}
