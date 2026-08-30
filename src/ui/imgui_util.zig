const std = @import("std");
const imguiz = @import("imguiz").imguiz;
const Colors = @import("./theme.zig").Colors;

pub const WIDTH_FILL = -std.math.floatMin(f32);

/// Display a byte slice as unformatted imgui text without requiring a null
/// terminator.
pub fn text_unformatted(bytes: []const u8) void {
    imguiz.ImGui_TextUnformattedEx(bytes.ptr, bytes.ptr + bytes.len);
}

/// Must be called while an ImGui tooltip is active.
pub fn wrapped_tooltip(text: []const u8) void {
    imguiz.ImGui_PushTextWrapPos(imguiz.ImGui_GetFontSize() * 25);
    text_unformatted(text);
    imguiz.ImGui_PopTextWrapPos();
}

pub fn help_marker(text: []const u8) void {
    imguiz.ImGui_TextDisabled("(?)");
    if (imguiz.ImGui_BeginItemTooltip()) {
        wrapped_tooltip(text);
        imguiz.ImGui_EndTooltip();
    }
}

/// Set a tooltip on the previously rendered item.
///
/// e.g.
///
/// ```zig
/// c.ImGui_Button("test button");
/// item_tooltip("asdf");
/// ```
pub fn item_tooltip(text: []const u8) void {
    if (imguiz.ImGui_IsItemHovered(imguiz.ImGuiHoveredFlags_DelayNormal | imguiz.ImGuiHoveredFlags_AllowWhenDisabled)) {
        if (imguiz.ImGui_BeginTooltip()) {
            wrapped_tooltip(text);
            imguiz.ImGui_EndTooltip();
        }
    }
}

/// Helper for `ImGui_SetNextItemWidth(-std.math.floatMin(f32))`
pub fn set_next_item_width_fill() void {
    imguiz.ImGui_SetNextItemWidth(WIDTH_FILL);
}

pub fn center_next_text(text: [*:0]const u8) void {
    const text_width = imguiz.ImGui_CalcTextSizeEx(text, null, true, -1).x;
    const available_width = imguiz.ImGui_GetContentRegionAvail().x;
    imguiz.ImGui_SetCursorPosX(
        imguiz.ImGui_GetCursorPosX() + @max(0, (available_width - text_width) / 2),
    );
}

/// Begin a tab with one icon before its title, using a separate color for the icon.
pub fn begin_tab_item_with_colored_icon(
    label: [:0]const u8,
    icon: [:0]const u8,
    icon_color: imguiz.ImVec4,
    p_open: ?*bool,
    flags: imguiz.ImGuiTabItemFlags,
) bool {
    const visible_end = std.mem.indexOf(u8, label, "##") orelse label.len;
    const style = imguiz.ImGui_GetStyle().*;
    const icon_width = imguiz.ImGui_CalcTextSize(icon.ptr).x;
    const label_width = imguiz.ImGui_CalcTextSizeEx(label.ptr, label.ptr + visible_end, false, -1).x;
    const spacing = style.ItemInnerSpacing.x;
    const has_close_button_or_marker = p_open != null or (flags & imguiz.ImGuiTabItemFlags_UnsavedDocument) != 0;
    const trailing_width = if (has_close_button_or_marker) spacing + imguiz.ImGui_GetFontSize() else 1;

    imguiz.ImGui_SetNextItemWidth(icon_width + spacing + label_width + style.FramePadding.x * 2 + trailing_width);
    imguiz.ImGui_PushStyleColorImVec4(imguiz.ImGuiCol_Text, Colors.transparent.as_vec4());
    const selected = imguiz.ImGui_BeginTabItem(label.ptr, p_open, flags);
    imguiz.ImGui_PopStyleColor();
    if (!imguiz.ImGui_IsItemVisible()) {
        return selected;
    }

    const tab_min = imguiz.ImGui_GetItemRectMin();
    const tab_max = imguiz.ImGui_GetItemRectMax();
    const text_pos = imguiz.ImVec2{ .x = tab_min.x + style.FramePadding.x, .y = tab_min.y + style.FramePadding.y };
    const draw_list = imguiz.ImGui_GetWindowDrawList();
    const text_max_x = tab_max.x - style.FramePadding.x - (if (has_close_button_or_marker) trailing_width else 0);
    imguiz.ImDrawList_PushClipRect(draw_list, text_pos, .{ .x = text_max_x, .y = tab_max.y }, true);
    imguiz.ImDrawList_AddText(draw_list, text_pos, imguiz.ImGui_GetColorU32ImVec4(icon_color), icon.ptr);
    imguiz.ImDrawList_AddTextEx(
        draw_list,
        .{ .x = text_pos.x + icon_width + spacing, .y = text_pos.y },
        imguiz.ImGui_GetColorU32(imguiz.ImGuiCol_Text),
        label.ptr,
        label.ptr + visible_end,
    );
    imguiz.ImDrawList_PopClipRect(draw_list);
    return selected;
}

/// NOTE: Must be followed by `pop_button_color`.
pub fn push_button_color(color: Colors.Enum) void {
    const colors = blk: {
        switch (color) {
            .red => {
                break :blk .{ Colors.red.as_vec4(), Colors.light_red.as_vec4() };
            },
            .green => {
                break :blk .{ Colors.green.as_vec4(), Colors.light_green.as_vec4() };
            },
            .transparent => {
                break :blk .{ Colors.transparent.as_vec4(), Colors.transparent.as_vec4() };
            },
            else => {
                @panic("Color not implemented.");
            },
        }
    };
    imguiz.ImGui_PushStyleColorImVec4(imguiz.ImGuiCol_Button, colors.@"0");
    imguiz.ImGui_PushStyleColorImVec4(imguiz.ImGuiCol_ButtonHovered, colors.@"1");
    imguiz.ImGui_PushStyleColorImVec4(imguiz.ImGuiCol_ButtonActive, colors.@"0");
}

pub fn pop_button_color() void {
    imguiz.ImGui_PopStyleColorEx(3);
}
