const c = @import("imguiz").imguiz;
const VulkanImageBuffer = @import("../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;
const CapturePreviewTexture = @import("../vulkan/capture_preview_texture.zig").CapturePreviewTexture;
const COLUMN_WIDTH = @import("./draw_left_column.zig").COLUMN_WIDTH;

pub fn drawVideoPreview(capture_preview_buffer: *CapturePreviewTexture, width: u32, height: u32) !void {
    const viewport_size = c.ImGui_GetMainViewport().*.Size;
    const container_width = viewport_size.x - COLUMN_WIDTH;
    const container_height = viewport_size.y;
    c.ImGui_SetNextWindowPos(.{ .x = COLUMN_WIDTH, .y = 0 }, 0);
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

// TODO: Just combine this with the function above.
pub fn drawVideoPreviewUnavailable() void {
    const viewport_size = c.ImGui_GetMainViewport().*.Size;
    const container_width = viewport_size.x - COLUMN_WIDTH;
    const container_height = viewport_size.y;
    c.ImGui_SetNextWindowPos(.{ .x = COLUMN_WIDTH, .y = 0 }, 0);
    c.ImGui_SetNextWindowSize(c.ImVec2{
        .x = container_width,
        .y = container_height,
    }, 0);
    c.ImGui_PushStyleColor(c.ImGuiCol_WindowBg, c.IM_COL32(0, 0, 0, 255));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 24, .y = 24 });
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

    const message = "Video capture is unavailable because this GPU does not support Vulkan Video.";
    const fallback_aspect_ratio = 16.0 / 9.0;

    var render_width = container_width;
    var render_height = render_width / fallback_aspect_ratio;

    if (render_height > container_height) {
        render_height = container_height;
        render_width = render_height * fallback_aspect_ratio;
    }

    if (render_width > container_width) {
        render_width = container_width;
        render_height = render_width / fallback_aspect_ratio;
    }

    const preview_x = (container_width - render_width) / 2;
    const preview_y = 0.0;
    const wrap_width = render_width * 0.7;
    const text_size = c.ImGui_CalcTextSizeEx(message, null, false, wrap_width);
    const cursor_x = preview_x + (render_width - text_size.x) / 2;
    const cursor_y = preview_y + (render_height - text_size.y) / 2;
    c.ImGui_SetCursorPos(.{ .x = cursor_x, .y = cursor_y });
    c.ImGui_PushTextWrapPos(cursor_x + wrap_width);
    c.ImGui_TextWrapped(message);
    c.ImGui_PopTextWrapPos();
}
