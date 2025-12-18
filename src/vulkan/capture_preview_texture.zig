const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const vk = @import("vulkan");
const imguiz = @import("imguiz").imguiz;

/// Stores the texture required for rendering the capture preview
/// on the IMGUI UI.
pub const CapturePreviewTexture = struct {
    const Self = @This();
    vulkan: *Vulkan,
    sampler: vk.Sampler,
    descriptor_set: imguiz.VkDescriptorSet,
    im_texture_ref: imguiz.ImTextureRef,

    pub fn init(vulkan: *Vulkan, image_view: vk.ImageView) !Self {
        const sampler = try vulkan.device.createSampler(&vk.SamplerCreateInfo{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0.0,
            .anisotropy_enable = .false,
            .max_anisotropy = 1.0,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0.0,
            .max_lod = 0.0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = .false,
        }, null);

        const s: imguiz.VkSampler = @ptrFromInt(@intFromEnum(sampler));
        const i: imguiz.VkImageView = @ptrFromInt(@intFromEnum(image_view));
        const descriptor_set = imguiz.cImGui_ImplVulkan_AddTexture(s, i, imguiz.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL).?;
        const im_texture_ref = imguiz.ImTextureRef{
            ._TexID = @intFromPtr(descriptor_set),
        };

        return .{
            .vulkan = vulkan,
            .sampler = sampler,
            .descriptor_set = descriptor_set,
            .im_texture_ref = im_texture_ref,
        };
    }

    pub fn deinit(self: *Self) void {
        if (@intFromPtr(self.descriptor_set) != 0) {
            imguiz.cImGui_ImplVulkan_RemoveTexture(self.descriptor_set);
        }
        self.vulkan.device.destroySampler(self.sampler, null);
    }
};
