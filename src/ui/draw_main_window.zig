const c = @import("imguiz").imguiz;
const VideoDisplay = @import("./video_display.zig").VideoDisplay;
const vk = @import("vulkan");

pub fn drawMainWindow(video_display: *VideoDisplay, src_image: ?vk.Image) !void {
    const viewport_pos = c.ImGui_GetMainViewport().*.Pos;
    const viewport_size = c.ImGui_GetMainViewport().*.Size;

    const left_panel_width = 250.0;

    c.ImGui_SetNextWindowPos(.{ .x = viewport_pos.x + left_panel_width, .y = viewport_pos.y }, 0);
    c.ImGui_SetNextWindowSize(.{ .x = viewport_size.x - left_panel_width, .y = viewport_size.y }, 0);

    _ = c.ImGui_Begin("main window", null, c.ImGuiWindowFlags_NoTitleBar |
        c.ImGuiWindowFlags_NoResize |
        c.ImGuiWindowFlags_NoMove |
        c.ImGuiWindowFlags_NoCollapse);
    defer c.ImGui_End();

    if (src_image) |image| {
        try video_display.copyAndDraw(image);
    }
}
