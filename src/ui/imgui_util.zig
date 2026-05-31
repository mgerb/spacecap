const std = @import("std");
const imguiz = @import("imguiz").imguiz;

pub const WIDTH_FILL = -std.math.floatMin(f32);

pub fn help_marker(text: [*]const u8) void {
    imguiz.ImGui_TextDisabled("(?)");
    if (imguiz.ImGui_BeginItemTooltip()) {
        imguiz.ImGui_PushTextWrapPos(imguiz.ImGui_GetFontSize() * 35.0);
        imguiz.ImGui_TextUnformatted(text);
        imguiz.ImGui_PopTextWrapPos();
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
pub fn item_tooltip(text: [*:0]const u8) void {
    if (imguiz.ImGui_IsItemHovered(imguiz.ImGuiHoveredFlags_DelayNormal | imguiz.ImGuiHoveredFlags_AllowWhenDisabled)) {
        imguiz.ImGui_SetTooltip(text);
    }
}

/// Helper for `ImGui_SetNextItemWidth(-std.math.floatMin(f32))`
pub fn set_next_item_width_fill() void {
    imguiz.ImGui_SetNextItemWidth(WIDTH_FILL);
}
