const std = @import("std");
const c = @import("imguiz").imguiz;
const imgui_util = @import("./imgui_util.zig");
const file_picker = @import("./draw_file_picker.zig");
const Store = @import("../store/store.zig").Store;
const String = @import("../string.zig").String;
const Colors = @import("./theme.zig").Colors;
const util = @import("../util.zig");
const FileBrowserState = @import("../store/file_browser_store.zig").FileBrowserStore.State;

const VIDEO_ICON = "";
const IMAGE_ICON = "󰋩";
const AUDIO_ICON = "󰝚";

const FileIcon = struct {
    glyph: [*:0]const u8,
    color: c.ImVec4,
};

pub fn draw(store: *Store, state: *const FileBrowserState, directory: []const u8) !void {

    // ----------------------------------------------------------------------------
    // Draw the directory picker at the top.
    // ----------------------------------------------------------------------------
    switch (file_picker.draw("file_browser_directory", directory)) {
        .none => {},
        .browse => store.dispatch(.{ .user_settings = .{ .select_output_directory = .file_browser } }),
        .set_path => |path| store.dispatch(.{ .user_settings = .{ .set_output_directory = .{
            .allocator = store.allocator,
            .output_directory = .file_browser,
            .directory = try store.allocator.dupe(u8, std.mem.sliceTo(&path, 0)),
        } } }),
    }
    c.ImGui_Spacing();

    // ----------------------------------------------------------------------------
    // Draw the file list in a new child to make it overflow scroll.
    // ----------------------------------------------------------------------------
    _ = c.ImGui_BeginChild(
        "##file_browser_list",
        .{ .x = 0, .y = 0 },
        c.ImGuiChildFlags_None,
        c.ImGuiWindowFlags_None,
    );
    defer c.ImGui_EndChild();

    if (state.files.entries.items.len == 0) {
        c.ImGui_TextDisabled("No files found");
        return;
    }

    if (!c.ImGui_BeginTable("##file_browser", 3, c.ImGuiTableFlags_SizingStretchProp)) {
        return;
    }
    defer c.ImGui_EndTable();

    // Icons can be different widths...
    const icon_width = @max(
        c.ImGui_CalcTextSizeEx(VIDEO_ICON, null, true, -1).x,
        c.ImGui_CalcTextSizeEx(IMAGE_ICON, null, true, -1).x,
        c.ImGui_CalcTextSizeEx(AUDIO_ICON, null, true, -1).x,
    );
    c.ImGui_TableSetupColumnEx("icon", c.ImGuiTableColumnFlags_WidthFixed, icon_width + 6, 0);
    c.ImGui_TableSetupColumnEx("name", c.ImGuiTableColumnFlags_WidthStretch, 1.0, 0);
    c.ImGui_TableSetupColumnEx("size", c.ImGuiTableColumnFlags_WidthFixed, 80, 0);

    for (state.files.entries.items, 0..) |entry, index| {
        c.ImGui_TableNextRow();
        _ = c.ImGui_TableNextColumn();
        const icon_pos = c.ImGui_GetCursorPos();
        c.ImGui_PushIDInt(@intCast(index));
        const row_clicked = c.ImGui_SelectableEx(
            "##file_row",
            false,
            c.ImGuiSelectableFlags_SpanAllColumns | c.ImGuiSelectableFlags_AllowOverlap,
            .{ .x = 0, .y = c.ImGui_GetTextLineHeight() },
        );
        c.ImGui_PopID();

        const file_name = std.fs.path.basename(entry.path.bytes);
        if (row_clicked) {
            store.dispatch(.{ .file_browser = .{
                .select_file = try String.init(store.allocator, entry.path.bytes),
            } });
        }

        // ----------------------------------------------------------------------------
        // Column 1: file type icon (optional)
        // ----------------------------------------------------------------------------
        if (get_file_icon(file_name)) |icon| {
            c.ImGui_SetCursorPos(icon_pos);
            c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Text, icon.color);
            c.ImGui_TextUnformatted(icon.glyph);
            c.ImGui_PopStyleColor();
        }

        // ----------------------------------------------------------------------------
        // Column 2: file name
        // ----------------------------------------------------------------------------
        _ = c.ImGui_TableNextColumn();
        imgui_util.text_unformatted(file_name);
        imgui_util.item_tooltip(file_name);

        // ----------------------------------------------------------------------------
        // Column 3: file size
        // ----------------------------------------------------------------------------
        _ = c.ImGui_TableNextColumn();
        const size_label = util.format_file_size_label(entry.size_bytes);
        const size_label_text = std.mem.sliceTo(&size_label, 0);
        const text_width = c.ImGui_CalcTextSizeEx(size_label_text.ptr, size_label_text.ptr + size_label_text.len, false, -1).x;
        const available_width = c.ImGui_GetContentRegionAvail().x;
        // Right align
        c.ImGui_SetCursorPosX(c.ImGui_GetCursorPosX() + @max(0, available_width - text_width));
        imgui_util.text_unformatted(size_label_text);
    }
}

/// Get the relative file icon based on file extension.
fn get_file_icon(file_name: []const u8) ?FileIcon {
    const extension = std.fs.path.extension(file_name);
    for ([_][]const u8{ ".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v", ".wmv" }) |video_extension| {
        if (std.ascii.eqlIgnoreCase(extension, video_extension)) {
            return .{ .glyph = VIDEO_ICON, .color = Colors.light_blue.as_vec4() }; // nf-fa-video_camera
        }
    }
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".svg" }) |image_extension| {
        if (std.ascii.eqlIgnoreCase(extension, image_extension)) {
            return .{ .glyph = IMAGE_ICON, .color = Colors.light_green.as_vec4() }; // nf-md-image
        }
    }
    for ([_][]const u8{ ".mp3", ".wav", ".flac", ".ogg", ".m4a", ".aac" }) |audio_extension| {
        if (std.ascii.eqlIgnoreCase(extension, audio_extension)) {
            return .{ .glyph = AUDIO_ICON, .color = Colors.light_red.as_vec4() }; // nf-md-music
        }
    }
    return null;
}
