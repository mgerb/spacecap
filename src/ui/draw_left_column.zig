const std = @import("std");
const c = @import("imguiz").imguiz;
const StateActor = @import("../state_actor.zig").StateActor;
const AudioDeviceType = @import("../capture/audio/audio_capture.zig").AudioDeviceType;
const AUDIO_GAIN_MIN = @import("../state/audio_state.zig").AUDIO_GAIN_MIN;
const AUDIO_GAIN_MAX = @import("../state/audio_state.zig").AUDIO_GAIN_MAX;
const imgui_util = @import("./imgui_util.zig");

pub const COLUMN_WIDTH = 280;
const CONTROL_HEIGHT: f32 = 30;
const GROUP_SPACING: f32 = 6;
const GAIN_LABEL_WIDTH: f32 = 36.0;
const CAPTURE_FPS_MIN: c_int = 1;
const CAPTURE_FPS_MAX: c_int = 240;

/// This is bound to a drag input. We keep a locally bound value
/// because we only want to update the global state when not dragging.
var capture_fps_local: ?i32 = null;

fn deviceTypeLabel(device_type: AudioDeviceType) []const u8 {
    return switch (device_type) {
        .source => "Source",
        .sink => "Sink",
    };
}

fn drawAudioDeviceSelector(allocator: std.mem.Allocator, state_actor: *StateActor) !void {
    var selected_count: usize = 0;
    var first_selected_name: ?[]const u8 = null;
    for (state_actor.state.audio.devices.items) |device| {
        if (!device.selected) continue;
        selected_count += 1;
        if (first_selected_name == null) {
            first_selected_name = device.name;
        }
    }

    var preview_buffer: ?[:0]u8 = null;
    defer if (preview_buffer) |value| allocator.free(value);

    const preview_text: [:0]const u8 = blk: {
        if (selected_count == 0) break :blk "None";
        if (selected_count == 1) {
            preview_buffer = try std.fmt.allocPrintSentinel(allocator, "{s}", .{first_selected_name.?}, 0);
            break :blk preview_buffer.?;
        }
        preview_buffer = try std.fmt.allocPrintSentinel(allocator, "{d} selected", .{selected_count}, 0);
        break :blk preview_buffer.?;
    };

    c.ImGui_Text("Audio Sources");
    c.ImGui_SetNextItemWidth(c.ImGui_GetContentRegionAvail().x);

    if (c.ImGui_BeginCombo("##Audio Sources", preview_text.ptr, 0)) {
        defer c.ImGui_EndCombo();

        if (state_actor.state.audio.devices.items.len == 0) {
            c.ImGui_Text("No audio devices found");
            return;
        }

        for (state_actor.state.audio.devices.items) |device| {
            const item_label = try std.fmt.allocPrintSentinel(allocator, "[{s}] {s}{s}##audio-device-{s}", .{
                deviceTypeLabel(device.device_type),
                device.name,
                if (device.is_default) " (default)" else "",
                device.id,
            }, 0);
            defer allocator.free(item_label);

            var selected = device.selected;
            if (c.ImGui_SelectableBoolPtr(
                item_label,
                &selected,
                c.ImGuiSelectableFlags_DontClosePopups,
            )) {
                const device_id_copy = try allocator.dupe(u8, device.id);
                errdefer allocator.free(device_id_copy);
                try state_actor.dispatch(.{ .audio = .{ .toggle_audio_device = device_id_copy } });
            }
        }
    }
}

fn drawSelectedAudioSourceGainSliders(allocator: std.mem.Allocator, state_actor: *StateActor) !void {
    var selected_total: usize = 0;
    for (state_actor.state.audio.devices.items) |device| {
        if (device.selected) selected_total += 1;
    }

    var rendered_count: usize = 0;
    for (state_actor.state.audio.devices.items) |device| {
        if (!device.selected) continue;
        rendered_count += 1;

        const device_text = try std.fmt.allocPrintSentinel(allocator, "[{s}] {s}{s}", .{
            deviceTypeLabel(device.device_type),
            device.name,
            if (device.is_default) " (default)" else "",
        }, 0);
        defer allocator.free(device_text);
        c.ImGui_PushTextWrapPos(0);
        c.ImGui_TextUnformatted(device_text.ptr);
        c.ImGui_PopTextWrapPos();

        const gain_slider_id = try std.fmt.allocPrintSentinel(allocator, "##audio-gain-{s}", .{
            device.id,
        }, 0);
        defer allocator.free(gain_slider_id);
        const gain_row_table_id = try std.fmt.allocPrintSentinel(allocator, "audio-gain-row-{s}", .{
            device.id,
        }, 0);
        defer allocator.free(gain_row_table_id);

        var gain = std.math.clamp(device.gain, AUDIO_GAIN_MIN, AUDIO_GAIN_MAX);
        if (c.ImGui_BeginTable(gain_row_table_id, 2, c.ImGuiTableFlags_SizingStretchSame)) {
            defer c.ImGui_EndTable();

            c.ImGui_TableSetupColumnEx("gain-label", c.ImGuiTableColumnFlags_WidthFixed, GAIN_LABEL_WIDTH, 0);
            c.ImGui_TableSetupColumnEx("gain-slider", c.ImGuiTableColumnFlags_WidthStretch, 1.0, 0);

            _ = c.ImGui_TableNextColumn();
            c.ImGui_AlignTextToFramePadding();
            c.ImGui_Text("Gain");

            _ = c.ImGui_TableNextColumn();
            c.ImGui_SetNextItemWidth(-std.math.floatMin(f32));
            if (c.ImGui_SliderFloatEx(gain_slider_id, &gain, AUDIO_GAIN_MIN, AUDIO_GAIN_MAX, "%.2fx", 0)) {
                try state_actor.dispatch(.{ .audio = .{
                    .set_audio_device_gain = try .init(allocator, .{
                        .device_id = device.id,
                        .gain = gain,
                    }),
                } });
            }
        }

        if (rendered_count < selected_total) {
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });
            c.ImGui_Separator();
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });
        } else {
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });
        }
    }

    if (selected_total == 0) {
        c.ImGui_TextDisabled("Select at least one audio source to adjust gain.");
    }
}

pub fn drawLeftColumn(allocator: std.mem.Allocator, state_actor: *StateActor) !void {
    // Get viewport size
    const viewport_pos = c.ImGui_GetMainViewport().*.Pos;
    const viewport_size = c.ImGui_GetMainViewport().*.Size;

    // Set position and size for the left panel window
    c.ImGui_SetNextWindowPos(viewport_pos, 0);
    c.ImGui_SetNextWindowSize(c.ImVec2{
        .x = COLUMN_WIDTH,
        .y = viewport_size.y,
    }, 0);

    _ = c.ImGui_Begin("left column", null, c.ImGuiWindowFlags_NoTitleBar |
        c.ImGuiWindowFlags_NoResize |
        c.ImGuiWindowFlags_NoMove |
        c.ImGuiWindowFlags_NoCollapse);
    defer c.ImGui_End();

    // c.ImGui_SeparatorText("Spacecap");

    if (c.ImGui_BeginTabBar("MainTabBar", 0)) {
        defer c.ImGui_EndTabBar();

        if (c.ImGui_BeginTabItem("Capture", null, 0)) {
            defer c.ImGui_EndTabItem();

            const video_capture_supported = state_actor.state.is_video_capture_supprted;
            c.ImGui_SeparatorText("Video");
            if (c.ImGui_BeginTable("source_table", 2, c.ImGuiTableFlags_None)) {
                c.ImGui_BeginDisabled(!video_capture_supported);
                _ = c.ImGui_TableNextColumn();
                if (c.ImGui_ButtonEx("Desktop", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = CONTROL_HEIGHT })) {
                    try state_actor.dispatch(.{ .select_video_source = .desktop });
                }

                _ = c.ImGui_TableNextColumn();
                if (c.ImGui_ButtonEx("Window", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = CONTROL_HEIGHT })) {
                    try state_actor.dispatch(.{ .select_video_source = .window });
                }
                c.ImGui_EndDisabled();
                c.ImGui_EndTable();
            }
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

            c.ImGui_SeparatorText("Audio");
            try drawAudioDeviceSelector(allocator, state_actor);
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });
            try drawSelectedAudioSourceGainSliders(allocator, state_actor);
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });
            c.ImGui_Separator();
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

            if (c.ImGui_BeginTable("button_table", 2, c.ImGuiTableFlags_None)) {
                _ = c.ImGui_TableNextColumn();

                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, c.ImVec4{ .x = 0.251, .y = 0.627, .z = 0.169, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, c.ImVec4{ .x = 0.329, .y = 0.706, .z = 0.247, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, c.ImVec4{ .x = 0.173, .y = 0.471, .z = 0.129, .w = 1.0 });
                c.ImGui_BeginDisabled(!video_capture_supported or state_actor.state.is_recording_video or !state_actor.state.is_capturing_video);
                if (c.ImGui_ButtonEx("Start", .{ .x = -std.math.floatMin(f32), .y = CONTROL_HEIGHT })) {
                    try state_actor.dispatch(.start_record);
                }
                c.ImGui_PopStyleColorEx(3);
                c.ImGui_EndDisabled();

                _ = c.ImGui_TableNextColumn();

                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, c.ImVec4{ .x = 0.6, .y = 0.0, .z = 0.0, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, c.ImVec4{ .x = 0.75, .y = 0.1, .z = 0.1, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, c.ImVec4{ .x = 0.5, .y = 0.0, .z = 0.0, .w = 1.0 });
                c.ImGui_BeginDisabled(!video_capture_supported or !state_actor.state.is_recording_video);
                if (c.ImGui_ButtonEx("Stop", .{ .x = -std.math.floatMin(f32), .y = CONTROL_HEIGHT })) {
                    try state_actor.dispatch(.stop_record);
                }
                c.ImGui_PopStyleColorEx(3);
                c.ImGui_EndDisabled();
                c.ImGui_EndTable();
            }
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

            const save_replay_enabled = video_capture_supported and state_actor.state.is_recording_video;
            if (save_replay_enabled) {
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, c.ImVec4{ .x = 0.447, .y = 0.529, .z = 0.992, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, c.ImVec4{ .x = 0.525, .y = 0.608, .z = 1.000, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, c.ImVec4{ .x = 0.369, .y = 0.451, .z = 0.874, .w = 1.0 });
            } else {
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, c.ImVec4{ .x = 0.22, .y = 0.24, .z = 0.28, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, c.ImVec4{ .x = 0.22, .y = 0.24, .z = 0.28, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, c.ImVec4{ .x = 0.22, .y = 0.24, .z = 0.28, .w = 1.0 });
            }
            c.ImGui_BeginDisabled(!save_replay_enabled);
            if (c.ImGui_ButtonEx("Save Replay", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = CONTROL_HEIGHT })) {
                try state_actor.dispatch(.save_replay);
            }
            c.ImGui_PopStyleColorEx(3);
            c.ImGui_EndDisabled();
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

            const replay_text = try std.fmt.allocPrintSentinel(allocator, "Time: {}s", .{state_actor.state.replay_buffer.seconds}, 0);
            defer allocator.free(replay_text);
            const size_text = try std.fmt.allocPrintSentinel(allocator, "Size: {d:.2}MB", .{state_actor.state.replay_buffer.sizeInMB()}, 0);
            defer allocator.free(size_text);
            c.ImGui_Text(replay_text);
            c.ImGui_Text(size_text);
        }

        if (c.ImGui_BeginTabItem("Settings", null, 0)) {
            defer c.ImGui_EndTabItem();

            try drawCaptureSettings(state_actor);

            c.ImGui_SeparatorText("GUI Settings");

            var fg_fps = @as(f32, @floatFromInt(state_actor.state.user_settings.settings.gui_foreground_fps));
            if (c.ImGui_DragFloatEx("FG FPS", &fg_fps, 1, 1.0, 240.0, "%.0f", 0)) {
                try state_actor.dispatch(.{ .user_settings = .{
                    .set_gui_foreground_fps = @as(u32, @intFromFloat(fg_fps)),
                } });
            }
            c.ImGui_SameLine();
            imgui_util.help_marker("Forground FPS. This is the max frame rate Spacecap will render while focused. Drag or double click to change.");

            var bg_fps = @as(f32, @floatFromInt(state_actor.state.user_settings.settings.gui_background_fps));
            if (c.ImGui_DragFloatEx("BG FPS", &bg_fps, 1, 1.0, 240.0, "%.0f", 0)) {
                try state_actor.dispatch(.{ .user_settings = .{
                    .set_gui_background_fps = @as(u32, @intFromFloat(bg_fps)),
                } });
            }
            c.ImGui_SameLine();
            imgui_util.help_marker("Background FPS. This is the max frame rate Spacecap will render while NOT focused. Drag or double click to change.");

            // NOTE: Hiding this for now. Linux shortcuts can be configured at the
            // desktop environment level. See comments regarding `Method.configure_shortcuts`
            // in `xdg_desktop_portal_global_shortcuts.zig` for more info.
            //
            // TODO: Adjust widths so that they match the above.
            // const help_marker_width = c.ImGui_CalcTextSize("(?)").x;
            // const spacing = c.ImGui_GetStyle().*.ItemSpacing.x;
            // const button_width = @max(0.0, c.ImGui_GetContentRegionAvail().x - help_marker_width - spacing);
            // if (c.ImGui_ButtonEx("Configure Shortcuts", .{ .x = button_width, .y = 0 })) {
            //     try state_actor.dispatch(.open_global_shortcuts);
            // }
            // c.ImGui_SameLineEx(0, spacing);
            // imgui_util.help_marker("This button may not work. Configure shortcuts with your system settings.");

            c.ImGui_SeparatorText("imgui debug");

            if (c.ImGui_ButtonEx("Show Demo", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0 })) {
                try state_actor.dispatch(.show_demo);
            }
            const io = c.ImGui_GetIO();
            c.ImGui_Text("%.3f ms/frame", 1000.0 / io.*.Framerate);
            c.ImGui_Text("%.1f fps", io.*.Framerate);
        }
    }
}

fn drawCaptureSettings(state_actor: *StateActor) !void {
    c.ImGui_SeparatorText("Capture Settings");
    const current_capture_fps: i32 = @intCast(state_actor.state.user_settings.settings.capture_fps);
    var fps = capture_fps_local orelse current_capture_fps;
    if (c.ImGui_DragIntEx("FPS", &fps, 1.0, CAPTURE_FPS_MIN, CAPTURE_FPS_MAX, "%d", c.ImGuiSliderFlags_AlwaysClamp)) {
        capture_fps_local = fps;
    }
    if (c.ImGui_IsItemDeactivatedAfterEdit() and fps > 0 and fps != current_capture_fps) {
        try state_actor.dispatch(.{ .user_settings = .{
            .set_capture_fps = @intCast(fps),
        } });
        capture_fps_local = null;
    } else if (!c.ImGui_IsItemActive()) {
        // Keep the UI synced with state when not actively editing.
        capture_fps_local = null;
    }
    c.ImGui_SameLine();
    imgui_util.help_marker("Capture FPS. Drag or double click to change.");
}
