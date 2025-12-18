const c = @import("imguiz").imguiz;
const VulkanImageBuffer = @import("../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;
const CapturePreviewTexture = @import("../vulkan/capture_preview_texture.zig").CapturePreviewTexture;

pub fn drawVideoPreview(capture_preview_buffer: *CapturePreviewTexture, width: u32, height: u32) !void {
    const left_panel_width = 250.0;
    const viewport_size = c.ImGui_GetMainViewport().*.Size;
    const container_width = viewport_size.x - left_panel_width;
    const container_height = viewport_size.y;
    c.ImGui_SetNextWindowPos(.{ .x = left_panel_width, .y = 0 }, 0);
    c.ImGui_SetNextWindowSize(c.ImVec2{
        .x = container_width,
        .y = container_height,
    }, 0);
    c.ImGui_PushStyleColor(c.ImGuiCol_WindowBg, c.IM_COL32(0, 0, 0, 255));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 0);
    _ = c.ImGui_Begin(
        "video preview",
        null,
        c.ImGuiWindowFlags_NoTitleBar |
            c.ImGuiWindowFlags_NoResize |
            c.ImGuiWindowFlags_NoMouseInputs |
            c.ImGuiWindowFlags_NoDecoration |
            c.ImGuiWindowFlags_NoCollapse,
    );
    defer c.ImGui_PopStyleColor();
    defer c.ImGui_PopStyleVarEx(2);
    defer c.ImGui_End();

    const capture_width = @as(f32, @floatFromInt(width));
    const capture_height = @as(f32, @floatFromInt(height));

    const aspect_ratio = capture_width / capture_height;

    var render_width = container_width;
    var render_height = render_width / aspect_ratio;

    if (render_height > container_height) {
        render_height = container_height;
        render_width = render_height * aspect_ratio;
    }

    if (render_width > container_width) {
        render_width = container_width;
        render_height = render_width / aspect_ratio;
    }

    const cursor_x = (container_width - render_width) / 2;
    c.ImGui_SetCursorPosX(cursor_x);
    c.ImGui_Image(capture_preview_buffer.im_texture_ref, .{ .x = render_width, .y = render_height });
}
