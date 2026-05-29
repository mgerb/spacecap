const c = @import("imguiz").imguiz;
const VulkanCapturePreviewTexture = @import("../vulkan/vulkan_capture_preview_texture.zig").VulkanCapturePreviewTexture;
const dockspace = @import("./dockspace.zig");

pub fn draw_video_preview(
    args: union(enum) {
        // The empty state is for rendering a balck background even when
        // a capture source isn't available.
        empty,
        vulkan_video_not_supported,
        capture_preview: struct {
            capture_preview_buffer: *VulkanCapturePreviewTexture,
            width: u32,
            height: u32,
        },
    },
) !void {
    c.ImGui_PushStyleColor(c.ImGuiCol_WindowBg, c.IM_COL32(0, 0, 0, 255));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 0);

    _ = c.ImGui_Begin(dockspace.VIDEO_WINDOW_NAME, null, c.ImGuiWindowFlags_None);
    defer c.ImGui_End();

    c.ImGui_PopStyleColor();
    c.ImGui_PopStyleVarEx(2);

    const container_size = c.ImGui_GetContentRegionAvail();
    const container_width = container_size.x;
    const container_height = container_size.y;

    switch (args) {
        .empty => {},
        .capture_preview => |capture_preview| {
            const capture_width: f32 = @floatFromInt(capture_preview.width);
            const capture_height: f32 = @floatFromInt(capture_preview.height);

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
            const cursor_y = (container_height - render_height) / 2;
            c.ImGui_SetCursorPos(.{ .x = cursor_x, .y = cursor_y });
            c.ImGui_Image(capture_preview.capture_preview_buffer.im_texture_ref, .{ .x = render_width, .y = render_height });
        },
        .vulkan_video_not_supported => {
            const message = "Vulkan video is not supported on your current hardware. Video recording will be disabled.";
            const wrap_width = container_width * 0.8;
            const text_size = c.ImGui_CalcTextSizeEx(message, null, false, wrap_width);
            const cursor_x = (container_width - text_size.x) / 2;
            const cursor_y = (container_height - text_size.y) / 2;
            c.ImGui_SetCursorPos(.{ .x = cursor_x, .y = cursor_y });
            c.ImGui_PushTextWrapPos(cursor_x + wrap_width);
            c.ImGui_TextWrapped(message);
            c.ImGui_PopTextWrapPos();
        },
    }
}
