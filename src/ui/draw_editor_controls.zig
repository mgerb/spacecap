const std = @import("std");
const c = @import("imguiz").imguiz;
const Store = @import("../store/store.zig").Store;
const UIStorage = @import("./ui_storage.zig").UIStorage;
const VideoEditorSession = @import("../video/video_editor_session.zig").VideoEditorSession;
const SessionId = VideoEditorSession.SessionId;

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

    if (c.ImGui_Button(if (session.is_playing()) "" else "")) {
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
    draw_timeline(ui_storage, store, session, session_id);

    if (c.ImGui_Button("<")) {
        store.dispatch(.{
            .video_editor = .{ .step_previous_frame = .{ .session_id = session_id } },
        });
    }

    c.ImGui_SameLine();
    if (c.ImGui_Button(">")) {
        store.dispatch(.{
            .video_editor = .{ .step_next_frame = .{ .session_id = session_id } },
        });
    }
}

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
        .y = c.ImGui_GetFrameHeight(),
    };
    _ = c.ImGui_InvisibleButton(
        "##editor_timeline",
        size,
        c.ImGuiButtonFlags_MouseButtonLeft,
    );

    const rect_min = c.ImGui_GetItemRectMin();
    const rect_max = c.ImGui_GetItemRectMax();
    const mouse_position = c.ImGui_GetMousePos();
    const mouse_x = mouse_position.x;

    if (c.ImGui_IsItemActivated()) {
        ui_storage.clear_editor_drag();
        ui_storage.editor_drag = .{
            .session_id = session_id,
            .target = pick_drag_target(
                mouse_x,
                mouse_position.y,
                rect_min.x,
                rect_min.y,
                rect_max.x,
                rect_max.y,
                duration_ns,
                trim_start_ns,
                playback_position_ns,
                trim_end_ns,
            ),
        };

        dispatch_set_scrubbing(store, session_id, true);
    }

    const active_drag = if (ui_storage.editor_drag) |drag|
        if (drag.session_id == session_id) drag else null
    else
        null;
    if (active_drag) |drag| {
        if (c.ImGui_IsItemActive() or c.ImGui_IsItemDeactivated()) {
            const position_ns = drag_position_ns(
                drag.target,
                mouse_x,
                rect_min.x,
                rect_max.x,
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
    duration_ns: i64,
    trim_start_ns: i64,
    playback_position_ns: i64,
    trim_end_ns: i64,
) UIStorage.EditorDragTarget {
    const trim_start_x = position_x(min_x, max_x, duration_ns, trim_start_ns);
    const playhead_x = position_x(min_x, max_x, duration_ns, playback_position_ns);
    const trim_end_x = position_x(min_x, max_x, duration_ns, trim_end_ns);
    const handle_pick_radius: f32 = 10;
    const playhead_pick_radius: f32 = 7;

    const center_y = (min_y + max_y) / 2;
    if (@abs(mouse_x - playhead_x) <= handle_pick_radius and
        @abs(mouse_y - center_y) <= playhead_pick_radius)
    {
        return .playhead;
    }

    const start_distance = @abs(mouse_x - trim_start_x);
    const end_distance = @abs(mouse_x - trim_end_x);
    if (@min(start_distance, end_distance) <= handle_pick_radius) {
        return if (start_distance <= end_distance) .trim_start else .trim_end;
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
    duration_ns: i64,
    trim_start_ns: i64,
    playback_position_ns: i64,
    trim_end_ns: i64,
) void {
    const draw_list = c.ImGui_GetWindowDrawList();
    const center_y = (rect_min.y + rect_max.y) / 2;
    const track_min = c.ImVec2{ .x = rect_min.x, .y = center_y - 3 };
    const track_max = c.ImVec2{ .x = rect_max.x, .y = center_y + 3 };
    const trim_start_x = position_x(rect_min.x, rect_max.x, duration_ns, trim_start_ns);
    const playhead_x = position_x(rect_min.x, rect_max.x, duration_ns, playback_position_ns);
    const trim_end_x = position_x(rect_min.x, rect_max.x, duration_ns, trim_end_ns);

    c.ImDrawList_AddRectFilled(
        draw_list,
        track_min,
        track_max,
        c.ImGui_GetColorU32(c.ImGuiCol_FrameBg),
    );
    c.ImDrawList_AddRectFilled(
        draw_list,
        .{ .x = trim_start_x, .y = track_min.y },
        .{ .x = trim_end_x, .y = track_max.y },
        c.ImGui_GetColorU32(c.ImGuiCol_SliderGrab),
    );

    const trim_color = c.ImGui_GetColorU32(c.ImGuiCol_Text);
    c.ImDrawList_AddRectFilled(
        draw_list,
        .{ .x = trim_start_x - 3, .y = rect_min.y },
        .{ .x = trim_start_x + 3, .y = rect_max.y },
        trim_color,
    );
    c.ImDrawList_AddRectFilled(
        draw_list,
        .{ .x = trim_end_x - 3, .y = rect_min.y },
        .{ .x = trim_end_x + 3, .y = rect_max.y },
        trim_color,
    );

    const playhead_color = c.ImGui_GetColorU32(c.ImGuiCol_SliderGrabActive);
    c.ImDrawList_AddLineEx(
        draw_list,
        .{ .x = playhead_x, .y = rect_min.y },
        .{ .x = playhead_x, .y = rect_max.y },
        playhead_color,
        2,
    );
    c.ImDrawList_AddCircleFilled(
        draw_list,
        .{ .x = playhead_x, .y = center_y },
        5,
        playhead_color,
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
