//// global types I don't know where to put yet

const vk = @import("vulkan");

pub const Size = struct {
    width: u32,
    height: u32,
};

pub const ReplayWindow = struct {
    start_ns: i128,
    end_ns: i128,
};
