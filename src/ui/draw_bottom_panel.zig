const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("imguiz").imguiz;
const dockspace = @import("./dockspace.zig");
const Store = @import("../store/store.zig").Store;
const AUDIO_GAIN_MIN = @import("../store/capture_store.zig").AUDIO_GAIN_MIN;
const AUDIO_GAIN_MAX = @import("../store/capture_store.zig").AUDIO_GAIN_MAX;
const AudioDevice = @import("../store/audio_session.zig").AudioDevice;
const imgui_util = @import("./imgui_util.zig");
const util = @import("../util.zig");
const theme = @import("./theme.zig");

const log = std.log.scoped(.draw_bottom_panel);

var val: f32 = 50;
var enabled: bool = false;

pub fn draw_bottom_panel(allocator: Allocator, store: *Store, state: *Store.State) !void {
    _ = c.ImGui_Begin(dockspace.BOTTOM_WINDOW_NAME, null, c.ImGuiWindowFlags_None);
    defer c.ImGui_End();

    // ----------------------------------------------------------------------------
    // Video collapsing header.
    // ----------------------------------------------------------------------------
    if (c.ImGui_CollapsingHeader("Video", c.ImGuiTreeNodeFlags_DefaultOpen)) {
        const replay_buffer_duration_label = try util.format_duration_label(
            allocator,
            @intCast(state.capture.replay_buffer_metrics.duration_seconds(store.io) orelse 0),
        );
        defer allocator.free(replay_buffer_duration_label);

        const video_container_width = c.ImGui_GetContentRegionAvail().x;
        const video_actions_column_width = @max(
            200,
            @min(400, video_container_width - 400),
        );

        // ----------------------------------------------------------------------------
        // Video container.
        // ----------------------------------------------------------------------------
        if (c.ImGui_BeginTable(
            "##video_container",
            2,
            c.ImGuiTableFlags_SizingStretchProp,
        )) {
            defer c.ImGui_EndTable();

            c.ImGui_TableSetupColumnEx("video_1", c.ImGuiTableColumnFlags_WidthStretch, 1.0, 0);
            c.ImGui_TableSetupColumnEx("video_2", c.ImGuiTableColumnFlags_WidthFixed, video_actions_column_width, 0);

            c.ImGui_TableNextRow();
            _ = c.ImGui_TableNextColumn();

            const video_cell_padding = c.ImVec2{ .x = 5, .y = 5 };
            c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_CellPadding, video_cell_padding);
            defer c.ImGui_PopStyleVar();

            // ----------------------------------------------------------------------------
            // Video primary.
            // ----------------------------------------------------------------------------
            if (c.ImGui_BeginTable("##video_1", 3, c.ImGuiTableFlags_SizingStretchProp)) {
                defer c.ImGui_EndTable();

                c.ImGui_TableSetupColumnEx("action", c.ImGuiTableColumnFlags_WidthFixed, 200, 0);
                c.ImGui_TableSetupColumnEx("size", c.ImGuiTableColumnFlags_WidthFixed, 84, 0);
                c.ImGui_TableSetupColumnEx("time", c.ImGuiTableColumnFlags_WidthFixed, 84, 0);

                c.ImGui_TableNextRow();
                _ = c.ImGui_TableNextColumn();
                const video_source_button_label = if (state.capture.video_capture_active) "󰦳 New Source" else "󰦳 Select Source";
                c.ImGui_BeginDisabled(!state.capture.is_video_capture_supprted);
                if (c.ImGui_ButtonEx(video_source_button_label, .{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0 })) {
                    store.dispatch(.{ .capture = .{ .select_video_source = .{ .source_type = .all } } });
                }
                c.ImGui_EndDisabled();

                const video_capture_ready = state.capture.is_video_capture_supprted and state.capture.video_capture_active;

                c.ImGui_TableNextRow();
                _ = c.ImGui_TableNextColumn();
                const replay_buffer_button_label = if (state.capture.replay_buffer_active) " Replay Buffer" else " Replay Buffer";
                const replay_buffer_button_color = if (state.capture.replay_buffer_active) theme.red.as_vec4() else theme.green.as_vec4();
                const replay_buffer_button_hover_color = if (state.capture.replay_buffer_active) theme.light_red.as_vec4() else theme.light_green.as_vec4();
                const replay_buffer_button_disabled = !state.capture.replay_buffer_active and !video_capture_ready;
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, replay_buffer_button_color);
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, replay_buffer_button_hover_color);
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, replay_buffer_button_color);
                c.ImGui_BeginDisabled(replay_buffer_button_disabled);
                if (c.ImGui_ButtonEx(replay_buffer_button_label, .{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0 })) {
                    store.dispatch(.{ .capture = if (state.capture.replay_buffer_active) .stop_replay_buffer else .start_replay_buffer });
                }
                c.ImGui_EndDisabled();
                c.ImGui_PopStyleColorEx(3);
                _ = c.ImGui_TableNextColumn();
                c.ImGui_Text("%.2fMB", state.capture.replay_buffer_metrics.size_in_mb(.total));
                if (c.ImGui_BeginItemTooltip()) {
                    c.ImGui_Text(
                        "Audio: %.2fMB",
                        state.capture.replay_buffer_metrics.size_in_mb(.audio),
                    );
                    c.ImGui_Text(
                        "Video: %.2fMB",
                        state.capture.replay_buffer_metrics.size_in_mb(.video),
                    );
                    c.ImGui_EndTooltip();
                }
                _ = c.ImGui_TableNextColumn();
                c.ImGui_TextUnformatted(replay_buffer_duration_label);

                c.ImGui_TableNextRow();
                _ = c.ImGui_TableNextColumn();
                const recording_button_label = if (state.capture.recording_to_disk) " Record" else " Record";
                const recording_button_color = if (state.capture.recording_to_disk) theme.red.as_vec4() else theme.green.as_vec4();
                const recording_button_hover_color = if (state.capture.recording_to_disk) theme.light_red.as_vec4() else theme.light_green.as_vec4();
                const recording_button_disabled = !state.capture.recording_to_disk and !video_capture_ready;
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, recording_button_color);
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, recording_button_hover_color);
                c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, recording_button_color);
                c.ImGui_BeginDisabled(recording_button_disabled);
                if (c.ImGui_ButtonEx(recording_button_label, .{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0 })) {
                    store.dispatch(.{ .capture = if (state.capture.recording_to_disk) .stop_recording_to_disk else .start_recording_to_disk });
                }
                c.ImGui_EndDisabled();
                c.ImGui_PopStyleColorEx(3);
                _ = c.ImGui_TableNextColumn();
                c.ImGui_Text("%.2fMB", state.capture.recording_metrics.size_in_mb(.total));
                if (c.ImGui_BeginItemTooltip()) {
                    c.ImGui_Text("Audio: %.2fMB", state.capture.recording_metrics.size_in_mb(.audio));
                    c.ImGui_Text("Video: %.2fMB", state.capture.recording_metrics.size_in_mb(.video));
                    c.ImGui_EndTooltip();
                }

                _ = c.ImGui_TableNextColumn();
                if (state.capture.recording_to_disk) {
                    const recording_duration_label = try util.format_duration_label(allocator, @intCast(state.capture.recording_metrics.duration_seconds(store.io) orelse 0));
                    defer allocator.free(recording_duration_label);
                    c.ImGui_TextUnformatted(recording_duration_label);
                } else {
                    c.ImGui_TextUnformatted("0s");
                }
            }

            _ = c.ImGui_TableNextColumn();

            // ----------------------------------------------------------------------------
            // Video actions.
            // ----------------------------------------------------------------------------
            if (c.ImGui_BeginTable("##video_2", 1, c.ImGuiTableFlags_SizingStretchProp)) {
                defer c.ImGui_EndTable();

                const button_height = c.ImGui_GetFrameHeight() * 1.5 + video_cell_padding.y;

                c.ImGui_TableNextRow();
                _ = c.ImGui_TableNextColumn();
                const save_replay_enabled = state.capture.is_video_capture_supprted and state.capture.replay_buffer_active;
                c.ImGui_BeginDisabled(!save_replay_enabled);
                if (c.ImGui_ButtonEx("󰆓 Save Replay", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = button_height })) {
                    store.dispatch(.{ .capture = .save_replay });
                }
                c.ImGui_EndDisabled();

                c.ImGui_TableNextRow();
                _ = c.ImGui_TableNextColumn();
                c.ImGui_BeginDisabled(true);
                defer c.ImGui_EndDisabled();
                _ = c.ImGui_ButtonEx("󰹑 Screenshot", .{ .x = c.ImGui_GetContentRegionAvail().x, .y = button_height });
                imgui_util.item_tooltip("Screenshots are not implemented yet.");
            }
        }
    }

    // ----------------------------------------------------------------------------
    // Audio collapsing header.
    // ----------------------------------------------------------------------------
    if (c.ImGui_CollapsingHeader("Audio", c.ImGuiTreeNodeFlags_DefaultOpen)) {
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_CellPadding, .{ .x = 0, .y = 5 });
        defer c.ImGui_PopStyleVar();

        if (c.ImGui_BeginTable("##audio_devices", 2, c.ImGuiTableFlags_BordersInnerH)) {
            defer c.ImGui_EndTable();

            c.ImGui_TableSetupColumnEx("audio device", c.ImGuiTableColumnFlags_WidthStretch, 1.0, 0);
            c.ImGui_TableSetupColumnEx("gain", c.ImGuiTableColumnFlags_WidthFixed, 300, 0);

            c.ImGui_TableNextRow();
            _ = c.ImGui_TableNextColumn();
            c.ImGui_Text("Audio Device");
            _ = c.ImGui_TableNextColumn();
            c.ImGui_Text("Gain");

            for (state.capture.audio_devices.list.items, 0..) |*audio_device, i| {
                if (audio_device.selected) {
                    c.ImGui_PushIDInt(@intCast(i));
                    defer c.ImGui_PopID();
                    try draw_audio_device(allocator, store, audio_device);
                }
            }

            // ----------------------------------------------------------------------------
            // Combo box to select devices.
            // ----------------------------------------------------------------------------
            c.ImGui_TableNextRow();
            _ = c.ImGui_TableNextColumn();

            if (c.ImGui_BeginCombo("##audio_sources", "Add audio device...", 0)) {
                defer c.ImGui_EndCombo();

                if (state.capture.audio_devices.list.items.len == 0) {
                    c.ImGui_Text("No audio devices found");
                } else {
                    for (state.capture.audio_devices.list.items, 0..) |*audio_device, i| {
                        c.ImGui_PushIDInt(@intCast(i));
                        defer c.ImGui_PopID();

                        var selected = audio_device.selected;
                        var flags = c.ImGuiSelectableFlags_None;
                        if (selected) {
                            flags |= c.ImGuiSelectableFlags_Disabled;
                        }
                        const item_label = try std.fmt.allocPrintSentinel(allocator, "{s}  {s}{s}##audio-device-{s}", .{
                            if (audio_device.device_type == .source) "" else "",
                            audio_device.name,
                            if (audio_device.is_default) " (default)" else "",
                            audio_device.id,
                        }, 0);
                        defer allocator.free(item_label);

                        if (c.ImGui_SelectableBoolPtr(
                            item_label,
                            &selected,
                            flags,
                        )) {
                            store.dispatch(.{ .capture = .{ .toggle_audio_device = try .from(store.allocator, audio_device.id) } });
                        }
                    }
                }
            }
        }
    }
}

/// Draw an audio device in the table.
fn draw_audio_device(allocator: Allocator, store: *Store, audio_device: *AudioDevice) !void {
    c.ImGui_TableNextRow();

    _ = c.ImGui_TableNextColumn();

    if (c.ImGui_Button("")) {
        store.dispatch(.{ .capture = .{ .toggle_audio_device = try .from(allocator, audio_device.id) } });
    }
    imgui_util.item_tooltip("Remove device");

    c.ImGui_SameLine();

    const name = try std.fmt.allocPrintSentinel(allocator, "{s}  {s}{s}", .{
        if (audio_device.device_type == .source) "" else "",
        audio_device.name,
        if (audio_device.is_default) " (default)" else "",
    }, 0);
    defer allocator.free(name);

    c.ImGui_TextUnformatted(name);
    imgui_util.item_tooltip(name);

    var gain_copy = audio_device.gain;

    _ = c.ImGui_TableNextColumn();
    c.ImGui_SetNextItemWidth(c.ImGui_GetContentRegionAvail().x);
    if (c.ImGui_SliderFloatEx("", &gain_copy, AUDIO_GAIN_MIN, AUDIO_GAIN_MAX, "%.2fx", 0)) {
        store.dispatch(.{ .capture = .{
            .set_audio_device_gain = try .init(allocator, .{
                .device_id = audio_device.id,
                .gain = gain_copy,
            }),
        } });
    }
}
