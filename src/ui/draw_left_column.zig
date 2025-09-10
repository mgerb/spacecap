const std = @import("std");
const c = @import("imguiz").imguiz;
const StateActor = @import("../state_actor.zig").StateActor;
const imgui_util = @import("./imgui_util.zig");

pub fn drawLeftColumn(allocator: std.mem.Allocator, state_actor: *StateActor) !void {
    // Get viewport size
    const viewport_pos = c.ImGui_GetMainViewport().*.Pos;
    const viewport_size = c.ImGui_GetMainViewport().*.Size;

    // Define left panel size
    const left_panel_width = 250.0;

    // Set position and size for the left panel window
    c.ImGui_SetNextWindowPos(viewport_pos, 0);
    c.ImGui_SetNextWindowSize(c.ImVec2{
        .x = left_panel_width,
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

            if (c.ImGui_BeginTable("source_table", 2, c.ImGuiTableFlags_None)) {
                _ = c.ImGui_TableNextColumn();
                if (c.ImGui_ButtonEx("Desktop", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0 })) {
                    try state_actor.dispatch(.{ .select_video_source = .desktop });
                }

                _ = c.ImGui_TableNextColumn();
                if (c.ImGui_ButtonEx("Window", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0 })) {
                    try state_actor.dispatch(.{ .select_video_source = .window });
                }
                c.ImGui_EndTable();
            }

            if (state_actor.state.has_source) {
                c.ImGui_SameLine();
                c.ImGui_Text("has source");
                if (state_actor.state.selected_screen_cast_identifier) |name| {
                    const screen_name_text = try std.fmt.allocPrintSentinel(allocator, "Selected: {s}", .{name}, 0);
                    defer allocator.free(screen_name_text);
                    c.ImGui_Text(screen_name_text);
                }
            }

            if (c.ImGui_BeginTable("button_table", 2, c.ImGuiTableFlags_None)) {
                _ = c.ImGui_TableNextColumn();

                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, c.ImVec4{ .x = 0.251, .y = 0.627, .z = 0.169, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, c.ImVec4{ .x = 0.329, .y = 0.706, .z = 0.247, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, c.ImVec4{ .x = 0.173, .y = 0.471, .z = 0.129, .w = 1.0 });
                c.ImGui_BeginDisabled(state_actor.state.recording or !state_actor.state.has_source);
                if (c.ImGui_ButtonEx("Start", .{ .x = -std.math.floatMin(f32), .y = 0 })) {
                    try state_actor.dispatch(.start_record);
                }
                c.ImGui_PopStyleColorEx(3);
                c.ImGui_EndDisabled();

                _ = c.ImGui_TableNextColumn();

                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, c.ImVec4{ .x = 0.6, .y = 0.0, .z = 0.0, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, c.ImVec4{ .x = 0.75, .y = 0.1, .z = 0.1, .w = 1.0 });
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, c.ImVec4{ .x = 0.5, .y = 0.0, .z = 0.0, .w = 1.0 });
                c.ImGui_BeginDisabled(!state_actor.state.recording);
                if (c.ImGui_ButtonEx("Stop", .{ .x = -std.math.floatMin(f32), .y = 0 })) {
                    try state_actor.dispatch(.stop_record);
                }
                c.ImGui_PopStyleColorEx(3);
                c.ImGui_EndDisabled();
                c.ImGui_EndTable();
            }

            const replay_text = try std.fmt.allocPrintSentinel(allocator, "Time: {}s", .{state_actor.state.replay_buffer_state.seconds}, 0);
            defer allocator.free(replay_text);
            const size_text = try std.fmt.allocPrintSentinel(allocator, "Size: {d:.2}MB", .{state_actor.state.replay_buffer_state.sizeInMB()}, 0);
            defer allocator.free(size_text);
            c.ImGui_Separator();
            c.ImGui_Text(replay_text);
            c.ImGui_Text(size_text);
            c.ImGui_Separator();

            c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, c.ImVec4{ .x = 0.447, .y = 0.529, .z = 0.992, .w = 1.0 });
            c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, c.ImVec4{ .x = 0.525, .y = 0.608, .z = 1.000, .w = 1.0 });
            c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, c.ImVec4{ .x = 0.369, .y = 0.451, .z = 0.874, .w = 1.0 });
            c.ImGui_BeginDisabled(!state_actor.state.recording);
            if (c.ImGui_ButtonEx("Save Replay", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = 30 })) {
                try state_actor.dispatch(.save_replay);
            }
            c.ImGui_PopStyleColorEx(3);
            c.ImGui_EndDisabled();
        }

        if (c.ImGui_BeginTabItem("Settings", null, 0)) {
            defer c.ImGui_EndTabItem();
            c.ImGui_SeparatorText("GUI Settings");

            var fg_fps = @as(f32, @floatFromInt(state_actor.state.user_settings.gui_foreground_fps));
            if (c.ImGui_DragFloatEx("FG FPS", &fg_fps, 1, 1.0, 240.0, "%.0f", 0)) {
                try state_actor.dispatch(.{ .set_gui_foreground_fps = @as(u32, @intFromFloat(fg_fps)) });
            }
            c.ImGui_SameLine();
            imgui_util.help_marker("Forground FPS. This is the max frame rate Spacecap will render while focused. Double click to change.");

            var bg_fps = @as(f32, @floatFromInt(state_actor.state.user_settings.gui_background_fps));
            if (c.ImGui_DragFloatEx("BG FPS", &bg_fps, 1, 1.0, 240.0, "%.0f", 0)) {
                try state_actor.dispatch(.{ .set_gui_background_fps = @as(u32, @intFromFloat(bg_fps)) });
            }
            c.ImGui_SameLine();
            imgui_util.help_marker("Background FPS. This is the max frame rate Spacecap will render while NOT focused. Double click to change.");

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
