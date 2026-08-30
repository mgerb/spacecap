const std = @import("std");
const build_options = @import("build_options");
const c = @import("imguiz").imguiz;
const imgui_util = @import("./imgui_util.zig");
const file_picker = @import("./draw_file_picker.zig");
const util = @import("../util.zig");
const Store = @import("../store/store.zig").Store;
const UserSettings = @import("../store/user_settings.zig").UserSettings;
const dockspace = @import("./dockspace.zig");
const file_browser = @import("./draw_file_browser.zig");

const GROUP_SPACING: f32 = 4;
const CAPTURE_FPS_MIN: c_int = 1;
const CAPTURE_FPS_MAX: c_int = 500;
const CAPTURE_BIT_RATE_BPS_PER_KBPS: u64 = 1_000;
const CAPTURE_BIT_RATE_KBPS_MIN: i32 = 100;
const CAPTURE_BIT_RATE_KBPS_MAX: i32 = 1_000_000;
const REPLAY_SECONDS_MIN: i32 = 1;
const REPLAY_SECONDS_MAX: i32 = 60 * 60 * 24;
const BYTES_PER_MB: u64 = 1024 * 1024;

// These local values are temporary to hold the value
// of an input as it's being edited. We do this so that
// we don't update the state on every little change
// (e.g. dragging a slider).
var capture_fps_local: ?i32 = null;
var capture_bit_rate_local: ?i32 = null;
var replay_seconds_local: ?i32 = null;
var replay_max_memory_mb_local: ?i32 = null;
var fg_fps_local: ?i32 = null;
var bg_fps_local: ?i32 = null;

pub fn draw_left_column(
    allocator: std.mem.Allocator,
    store: *Store,
    state: *Store.State,
) !void {
    _ = c.ImGui_Begin(dockspace.LEFT_WINDOW_NAME, null, c.ImGuiWindowFlags_None);
    defer c.ImGui_End();

    const footer_height = c.ImGui_GetFrameHeight();
    // ----------------------------------------------------------------------------
    // Content
    // ----------------------------------------------------------------------------
    {
        _ = c.ImGui_BeginChild(
            "##left_column_content",
            .{ .x = 0, .y = -footer_height },
            c.ImGuiChildFlags_None,
            c.ImGuiWindowFlags_None,
        );
        defer c.ImGui_EndChild();
        if (c.ImGui_BeginTabBar("main_tab_bar", 0)) {
            defer c.ImGui_EndTabBar();

            if (c.ImGui_BeginTabItem(" Files", null, 0)) {
                defer c.ImGui_EndTabItem();
                try file_browser.draw(store, &state.file_browser, state.user_settings.user_settings.file_browser_directory.?.bytes);
            }

            if (c.ImGui_BeginTabItem(" Settings", null, 0)) {
                defer c.ImGui_EndTabItem();

                try draw_capture_settings(store, state);

                c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

                try draw_output_settings(allocator, store);

                c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });
                draw_misc_settings();

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

    // ----------------------------------------------------------------------------
    // Footer
    // ----------------------------------------------------------------------------
    {
        _ = c.ImGui_BeginChild(
            "##left_column_footer",
            .{ .x = 0, .y = 0 },
            c.ImGuiChildFlags_None,
            c.ImGuiWindowFlags_None,
        );
        defer c.ImGui_EndChild();
        const version_label = std.fmt.comptimePrint("{s}", .{build_options.version});
        imgui_util.center_next_text(version_label);
        c.ImGui_TextDisabled(version_label);
    }
}

fn draw_misc_settings() void {
    c.ImGui_SeparatorText("Misc");
    const popup_title = "Global Shortcuts";

    if (c.ImGui_ButtonEx(popup_title, .{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0 })) {
        c.ImGui_OpenPopup(popup_title, c.ImGuiPopupFlags_None);
    }

    c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

    const report_an_issue_text = "Report Issue";
    imgui_util.center_next_text(report_an_issue_text);
    _ = c.ImGui_TextLinkOpenURLEx(report_an_issue_text, "https://github.com/mgerb/spacecap/issues/new");

    c.ImGui_Dummy(.{ .x = 0, .y = GROUP_SPACING });

    const source_text = " Source";
    imgui_util.center_next_text(source_text);
    _ = c.ImGui_TextLinkOpenURLEx(source_text, "https://github.com/mgerb/spacecap");

    const viewport_size = c.ImGui_GetMainViewport().*.Size;
    c.ImGui_SetNextWindowSize(.{ .x = @min(800, viewport_size.x), .y = @min(600, viewport_size.y) }, c.ImGuiCond_Appearing);
    var popup_open = true; // Enables the close icon in the top right.
    if (c.ImGui_BeginPopupModal(
        popup_title,
        &popup_open,
        c.ImGuiWindowFlags_NoSavedSettings,
    )) {
        defer c.ImGui_EndPopup();

        if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) {
            c.ImGui_CloseCurrentPopup();
        }

        const instructions: [:0]const u8 =
            \\KDE, GNOME, etc.
            \\----------------
            \\  Shortcuts can be configured in your system settings.
            \\  Spacecap configures global shortcuts via the XDG Desktop Portal.
            \\  See the list of supported desktop environments here:
            \\    https://wiki.archlinux.org/title/XDG_Desktop_Portal#List_of_backends_and_interfaces
            \\
            \\Other Compositors
            \\-----------------
            \\  The Spacecap CLI can be used to send commands:
            \\    spacecap -s save-replay
            \\
            \\  See all available commands:
            \\    spacecap -h
            \\
            \\  Examples:
            \\
            \\    Niri:
            \\      binds {
            \\        Mod+Shift+R { spawn-sh "spacecap -s save-replay"; }
            \\      }
            \\   
            \\    Hyprland:
            \\      hl.bind(
            \\        "SUPER + SHIFT + R",
            \\        hl.dsp.exec_cmd("spacecap -s save-replay")
            \\      )
        ;
        const content_size = c.ImGui_GetContentRegionAvail();
        _ = c.ImGui_InputTextMultilineEx(
            "##global_shortcuts_help",
            @constCast(instructions.ptr),
            instructions.len + 1,
            .{
                .x = imgui_util.WIDTH_FILL,
                .y = @max(100, content_size.y - c.ImGui_GetFrameHeightWithSpacing()),
            },
            c.ImGuiInputTextFlags_ReadOnly,
            null,
            null,
        );

        if (c.ImGui_ButtonEx("Close", .{ .x = content_size.x, .y = 0 })) {
            c.ImGui_CloseCurrentPopup();
        }
    }
}

fn draw_output_settings(allocator: std.mem.Allocator, store: *Store) !void {
    c.ImGui_SeparatorText("Output");

    const settings = store.state.private.value.user_settings.user_settings;
    const video_output_directory = settings.video_output_directory.?.bytes;
    const screenshot_output_directory = settings.screenshot_output_directory.?.bytes;

    c.ImGui_Text("Videos");
    try draw_output_directory_picker("video_output_directory", allocator, store, .videos, video_output_directory);

    c.ImGui_Text("Screenshots");
    try draw_output_directory_picker("screenshot_output_directory", allocator, store, .screenshots, screenshot_output_directory);
}

fn draw_output_directory_picker(
    comptime id: [:0]const u8,
    allocator: std.mem.Allocator,
    store: *Store,
    output_directory: UserSettings.OutputDirectory,
    directory: []const u8,
) !void {
    switch (file_picker.draw(id, directory)) {
        .none => {},
        .browse => store.dispatch(.{ .user_settings = .{ .select_output_directory = output_directory } }),
        .set_path => |path| store.dispatch(.{ .user_settings = .{ .set_output_directory = .{
            .allocator = allocator,
            .output_directory = output_directory,
            .directory = try store.allocator.dupe(u8, std.mem.sliceTo(&path, 0)),
        } } }),
    }
}

fn draw_capture_settings(store: *Store, state: *Store.State) !void {
    c.ImGui_SeparatorText("Capture");

    const settings = state.user_settings.user_settings;

    const current_capture_fps: i32 = @intCast(settings.capture_fps);
    const current_capture_bit_rate: i32 = @intCast(settings.capture_bit_rate / CAPTURE_BIT_RATE_BPS_PER_KBPS);
    const current_replay_seconds: i32 = @intCast(settings.replay_seconds);
    const current_replay_max_memory_mb: i32 = @intCast(if (settings.replay_max_bytes == 0)
        0
    else
        std.math.divCeil(u64, settings.replay_max_bytes, BYTES_PER_MB) catch |err| @panic(@errorName(err)));
    var restore_capture_source_on_startup = settings.restore_capture_source_on_startup;
    var start_replay_buffer_on_startup = settings.start_replay_buffer_on_startup;

    // FPS
    {
        var fps = capture_fps_local orelse current_capture_fps;
        c.ImGui_Text("FPS");
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
        imgui_util.help_marker("Capture bitrate in Kbps. Higher bitrate increases quality, but also increases size.");
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
        c.ImGui_PushTextWrapPos(0);
        c.ImGui_Text("Replay buffer length (s)");
        c.ImGui_PopTextWrapPos();
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

        const replay_duration_label = util.format_duration_label(.{
            .seconds = @floatFromInt(replay_seconds),
        });
        c.ImGui_PushTextWrapPos(0);
        c.ImGui_TextDisabled("Duration: %s", &replay_duration_label);
        c.ImGui_PopTextWrapPos();
    }

    // Replay buffer memory limit
    {
        c.ImGui_PushTextWrapPos(0);
        c.ImGui_Text("Replay video memory limit (MB)");
        c.ImGui_PopTextWrapPos();
        c.ImGui_SameLine();
        imgui_util.help_marker("Maximum size of the replay buffer (Megabytes). 0 disables the memory limit.");
        imgui_util.set_next_item_width_fill();
        var replay_max_memory_mb = replay_max_memory_mb_local orelse current_replay_max_memory_mb;
        if (c.ImGui_InputIntEx(
            "##replay_buffer_max_memory",
            &replay_max_memory_mb,
            5,
            25,
            c.ImGuiInputTextFlags_None,
        )) {
            replay_max_memory_mb = std.math.clamp(replay_max_memory_mb, 0, std.math.maxInt(i32));
            replay_max_memory_mb_local = replay_max_memory_mb;
        }
        if (c.ImGui_IsItemDeactivatedAfterEdit() and replay_max_memory_mb != current_replay_max_memory_mb) {
            store.dispatch(.{ .user_settings = .{
                .set_replay_max_bytes = @as(u64, @intCast(replay_max_memory_mb)) * BYTES_PER_MB,
            } });
            replay_max_memory_mb_local = null;
        } else if (!c.ImGui_IsItemActive()) {
            replay_max_memory_mb_local = null;
        }
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
