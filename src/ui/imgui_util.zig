const imguiz = @import("imguiz").imguiz;

pub fn help_marker(text: [*]const u8) void {
    imguiz.ImGui_TextDisabled("(?)");
    if (imguiz.ImGui_BeginItemTooltip()) {
        imguiz.ImGui_PushTextWrapPos(imguiz.ImGui_GetFontSize() * 35.0);
        imguiz.ImGui_TextUnformatted(text);
        imguiz.ImGui_PopTextWrapPos();
        imguiz.ImGui_EndTooltip();
    }
}
