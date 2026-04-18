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

/// Helper for `ImGui_SetNextItemWidth(-std.math.floatMin(f32))`
pub fn set_next_item_width_fill() void {
    imguiz.ImGui_SetNextItemWidth(WIDTH_FILL);
}
