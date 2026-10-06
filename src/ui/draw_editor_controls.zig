const std = @import("std");
const c = @import("imguiz").imguiz;
const imgui_util = @import("./imgui_util.zig");
const util = @import("../util.zig");
const theme = @import("./theme.zig");
const Store = @import("../store/store.zig").Store;
const UIStorage = @import("./ui_storage.zig").UIStorage;
const VideoEditorSession = @import("../store/video_editor_session.zig").VideoEditorSession;
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

    // ----------------------------------------------------------------------------
    // Draw editor controls
    // ----------------------------------------------------------------------------
    {
        c.ImGui_BeginDisabled(session.duration_ns <= 0);
        defer c.ImGui_EndDisabled();

        Timeline.draw(ui_storage, store, session, session_id);
        c.ImGui_Spacing();

        const button_width: f32 = 64;
        const button_height: f32 = 36;
        const trim_start_ns = session.trim_start_ns();
        const trim_duration_ns = if (session.duration_ns > 0)
            @max(0, session.trim_end_ns() - trim_start_ns)
        else
            0;
        const elapsed_ns = session.playback_position_ns() - trim_start_ns;
        const play_time_label = imgui_util.format_play_time(elapsed_ns, trim_duration_ns);

        // ----------------------------------------------------------------------------
        // Draw timestamp
        // ----------------------------------------------------------------------------
        const row_start_x = c.ImGui_GetCursorPosX();
        const row_width = c.ImGui_GetContentRegionAvail().x;
        c.ImGui_SetCursorPosX(row_start_x + Timeline.trim_handle_width);
        c.ImGui_TextUnformatted(&play_time_label);
        c.ImGui_SameLine();

        // ----------------------------------------------------------------------------
        // Draw controls - play, pause, etc.
        // Set the cursor position because these will be centered.
        // ----------------------------------------------------------------------------
        const item_spacing_x = c.ImGui_GetStyle().*.ItemSpacing.x;
        const controls_width = button_width * 3 + item_spacing_x * 2;
        const play_time_size = c.ImGui_CalcTextSize(&play_time_label);
        const controls_x = row_start_x + @max(
            Timeline.trim_handle_width + play_time_size.x + item_spacing_x,
            (row_width - controls_width) / 2,
        );
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
    }

    // ----------------------------------------------------------------------------
    // Draw export controls
    // ----------------------------------------------------------------------------
    c.ImGui_Spacing();
    if (c.ImGui_CollapsingHeader("Export", c.ImGuiTreeNodeFlags_DefaultOpen)) {
        draw_export_controls(store, session);
    }

    // ----------------------------------------------------------------------------
    // Draw video details
    // ----------------------------------------------------------------------------
    c.ImGui_Spacing();
    if (c.ImGui_CollapsingHeader("Details", c.ImGuiTreeNodeFlags_DefaultOpen)) {
        draw_video_details(session);
    }
}

fn draw_export_controls(store: *Store, session: *const VideoEditorSession) void {
    const export_width = c.ImGui_GetContentRegionAvail().x;
    const actions_column_width = @max(200, @min(400, export_width - 400));

    if (!c.ImGui_BeginTable("##editor_export", 2, c.ImGuiTableFlags_SizingStretchProp)) {
        return;
    }
    defer c.ImGui_EndTable();

    c.ImGui_TableSetupColumnEx("options", c.ImGuiTableColumnFlags_WidthStretch, 1.0, 0);
    c.ImGui_TableSetupColumnEx("actions", c.ImGuiTableColumnFlags_WidthFixed, actions_column_width, 0);
    c.ImGui_TableNextRow();
    _ = c.ImGui_TableNextColumn();

    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_CellPadding, theme.container_padding);
    defer c.ImGui_PopStyleVar();

    // ----------------------------------------------------------------------------
    // Export options
    // ----------------------------------------------------------------------------
    if (c.ImGui_BeginTable("##editor_export_options", 1, c.ImGuiTableFlags_SizingStretchProp)) {
        defer c.ImGui_EndTable();
        c.ImGui_BeginDisabled(true);
        defer c.ImGui_EndDisabled();
        inline for (.{ .{ "Include audio", true }, .{ "Re-encode", false } }) |option| {
            var checked = option[1];
            _ = c.ImGui_TableNextColumn();
            _ = c.ImGui_Checkbox(option[0], &checked);
            imgui_util.item_tooltip("This export option is not available yet.");
        }
    }

    // ----------------------------------------------------------------------------
    // Export buttons
    // ----------------------------------------------------------------------------
    _ = c.ImGui_TableNextColumn();
    if (c.ImGui_BeginTable("##editor_actions", 1, c.ImGuiTableFlags_SizingStretchProp)) {
        defer c.ImGui_EndTable();

        const action_button_height = theme.action_button_height();
        c.ImGui_BeginDisabled(session.duration_ns <= 0);
        defer c.ImGui_EndDisabled();

        _ = c.ImGui_TableNextColumn();
        if (c.ImGui_ButtonEx("󰆓 Save", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = action_button_height })) {
            store.dispatch(.{ .video_editor = .{ .export_trimmed_video = .{
                .session_id = session.id,
                .trim_start_ns = session.trim_start_ns(),
                .trim_end_ns = session.trim_end_ns(),
            } } });
        }
        imgui_util.item_tooltip("Saving creates a copy of the video and does not overwrite the original.");

        _ = c.ImGui_TableNextColumn();
        c.ImGui_BeginDisabled(true);
        _ = c.ImGui_ButtonEx("󰹑 Screenshot", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = action_button_height });
        c.ImGui_EndDisabled();
        imgui_util.item_tooltip("Not implemented yet");
    }
}

fn draw_video_details(session: *const VideoEditorSession) void {
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_CellPadding, .{
        .x = theme.container_padding.x,
        .y = c.ImGui_GetStyle().*.CellPadding.y,
    });
    defer c.ImGui_PopStyleVar();

    if (!c.ImGui_BeginTable(
        "##editor_metrics",
        2,
        c.ImGuiTableFlags_SizingFixedFit | c.ImGuiTableFlags_RowBg | c.ImGuiTableFlags_PadOuterX,
    )) {
        return;
    }
    defer c.ImGui_EndTable();

    c.ImGui_TableSetupColumnEx("metric", c.ImGuiTableColumnFlags_WidthFixed, 0, 0);
    c.ImGui_TableSetupColumnEx("value", c.ImGuiTableColumnFlags_WidthFixed, 0, 0);

    draw_detail_row("File format");
    c.ImGui_TextUnformatted(session.container_format_name.ptr);

    draw_detail_row("File size");
    if (session.file_size_bytes) |size_bytes| {
        const size_label = util.format_file_size_label(size_bytes);
        c.ImGui_TextUnformatted(&size_label);
    } else {
        c.ImGui_TextDisabled("Unknown");
    }

    draw_detail_row("Resolution");
    c.ImGui_Text("%u × %u", session.width, session.height);

    draw_detail_row("Frame rate");
    if (session.frame_rate) |frame_rate| {
        c.ImGui_Text("%.2f fps", frame_rate);
    } else {
        c.ImGui_TextDisabled("Unknown");
    }

    draw_detail_row("Video codec");
    c.ImGui_TextUnformatted(session.video_codec_name.ptr);

    draw_detail_row("Video bitrate");
    imgui_util.draw_bit_rate(session.video_bit_rate);

    if (session.audio_codec_name) |audio_codec_name| {
        draw_detail_row("Audio codec");
        c.ImGui_TextUnformatted(audio_codec_name.ptr);

        draw_detail_row("Audio bitrate");
        imgui_util.draw_bit_rate(session.audio_bit_rate);

        draw_detail_row("Audio sample rate");
        if (session.audio_sample_rate) |sample_rate| {
            c.ImGui_Text("%g kHz", @as(f64, @floatFromInt(sample_rate)) / 1000);
        } else {
            c.ImGui_TextDisabled("Unknown");
        }
    } else {
        draw_detail_row("Audio");
        c.ImGui_TextDisabled("No audio");
    }
}

fn draw_detail_row(label: [:0]const u8) void {
    c.ImGui_TableNextRow();
    _ = c.ImGui_TableNextColumn();
    c.ImGui_TextDisabled(label.ptr);
    _ = c.ImGui_TableNextColumn();
}

/// Draw a timeline with a scrub handle and two trim handles on each end.
const Timeline = struct {
    const trim_handle_width: f32 = 12;
    const playhead_width: f32 = 8;
    const playhead_half_width: f32 = playhead_width / 2;
    const handle_radius: f32 = 2;

    /// Draw a custom slider widget with trim handles at the beginning/end.
    fn draw(
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

        draw_track(
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

    fn draw_track(
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
        if (duration_ns <= 0) {
            return min_x;
        }
        const fraction: f32 = @floatCast(
            @as(f64, @floatFromInt(std.math.clamp(position_ns, 0, duration_ns))) /
                @as(f64, @floatFromInt(duration_ns)),
        );
        return min_x + ((max_x - min_x) * fraction);
    }
};
