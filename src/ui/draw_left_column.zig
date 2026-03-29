const std = @import("std");
const c = @import("imguiz").imguiz;
const Actor = @import("../state/actor.zig").Actor;
const AudioDeviceType = @import("../capture/audio/audio_capture.zig").AudioDeviceType;
const AUDIO_GAIN_MIN = @import("../state/audio_state.zig").AUDIO_GAIN_MIN;
const AUDIO_GAIN_MAX = @import("../state/audio_state.zig").AUDIO_GAIN_MAX;
const imgui_util = @import("./imgui_util.zig");
const util = @import("../util.zig");

pub const COLUMN_WIDTH = 380;
const CONTROL_HEIGHT: f32 = 30;
const GROUP_SPACING: f32 = 6;
const GAIN_LABEL_WIDTH: f32 = 36.0;
const CAPTURE_FPS_MIN: c_int = 1;
const CAPTURE_FPS_MAX: c_int = 500;
const GUI_FPS_MIN: i32 = 1;
const GUI_FPS_MAX: i32 = 240;
const CAPTURE_BIT_RATE_BPS_PER_KBPS: u64 = 1_000;
const CAPTURE_BIT_RATE_KBPS_MIN: i32 = 100;
const CAPTURE_BIT_RATE_KBPS_MAX: i32 = 1_000_000;
const REPLAY_SECONDS_MIN: i32 = 1;
const REPLAY_SECONDS_MAX: i32 = 60 * 60 * 24;

/// This is bound to a drag input. We keep a locally bound value
/// because we only want to update the global state when not dragging.
var capture_fps_local: ?i32 = null;
var capture_bit_rate_local: ?i32 = null;
var replay_seconds_local: ?i32 = null;
var fg_fps_local: ?i32 = null;
var bg_fps_local: ?i32 = null;

fn device_type_label(device_type: AudioDeviceType) []const u8 {
    return switch (device_type) {
        .source => "Source",
        .sink => "Sink",
    };
}

fn draw_audio_device_selector(allocator: std.mem.Allocator, actor: *Actor) !void {
    var selected_count: usize = 0;
    var first_selected_name: ?[]const u8 = null;
    for (actor.state.audio.devices.items) |device| {
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

        if (actor.state.audio.devices.items.len == 0) {
            c.ImGui_Text("No audio devices found");
            return;
        }

        for (actor.state.audio.devices.items) |device| {
            const item_label = try std.fmt.allocPrintSentinel(allocator, "[{s}] {s}{s}##audio-device-{s}", .{
                device_type_label(device.device_type),
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
                try actor.dispatch(.{ .audio = .{ .toggle_audio_device = device_id_copy } });
            }
        }
    }
}

fn draw_selected_audio_source_gain_sliders(allocator: std.mem.Allocator, actor: *Actor) !void {
    var selected_total: usize = 0;
    for (actor.state.audio.devices.items) |device| {
        if (device.selected) selected_total += 1;
    }

    var rendered_count: usize = 0;
    for (actor.state.audio.devices.items) |device| {
        if (!device.selected) continue;
        rendered_count += 1;

        const device_text = try std.fmt.allocPrintSentinel(allocator, "[{s}] {s}{s}", .{
            device_type_label(device.device_type),
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
                try actor.dispatch(.{ .audio = .{
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
        c.ImGui_PushTextWrapPos(0);
        c.ImGui_TextDisabled("Select at least one audio source to adjust gain.");
        c.ImGui_PopTextWrapPos();
    }
}

pub fn draw_left_column(allocator: std.mem.Allocator, actor: *Actor) !void {
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

            const video_capture_supported = actor.state.is_video_capture_supprted;
            c.ImGui_SeparatorText("Video");
            if (c.ImGui_BeginTable("source_table", 2, c.ImGuiTableFlags_None)) {
                c.ImGui_BeginDisabled(!video_capture_supported);
                _ = c.ImGui_TableNextColumn();
                if (c.ImGui_ButtonEx("Desktop", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = CONTROL_HEIGHT })) {
                    try actor.dispatch(.{ .select_video_source = .desktop });
                }

                _ = c.ImGui_TableNextColumn();
                if (c.ImGui_ButtonEx("Window", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = CONTROL_HEIGHT })) {
                    try actor.dispatch(.{ .select_video_source = .window });
                }
                c.ImGui_EndDisabled();
                c.ImGui_EndTable();
            }
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

            c.ImGui_SeparatorText("Audio");
            try draw_audio_device_selector(allocator, actor);
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });
            try draw_selected_audio_source_gain_sliders(allocator, actor);
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });
            c.ImGui_Separator();
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

            if (c.ImGui_BeginTable("button_table", 2, c.ImGuiTableFlags_None)) {
                _ = c.ImGui_TableNextColumn();

                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, c.ImVec4{ .x = 0.251, .y = 0.627, .z = 0.169, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, c.ImVec4{ .x = 0.329, .y = 0.706, .z = 0.247, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, c.ImVec4{ .x = 0.173, .y = 0.471, .z = 0.129, .w = 1.0 });
                c.ImGui_BeginDisabled(!video_capture_supported or actor.state.is_recording_video or !actor.state.is_capturing_video);
                if (c.ImGui_ButtonEx("Start", .{ .x = -std.math.floatMin(f32), .y = CONTROL_HEIGHT })) {
                    try actor.dispatch(.start_record);
                }
                c.ImGui_PopStyleColorEx(3);
                c.ImGui_EndDisabled();

                _ = c.ImGui_TableNextColumn();

                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, c.ImVec4{ .x = 0.6, .y = 0.0, .z = 0.0, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, c.ImVec4{ .x = 0.75, .y = 0.1, .z = 0.1, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, c.ImVec4{ .x = 0.5, .y = 0.0, .z = 0.0, .w = 1.0 });
                c.ImGui_BeginDisabled(!video_capture_supported or !actor.state.is_recording_video);
                if (c.ImGui_ButtonEx("Stop", .{ .x = -std.math.floatMin(f32), .y = CONTROL_HEIGHT })) {
                    try actor.dispatch(.stop_record);
                }
                c.ImGui_PopStyleColorEx(3);
                c.ImGui_EndDisabled();
                c.ImGui_EndTable();
            }
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

            const save_replay_enabled = video_capture_supported and actor.state.is_recording_video;
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
                try actor.dispatch(.save_replay);
            }
            c.ImGui_PopStyleColorEx(3);
            c.ImGui_EndDisabled();
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

            const replay_text = try std.fmt.allocPrintSentinel(allocator, "Time: {}s", .{actor.state.replay_buffer.seconds}, 0);
            defer allocator.free(replay_text);
            const size_text = try std.fmt.allocPrintSentinel(allocator, "Size: {d:.2}MB", .{actor.state.replay_buffer.size_in_mb()}, 0);
            defer allocator.free(size_text);
            c.ImGui_Text(replay_text);
            c.ImGui_Text(size_text);
        }

        if (c.ImGui_BeginTabItem("Settings", null, 0)) {
            defer c.ImGui_EndTabItem();

            try draw_capture_settings(allocator, actor);

            c.ImGui_SeparatorText("GUI Settings");

            c.ImGui_Text("FG FPS");
            c.ImGui_SameLine();
            imgui_util.help_marker("Forground FPS. This is the max frame rate Spacecap will render while focused. Drag or double click to change.");
            c.ImGui_SetNextItemWidth(-std.math.floatMin(f32));
            const current_fg_fps: i32 = @intCast(actor.state.user_settings.settings.gui_foreground_fps);
            var fg_fps = fg_fps_local orelse current_fg_fps;
            if (c.ImGui_InputIntEx(
                "##fg_fps",
                &fg_fps,
                5,
                10,
                c.ImGuiInputTextFlags_None,
            )) {
                fg_fps = std.math.clamp(fg_fps, GUI_FPS_MIN, GUI_FPS_MAX);
                fg_fps_local = fg_fps;
            }
            if (c.ImGui_IsItemDeactivatedAfterEdit() and fg_fps != current_fg_fps) {
                try actor.dispatch(.{ .user_settings = .{
                    .set_gui_foreground_fps = @intCast(fg_fps),
                } });
                fg_fps_local = null;
            } else if (!c.ImGui_IsItemActive()) {
                // Keep the UI synced with state when not actively editing.
                fg_fps_local = null;
            }

            c.ImGui_Text("BG FPS");
            c.ImGui_SameLine();
            imgui_util.help_marker("Background FPS. This is the max frame rate Spacecap will render while NOT focused. Drag or double click to change.");
            c.ImGui_SetNextItemWidth(-std.math.floatMin(f32));
            const current_bg_fps: i32 = @intCast(actor.state.user_settings.settings.gui_background_fps);
            var bg_fps = bg_fps_local orelse current_bg_fps;
            if (c.ImGui_InputIntEx(
                "##bg_fps",
                &bg_fps,
                5,
                10,
                c.ImGuiInputTextFlags_None,
            )) {
                bg_fps = std.math.clamp(bg_fps, GUI_FPS_MIN, GUI_FPS_MAX);
                bg_fps_local = bg_fps;
            }
            if (c.ImGui_IsItemDeactivatedAfterEdit() and bg_fps != current_bg_fps) {
                try actor.dispatch(.{ .user_settings = .{
                    .set_gui_background_fps = @intCast(bg_fps),
                } });
                bg_fps_local = null;
            } else if (!c.ImGui_IsItemActive()) {
                // Keep the UI synced with state when not actively editing.
                bg_fps_local = null;
            }

            const io = c.ImGui_GetIO();
            c.ImGui_TextDisabled("%.3f ms/frame", 1000.0 / io.*.Framerate);
            c.ImGui_TextDisabled("%.1f fps", io.*.Framerate);

            // NOTE: Hiding this for now. Linux shortcuts can be configured at the
            // desktop environment level. See comments regarding `Method.configure_shortcuts`
            // in `xdg_desktop_portal_global_shortcuts.zig` for more info.
            //
            // TODO: Adjust widths so that they match the above.
            // const help_marker_width = c.ImGui_CalcTextSize("(?)").x;
            // const spacing = c.ImGui_GetStyle().*.ItemSpacing.x;
            // const button_width = @max(0.0, c.ImGui_GetContentRegionAvail().x - help_marker_width - spacing);
            // if (c.ImGui_ButtonEx("Configure Shortcuts", .{ .x = button_width, .y = 0 })) {
            //     try actor.dispatch(.open_global_shortcuts);
            // }
            // c.ImGui_SameLineEx(0, spacing);
            // imgui_util.help_marker("This button may not work. Configure shortcuts with your system settings.");

            c.ImGui_SeparatorText("IMGUI Debug");

            if (c.ImGui_ButtonEx("Show Demo", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0 })) {
                try actor.dispatch(.show_demo);
            }
        }
    }
}

fn draw_capture_settings(allocator: std.mem.Allocator, actor: *Actor) !void {
    c.ImGui_SeparatorText("Capture Settings");

    // FPS
    {
        const current_capture_fps: i32 = @intCast(actor.state.user_settings.settings.capture_fps);
        var fps = capture_fps_local orelse current_capture_fps;
        c.ImGui_Text("Max FPS");
        c.ImGui_SameLine();
        imgui_util.help_marker("The maximum capture rate (frames per second). If your system can't keep up, it may be slower than the desired FPS.");
        c.ImGui_SetNextItemWidth(-std.math.floatMin(f32));
        if (c.ImGui_InputIntEx(
            "##capture_fps",
            &fps,
            5,
            10,
            c.ImGuiInputTextFlags_None,
        )) {
            fps = std.math.clamp(fps, CAPTURE_FPS_MIN, CAPTURE_FPS_MAX);
            capture_fps_local = fps;
        }
        if (c.ImGui_IsItemDeactivatedAfterEdit() and fps > 0 and fps != current_capture_fps) {
            try actor.dispatch(.{ .user_settings = .{
                .set_capture_fps = @intCast(fps),
            } });
            capture_fps_local = null;
        } else if (!c.ImGui_IsItemActive()) {
            // Keep the UI synced with state when not actively editing.
            capture_fps_local = null;
        }
    }

    // Bitrate
    {
        c.ImGui_Text("Bitrate");
        c.ImGui_SameLine();
        imgui_util.help_marker("Capture bitrate in Kbps");
        c.ImGui_SetNextItemWidth(-std.math.floatMin(f32));
        const current_capture_bit_rate: i32 = @intCast(actor.state.user_settings.settings.capture_bit_rate / CAPTURE_BIT_RATE_BPS_PER_KBPS);
        var capture_bit_rate = capture_bit_rate_local orelse current_capture_bit_rate;
        if (c.ImGui_InputIntEx(
            "##bitrate",
            &capture_bit_rate,
            1_000,
            5_000,
            c.ImGuiInputTextFlags_None,
        )) {
            capture_bit_rate = std.math.clamp(capture_bit_rate, CAPTURE_BIT_RATE_KBPS_MIN, CAPTURE_BIT_RATE_KBPS_MAX);
            capture_bit_rate_local = capture_bit_rate;
        }
        if (c.ImGui_IsItemDeactivatedAfterEdit() and capture_bit_rate != current_capture_bit_rate) {
            try actor.dispatch(.{ .user_settings = .{
                .set_capture_bit_rate = @as(u64, @intCast(capture_bit_rate)) * CAPTURE_BIT_RATE_BPS_PER_KBPS,
            } });
            capture_bit_rate_local = null;
        } else if (!c.ImGui_IsItemActive()) {
            // Keep the UI synced with state when not actively editing.
            capture_bit_rate_local = null;
        }

        if (actor.state.is_recording_video) {
            c.ImGui_PushTextWrapPos(0);
            c.ImGui_TextDisabled(" Recording in progress. Bitrate changes take effect after restarting recording.");
            c.ImGui_PopTextWrapPos();
        }
    }

    // Replay buffer length
    {
        c.ImGui_Text("Replay buffer length");
        c.ImGui_SameLine();
        imgui_util.help_marker("Length of video and audio stored in memory (seconds)");
        c.ImGui_SetNextItemWidth(-std.math.floatMin(f32));
        const current_replay_seconds: i32 = @intCast(actor.state.user_settings.settings.replay_seconds);
        var replay_seconds = replay_seconds_local orelse current_replay_seconds;
        if (c.ImGui_InputIntEx(
            "##replay_buffer_length",
            &replay_seconds,
            5,
            10,
            c.ImGuiInputTextFlags_None,
        )) {
            replay_seconds = std.math.clamp(replay_seconds, REPLAY_SECONDS_MIN, REPLAY_SECONDS_MAX);
            replay_seconds_local = replay_seconds;
        }
        if (c.ImGui_IsItemDeactivatedAfterEdit() and replay_seconds != current_replay_seconds) {
            try actor.dispatch(.{ .user_settings = .{
                .set_replay_seconds = @intCast(replay_seconds),
            } });
            replay_seconds_local = null;
        } else if (!c.ImGui_IsItemActive()) {
            replay_seconds_local = null;
        }

        const replay_duration_label = try util.format_duration_label(allocator, @intCast(replay_seconds));
        defer allocator.free(replay_duration_label);
        c.ImGui_PushTextWrapPos(0);
        c.ImGui_TextDisabled("Duration: %s", replay_duration_label.ptr);
        c.ImGui_PopTextWrapPos();
    }
}
