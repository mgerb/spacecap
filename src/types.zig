//// global types I don't know where to put yet

const vk = @import("vulkan");

pub const Size = struct {
    width: u32,
    height: u32,
};

pub const VkImages = struct {
    image: vk.Image,
    image_view: vk.ImageView,
    /// Capture timestamp in nanoseconds.
    frame_time_ns: i128,
};
