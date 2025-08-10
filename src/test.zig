test {
    _ = @import("./main.zig");
    _ = @import("./channel.zig");
    _ = @import("./vulkan/replay_buffer.zig");
    _ = @import("./capture/linux/pipewire/token_manager.zig");
    _ = @import("./vulkan/vulkan.zig");
}
