const std = @import("std");
const c = @import("imguiz").imguiz;
const imgui_util = @import("./imgui_util.zig");
const util = @import("../util.zig");
const Store = @import("../store/store.zig").Store;
const dockspace = @import("./dockspace.zig");

const GROUP_SPACING: f32 = 6;
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

pub fn draw_left_column(allocator: std.mem.Allocator, store: *Store, state: *Store.State) !void {
    _ = c.ImGui_Begin(dockspace.LEFT_WINDOW_NAME, null, c.ImGuiWindowFlags_None);
    defer c.ImGui_End();

    if (c.ImGui_BeginTabBar("MainTabBar", 0)) {
        defer c.ImGui_EndTabBar();

        if (c.ImGui_BeginTabItem(" Settings", null, 0)) {
            defer c.ImGui_EndTabItem();

            try draw_capture_settings(allocator, store, state);

            c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

            try draw_output_settings(allocator, store);

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

fn draw_output_settings(allocator: std.mem.Allocator, store: *Store) !void {
    c.ImGui_SeparatorText("Output Directory");

    const video_output_directory = blk: {
        break :blk store.state.private.value.user_settings.user_settings.video_output_directory.?.bytes;
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
                store.dispatch(.{ .user_settings = .{
                    .set_video_output_directory = try .init(allocator, .{
                        .video_output_directory = updated_directory,
                    }),
                } });
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
            store.dispatch(.{ .user_settings = .select_output_directory });
        }
        if (c.ImGui_BeginItemTooltip()) {
            c.ImGui_TextUnformatted("Choose directory");
            c.ImGui_EndTooltip();
        }
    }
}

fn draw_capture_settings(allocator: std.mem.Allocator, store: *Store, state: *Store.State) !void {
    c.ImGui_SeparatorText("Capture Settings");

    const settings = state.user_settings.user_settings;

    const current_capture_fps: i32 = @intCast(settings.capture_fps);
    const current_capture_bit_rate: i32 = @intCast(settings.capture_bit_rate / CAPTURE_BIT_RATE_BPS_PER_KBPS);
    const current_replay_seconds: i32 = @intCast(settings.replay_seconds);
    var restore_capture_source_on_startup = settings.restore_capture_source_on_startup;
    var start_replay_buffer_on_startup = settings.start_replay_buffer_on_startup;

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
            store.dispatch(.{ .user_settings = .{
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
            store.dispatch(.{ .user_settings = .{
                .set_capture_bit_rate = @as(u64, @intCast(capture_bit_rate)) * CAPTURE_BIT_RATE_BPS_PER_KBPS,
            } });
            capture_bit_rate_local = null;
        } else if (!c.ImGui_IsItemActive()) {
            // Keep the UI synced with state when not actively editing.
            capture_bit_rate_local = null;
        }

        if (state.capture.recording_to_disk or state.capture.replay_buffer_active) {
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
            store.dispatch(.{ .user_settings = .{
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

    c.ImGui_PushTextWrapPos(0);
    c.ImGui_Text("Restore capture source on startup");
    c.ImGui_PopTextWrapPos();
    c.ImGui_SameLine();
    imgui_util.help_marker("Try to restore the last capture source when Spacecap starts.");
    if (c.ImGui_Checkbox("##restore_capture_source_on_startup", &restore_capture_source_on_startup)) {
        store.dispatch(.{ .user_settings = .{
            .set_restore_capture_source_on_startup = restore_capture_source_on_startup,
        } });
    }

    {
        c.ImGui_PushTextWrapPos(0);
        c.ImGui_Text("Start replay buffer on startup");
        c.ImGui_PopTextWrapPos();
        c.ImGui_SameLine();
        imgui_util.help_marker("Start the replay buffer when Spacecap starts. Requires 'Restore capture source on startup'.");
        c.ImGui_BeginDisabled(!restore_capture_source_on_startup);
        defer c.ImGui_EndDisabled();
        if (c.ImGui_Checkbox("##start_replay_buffer_on_startup", &start_replay_buffer_on_startup)) {
            store.dispatch(.{ .user_settings = .{
                .set_start_replay_buffer_on_startup = start_replay_buffer_on_startup,
            } });
        }
    }
}
