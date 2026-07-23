const std = @import("std");
const imguiz = @import("imguiz").imguiz;
const Colors = @import("./theme.zig").Colors;

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

pub fn center_next_text(text: [*:0]const u8) void {
    const text_width = imguiz.ImGui_CalcTextSizeEx(text, null, true, -1).x;
    const available_width = imguiz.ImGui_GetContentRegionAvail().x;
    imguiz.ImGui_SetCursorPosX(
        imguiz.ImGui_GetCursorPosX() + @max(0, (available_width - text_width) / 2),
    );
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
