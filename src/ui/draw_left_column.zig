const std = @import("std");
const c = @import("imguiz").imguiz;
const Actor = @import("../state/actor.zig").Actor;
const AudioDeviceType = @import("../capture/audio/audio_capture.zig").AudioDeviceType;
const AUDIO_GAIN_MIN = @import("../state/audio_state.zig").AUDIO_GAIN_MIN;
const AUDIO_GAIN_MAX = @import("../state/audio_state.zig").AUDIO_GAIN_MAX;
const imgui_util = @import("./imgui_util.zig");
const util = @import("../util.zig");
const Store = @import("../state/store.zig").Store;

pub const COLUMN_WIDTH = 380;
const CONTROL_HEIGHT: f32 = 30;
const GROUP_SPACING: f32 = 6;
const GAIN_LABEL_WIDTH: f32 = 36.0;
const CAPTURE_FPS_MIN: c_int = 1;
const CAPTURE_FPS_MAX: c_int = 500;
const CAPTURE_BIT_RATE_BPS_PER_KBPS: u64 = 1_000;
const CAPTURE_BIT_RATE_KBPS_MIN: i32 = 100;
const CAPTURE_BIT_RATE_KBPS_MAX: i32 = 1_000_000;
const REPLAY_SECONDS_MIN: i32 = 1;
const REPLAY_SECONDS_MAX: i32 = 60 * 60 * 24;
const VIDEO_OUTPUT_DIRECTORY_MAX_BYTES = std.fs.max_path_bytes;
const VIDEO_OUTPUT_DIRECTORY_PICKER_BUTTON_WIDTH: f32 = 34;

// These local values are temporary to hold the value
// of an input as it's being edited. We do this so that
// we don't update the state on every little change
// (e.g. dragging a slider).
var capture_fps_local: ?i32 = null;
var capture_bit_rate_local: ?i32 = null;
var replay_seconds_local: ?i32 = null;
var fg_fps_local: ?i32 = null;
var bg_fps_local: ?i32 = null;
var video_output_directory_local: ?[VIDEO_OUTPUT_DIRECTORY_MAX_BYTES:0]u8 = null;

fn device_type_label(device_type: AudioDeviceType) []const u8 {
    return switch (device_type) {
        .source => "Source",
        .sink => "Sink",
    };
}

fn draw_audio_device_selector(allocator: std.mem.Allocator, actor: *Actor) !void {
    var selected_count: usize = 0;
    var first_selected_name: ?[]const u8 = null;
    var locked_devices = actor.state.audio.devices.lock();
    defer locked_devices.unlock();
    const devices = locked_devices.unwrap();

    for (devices.items) |device| {
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

        if (devices.items.len == 0) {
            c.ImGui_Text("No audio devices found");
            return;
        }

        for (devices.items) |device| {
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
    var locked_devices = actor.state.audio.devices.lock();
    defer locked_devices.unlock();
    const devices = locked_devices.unwrap();
    var selected_total: usize = 0;
    for (devices.items) |device| {
        if (device.selected) selected_total += 1;
    }

    var rendered_count: usize = 0;
    for (devices.items) |device| {
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
            imgui_util.set_next_item_width_fill();
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

pub fn draw_left_column(allocator: std.mem.Allocator, actor: *Actor, store: *Store) !void {
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
                if (c.ImGui_ButtonEx("Start Replay", .{ .x = imgui_util.WIDTH_FILL, .y = CONTROL_HEIGHT })) {
                    try actor.dispatch(.start_record);
                }
                c.ImGui_PopStyleColorEx(3);
                c.ImGui_EndDisabled();

                _ = c.ImGui_TableNextColumn();

                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, c.ImVec4{ .x = 0.6, .y = 0.0, .z = 0.0, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, c.ImVec4{ .x = 0.75, .y = 0.1, .z = 0.1, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, c.ImVec4{ .x = 0.5, .y = 0.0, .z = 0.0, .w = 1.0 });
                c.ImGui_BeginDisabled(!video_capture_supported or !actor.state.is_recording_video);
                if (c.ImGui_ButtonEx("Stop Replay", .{ .x = imgui_util.WIDTH_FILL, .y = CONTROL_HEIGHT })) {
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

            if (c.ImGui_BeginTable("recording_button_table", 2, c.ImGuiTableFlags_None)) {
                _ = c.ImGui_TableNextColumn();
                c.ImGui_BeginDisabled(!video_capture_supported or actor.state.is_recording_to_disk or !actor.state.is_capturing_video);
                if (c.ImGui_ButtonEx("Start Recording", .{ .x = imgui_util.WIDTH_FILL, .y = CONTROL_HEIGHT })) {
                    try actor.dispatch(.start_disk_recording);
                }
                c.ImGui_EndDisabled();

                _ = c.ImGui_TableNextColumn();
                c.ImGui_BeginDisabled(!video_capture_supported or !actor.state.is_recording_to_disk);
                if (c.ImGui_ButtonEx("Stop Recording", .{ .x = imgui_util.WIDTH_FILL, .y = CONTROL_HEIGHT })) {
                    try actor.dispatch(.stop_disk_recording);
                }
                c.ImGui_EndDisabled();
                c.ImGui_EndTable();
            }
            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

            c.ImGui_Text(
                "%ds / %.2fMB",
                actor.state.replay_buffer.seconds,
                actor.state.replay_buffer.size_in_mb(.total),
            );
            if (c.ImGui_BeginItemTooltip()) {
                c.ImGui_Text(
                    "Audio: %.2fMB",
                    actor.state.replay_buffer.size_in_mb(.audio),
                );
                c.ImGui_Text(
                    "Video: %.2fMB",
                    actor.state.replay_buffer.size_in_mb(.video),
                );
                c.ImGui_EndTooltip();
            }
        }

        if (c.ImGui_BeginTabItem("Settings", null, 0)) {
            defer c.ImGui_EndTabItem();

            try draw_capture_settings(allocator, actor);

            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

            try draw_output_settings(allocator, actor);

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

            if (util.DEBUG) {
                c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });
                c.ImGui_SeparatorText("IMGUI Debug");

                if (c.ImGui_ButtonEx("Show Demo", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0 })) {
                    store.dispatch(.show_demo);
                }

                c.ImGui_Spacing();
                const io = c.ImGui_GetIO();
                c.ImGui_TextDisabled("%.3f ms/frame", 1000.0 / io.*.Framerate);
                c.ImGui_TextDisabled("%.1f fps", io.*.Framerate);
            }
        }
    }
}

fn draw_output_settings(allocator: std.mem.Allocator, actor: *Actor) !void {
    c.ImGui_SeparatorText("Output");

    const video_output_directory = blk: {
        // const settings_locked = actor.state.user_settings.settings.lock();
        // defer settings_locked.unlock();
        // const settings = settings_locked.unwrap_ptr();
        // break :blk settings.video_output_directory.?.bytes;
        break :blk actor.store.state.private.value.user_settings.user_settings.video_output_directory.?.bytes;
    };

    c.ImGui_Text("Video");

    var _video_output_directory_local = video_output_directory_local orelse blk: {
        var buffer = std.mem.zeroes([VIDEO_OUTPUT_DIRECTORY_MAX_BYTES:0]u8);
        const copy_len = @min(video_output_directory.len, buffer.len - 1);
        @memmove(buffer[0..copy_len], video_output_directory[0..copy_len]);
        break :blk buffer;
    };

    if (c.ImGui_BeginTable("video_output_directory_row", 2, c.ImGuiTableFlags_SizingStretchProp)) {
        defer c.ImGui_EndTable();

        c.ImGui_TableSetupColumnEx("input", c.ImGuiTableColumnFlags_WidthStretch, 1.0, 0);
        c.ImGui_TableSetupColumnEx("button", c.ImGuiTableColumnFlags_WidthFixed, VIDEO_OUTPUT_DIRECTORY_PICKER_BUTTON_WIDTH, 0);

        _ = c.ImGui_TableNextColumn();
        imgui_util.set_next_item_width_fill();
        _ = c.ImGui_InputText(
            "##video_output_directory",
            &_video_output_directory_local,
            _video_output_directory_local.len,
            c.ImGuiInputTextFlags_None,
        );
        if (c.ImGui_IsItemEdited()) {
            video_output_directory_local = _video_output_directory_local;
        }
        if (c.ImGui_IsItemDeactivatedAfterEdit()) {
            const updated_directory = std.mem.sliceTo(_video_output_directory_local[0..], 0);
            if (updated_directory.len > 0 and !std.mem.eql(u8, updated_directory, video_output_directory)) {
                actor.store.dispatch(.{ .user_settings = .{
                    .set_video_output_directory = try .init(allocator, .{
                        .video_output_directory = updated_directory,
                    }),
                } });
                // try actor.dispatch(.{ .user_settings = .{
                //     .set_video_output_directory = try .init(allocator, .{
                //         .video_output_directory = updated_directory,
                //     }),
                // } });
            }
            video_output_directory_local = null;
        } else if (!c.ImGui_IsItemActive()) {
            video_output_directory_local = null;
        }

        _ = c.ImGui_TableNextColumn();
        if (c.ImGui_ButtonEx("...##video_output_directory_picker", .{
            .x = imgui_util.WIDTH_FILL,
            .y = 0,
        })) {
            try actor.dispatch(.{ .user_settings = .select_output_directory });
        }
        if (c.ImGui_BeginItemTooltip()) {
            c.ImGui_TextUnformatted("Choose directory");
            c.ImGui_EndTooltip();
        }
    }
}

fn draw_capture_settings(allocator: std.mem.Allocator, actor: *Actor) !void {
    c.ImGui_SeparatorText("Capture Settings");

    const settings_locked = actor.state.user_settings.settings.lock();
    const settings = settings_locked.unwrap_ptr();

    const current_capture_fps: i32 = @intCast(settings.capture_fps);
    const current_capture_bit_rate: i32 = @intCast(settings.capture_bit_rate / CAPTURE_BIT_RATE_BPS_PER_KBPS);
    const current_replay_seconds: i32 = @intCast(settings.replay_seconds);
    var restore_capture_source_on_startup = settings.restore_capture_source_on_startup;
    var start_replay_buffer_on_startup = settings.start_replay_buffer_on_startup;

    settings_locked.unlock();

    // FPS
    {
        var fps = capture_fps_local orelse current_capture_fps;
        c.ImGui_Text("Max FPS");
        c.ImGui_SameLine();
        imgui_util.help_marker("The maximum capture rate (frames per second). If your system can't keep up, it may be slower than the desired FPS.");
        imgui_util.set_next_item_width_fill();
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
        imgui_util.set_next_item_width_fill();
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
        imgui_util.set_next_item_width_fill();
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

    c.ImGui_Text("Restore capture source on startup");
    c.ImGui_SameLine();
    imgui_util.help_marker("Try to restore the last capture source when Spacecap starts.");
    if (c.ImGui_Checkbox("##restore_capture_source_on_startup", &restore_capture_source_on_startup)) {
        try actor.dispatch(.{ .user_settings = .{
            .set_restore_capture_source_on_startup = restore_capture_source_on_startup,
        } });
    }

    {
        c.ImGui_Text("Start replay buffer on startup");
        c.ImGui_SameLine();
        imgui_util.help_marker("Start the replay buffer when Spacecap starts. Requires 'Restore capture source on startup'.");
        c.ImGui_BeginDisabled(!restore_capture_source_on_startup);
        defer c.ImGui_EndDisabled();
        if (c.ImGui_Checkbox("##start_replay_buffer_on_startup", &start_replay_buffer_on_startup)) {
            try actor.dispatch(.{ .user_settings = .{
                .set_start_replay_buffer_on_startup = start_replay_buffer_on_startup,
            } });
        }
    }
}
