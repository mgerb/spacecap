const vk = @import("vulkan");
const imguiz = @import("imguiz").imguiz;

/// Stores the texture required for rendering a Vulkan image with ImGui.
pub const VulkanImGuiTexture = struct {
    const Self = @This();
    descriptor_set: imguiz.VkDescriptorSet,
    im_texture_ref: imguiz.ImTextureRef,

    pub fn init(image_view: vk.ImageView) !Self {
        const i: imguiz.VkImageView = @ptrFromInt(@backingInt(image_view));
        const descriptor_set = imguiz.cImGui_ImplVulkan_AddTexture(
            i,
            imguiz.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        ) orelse return error.ImGuiTextureDescriptorAllocationFailed;
        const im_texture_ref = imguiz.ImTextureRef{
            ._TexID = @intFromPtr(descriptor_set),
        };

        return .{
            .descriptor_set = descriptor_set,
            .im_texture_ref = im_texture_ref,
        };
    }

    pub fn deinit(self: *Self) void {
        if (@intFromPtr(self.descriptor_set) != 0) {
            imguiz.cImGui_ImplVulkan_RemoveTexture(self.descriptor_set);
        }
    }
};
