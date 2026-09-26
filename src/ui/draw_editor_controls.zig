const std = @import("std");
const c = @import("imguiz").imguiz;
const imgui_util = @import("./imgui_util.zig");
const Store = @import("../store/store.zig").Store;
const UIStorage = @import("./ui_storage.zig").UIStorage;
const VideoEditorSession = @import("../store/video_editor_session.zig").VideoEditorSession;
const SessionId = VideoEditorSession.SessionId;

const trim_handle_width: f32 = 12;
const playhead_width: f32 = 8;
const playhead_half_width: f32 = playhead_width / 2;
const handle_radius: f32 = 2;

pub fn draw_editor_controls(
    ui_storage: *UIStorage,
    store: *Store,
    state: *Store.State,
    session_id: SessionId,
) void {
    const session_ref = state.video_editor.sessions.get(session_id) orelse return;
    const session = session_ref.as_ptr();
    if (ui_storage.editor_drag) |drag| {
        if (drag.session_id != session_id) {
            ui_storage.clear_editor_drag();
        }
    }

    c.ImGui_BeginDisabled(session.duration_ns <= 0);
    defer c.ImGui_EndDisabled();

    draw_timeline(ui_storage, store, session, session_id);
    c.ImGui_Spacing();

    const button_width: f32 = 64;
    const button_height: f32 = 36;
    const row_start_x = c.ImGui_GetCursorPosX();
    const row_width = c.ImGui_GetContentRegionAvail().x;
    const item_spacing_x = c.ImGui_GetStyle().*.ItemSpacing.x;
    const controls_width = button_width * 3 + item_spacing_x * 2;
    const save_button_width: f32 = 92;
    const controls_x = row_start_x + @max(0, @min(
        (row_width - controls_width) / 2,
        row_width - controls_width - save_button_width - item_spacing_x,
    ));

    c.ImGui_SetCursorPosX(controls_x);

    if (c.ImGui_ButtonEx("<", .{ .x = button_width, .y = button_height })) {
        store.dispatch(.{
            .video_editor = .{ .step_previous_frame = .{ .session_id = session_id } },
        });
    }
    imgui_util.item_tooltip("Previous frame");

    c.ImGui_SameLine();
    if (c.ImGui_ButtonEx(if (session.is_playing()) "" else "", .{ .x = button_width, .y = button_height })) {
        store.dispatch(.{
            .video_editor = .{
                .set_playing = .{
                    .session_id = session_id,
                    .playing = !session.is_playing(),
                },
            },
        });
    }

    c.ImGui_SameLine();
    if (c.ImGui_ButtonEx(">", .{ .x = button_width, .y = button_height })) {
        store.dispatch(.{
            .video_editor = .{ .step_next_frame = .{ .session_id = session_id } },
        });
    }
    imgui_util.item_tooltip("Next frame");

    c.ImGui_SameLine();
    c.ImGui_SetCursorPosX(@max(c.ImGui_GetCursorPosX(), row_start_x + row_width - save_button_width));
    if (c.ImGui_ButtonEx("󰆓 Save", .{ .x = save_button_width, .y = button_height })) {
        store.dispatch(.{ .video_editor = .{ .export_trimmed_video = .{
            .session_id = session_id,
            .trim_start_ns = session.trim_start_ns(),
            .trim_end_ns = session.trim_end_ns(),
        } } });
    }
    imgui_util.item_tooltip("Saving creates a copy of the video and does not overwrite the original.");
}

/// Draw a custom slider widget with trim handles at the beginning/end.
fn draw_timeline(
    ui_storage: *UIStorage,
    store: *Store,
    session: *const VideoEditorSession,
    session_id: SessionId,
) void {
    const duration_ns = session.duration_ns;
    const trim_start_ns = session.trim_start_ns();
    const trim_end_ns = session.trim_end_ns();
    const playback_position_ns = session.playback_position_ns();

    const size = c.ImVec2{
        .x = c.ImGui_GetContentRegionAvail().x,
        .y = @max(c.ImGui_GetFrameHeight(), 32),
    };
    _ = c.ImGui_InvisibleButton(
        "##editor_timeline",
        size,
        c.ImGuiButtonFlags_MouseButtonLeft,
    );

    const rect_min = c.ImGui_GetItemRectMin();
    const rect_max = c.ImGui_GetItemRectMax();
    const timeline_min_x = rect_min.x + trim_handle_width + playhead_half_width;
    const timeline_max_x = rect_max.x - trim_handle_width - playhead_half_width;
    const mouse_position = c.ImGui_GetMousePos();
    const mouse_x = mouse_position.x;

    if (c.ImGui_IsItemActivated()) {
        ui_storage.clear_editor_drag();
        const target = pick_drag_target(
            mouse_x,
            mouse_position.y,
            rect_min.x,
            rect_min.y,
            rect_max.x,
            rect_max.y,
            timeline_min_x,
            timeline_max_x,
            duration_ns,
            trim_start_ns,
            trim_end_ns,
        );
        const handle_position_ns = switch (target) {
            .trim_start => trim_start_ns,
            .trim_end => trim_end_ns,
            .playhead => null,
        };
        ui_storage.editor_drag = .{
            .session_id = session_id,
            .target = target,
            .mouse_offset_x = if (handle_position_ns) |position_ns|
                mouse_x - position_x(timeline_min_x, timeline_max_x, duration_ns, position_ns)
            else
                0,
        };

        dispatch_set_scrubbing(store, session_id, true);
    }

    if (ui_storage.editor_drag) |drag| {
        if (c.ImGui_IsItemActive() or c.ImGui_IsItemDeactivated()) {
            const position_ns = drag_position_ns(
                drag.target,
                mouse_x - drag.mouse_offset_x,
                timeline_min_x,
                timeline_max_x,
                duration_ns,
                trim_start_ns,
                trim_end_ns,
            );
            if (drag.last_position_ns == null or drag.last_position_ns.? != position_ns) {
                dispatch_drag_position(store, session_id, drag.target, position_ns);
                ui_storage.editor_drag.?.last_position_ns = position_ns;
            }

            if (c.ImGui_IsItemDeactivated()) {
                dispatch_set_scrubbing(store, session_id, false);
                ui_storage.clear_editor_drag();
            }
        }
    }

    draw_timeline_track(
        rect_min,
        rect_max,
        timeline_min_x,
        timeline_max_x,
        duration_ns,
        trim_start_ns,
        playback_position_ns,
        trim_end_ns,
    );
}

fn pick_drag_target(
    mouse_x: f32,
    mouse_y: f32,
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    timeline_min_x: f32,
    timeline_max_x: f32,
    duration_ns: i64,
    trim_start_ns: i64,
    trim_end_ns: i64,
) UIStorage.EditorDragTarget {
    const trim_start_x = position_x(timeline_min_x, timeline_max_x, duration_ns, trim_start_ns);
    const trim_end_x = position_x(timeline_min_x, timeline_max_x, duration_ns, trim_end_ns);

    if (mouse_y >= min_y and mouse_y <= max_y and mouse_x >= min_x and mouse_x <= max_x) {
        if (mouse_x >= trim_start_x - playhead_half_width - trim_handle_width and
            mouse_x <= trim_start_x - playhead_half_width)
        {
            return .trim_start;
        }
        if (mouse_x >= trim_end_x + playhead_half_width and
            mouse_x <= trim_end_x + playhead_half_width + trim_handle_width)
        {
            return .trim_end;
        }
    }
    return .playhead;
}

fn drag_position_ns(
    target: UIStorage.EditorDragTarget,
    mouse_x: f32,
    min_x: f32,
    max_x: f32,
    duration_ns: i64,
    trim_start_ns: i64,
    trim_end_ns: i64,
) i64 {
    const width = @max(max_x - min_x, 1);
    const fraction = std.math.clamp((mouse_x - min_x) / width, 0, 1);
    const position_ns: i64 = @intFromFloat(
        @as(f64, @floatCast(fraction)) * @as(f64, @floatFromInt(duration_ns)),
    );
    return switch (target) {
        .trim_start => std.math.clamp(position_ns, 0, trim_end_ns),
        .playhead => std.math.clamp(position_ns, trim_start_ns, trim_end_ns),
        .trim_end => std.math.clamp(position_ns, trim_start_ns, duration_ns),
    };
}

fn dispatch_drag_position(
    store: *Store,
    session_id: SessionId,
    target: UIStorage.EditorDragTarget,
    position_ns: i64,
) void {
    switch (target) {
        .trim_start => store.dispatch(.{
            .video_editor = .{ .set_trim_start = .{
                .session_id = session_id,
                .position_ns = position_ns,
            } },
        }),
        .trim_end => store.dispatch(.{
            .video_editor = .{ .set_trim_end = .{
                .session_id = session_id,
                .position_ns = position_ns,
            } },
        }),
        .playhead => store.dispatch(.{
            .video_editor = .{ .scrub = .{
                .session_id = session_id,
                .position_ns = position_ns,
            } },
        }),
    }
}

fn dispatch_set_scrubbing(
    store: *Store,
    session_id: SessionId,
    scrubbing: bool,
) void {
    store.dispatch(.{
        .video_editor = .{ .set_scrubbing = .{
            .session_id = session_id,
            .scrubbing = scrubbing,
        } },
    });
}

fn draw_timeline_track(
    rect_min: c.ImVec2,
    rect_max: c.ImVec2,
    timeline_min_x: f32,
    timeline_max_x: f32,
    duration_ns: i64,
    trim_start_ns: i64,
    playback_position_ns: i64,
    trim_end_ns: i64,
) void {
    const draw_list = c.ImGui_GetWindowDrawList();
    const center_y = (rect_min.y + rect_max.y) / 2;
    const track_min = c.ImVec2{ .x = timeline_min_x - playhead_half_width, .y = center_y - 3 };
    const track_max = c.ImVec2{ .x = timeline_max_x + playhead_half_width, .y = center_y + 3 };
    const trim_start_x = position_x(timeline_min_x, timeline_max_x, duration_ns, trim_start_ns);
    const playhead_x = position_x(timeline_min_x, timeline_max_x, duration_ns, playback_position_ns);
    const trim_end_x = position_x(timeline_min_x, timeline_max_x, duration_ns, trim_end_ns);

    c.ImDrawList_AddRectFilled(
        draw_list,
        track_min,
        track_max,
        c.ImGui_GetColorU32(c.ImGuiCol_FrameBg),
    );
    c.ImDrawList_AddRectFilled(
        draw_list,
        .{ .x = trim_start_x - playhead_half_width, .y = track_min.y },
        .{ .x = trim_end_x + playhead_half_width, .y = track_max.y },
        c.ImGui_GetColorU32(c.ImGuiCol_SliderGrab),
    );

    const trim_color = c.ImGui_GetColorU32(c.ImGuiCol_Text);
    c.ImDrawList_AddRectFilledEx(
        draw_list,
        .{ .x = trim_start_x - playhead_half_width - trim_handle_width, .y = rect_min.y },
        .{ .x = trim_start_x - playhead_half_width, .y = rect_max.y },
        trim_color,
        handle_radius,
        0,
    );
    c.ImDrawList_AddRectFilledEx(
        draw_list,
        .{ .x = trim_end_x + playhead_half_width, .y = rect_min.y },
        .{ .x = trim_end_x + playhead_half_width + trim_handle_width, .y = rect_max.y },
        trim_color,
        handle_radius,
        0,
    );

    c.ImDrawList_AddRectFilledEx(
        draw_list,
        .{ .x = playhead_x - playhead_half_width, .y = rect_min.y },
        .{ .x = playhead_x + playhead_half_width, .y = rect_max.y },
        c.ImGui_GetColorU32(c.ImGuiCol_SliderGrabActive),
        handle_radius,
        0,
    );
}

fn position_x(min_x: f32, max_x: f32, duration_ns: i64, position_ns: i64) f32 {
    if (duration_ns <= 0) return min_x;
    const fraction: f32 = @floatCast(
        @as(f64, @floatFromInt(std.math.clamp(position_ns, 0, duration_ns))) /
            @as(f64, @floatFromInt(duration_ns)),
    );
    return min_x + ((max_x - min_x) * fraction);
}
