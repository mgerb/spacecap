const std = @import("std");
const UI = @import("./ui/ui.zig").UI;
const Vulkan = @import("./vulkan/vulkan.zig").Vulkan;
const Capture = @import("./capture/capture.zig").Capture;
const StateActor = @import("./state_actor.zig").StateActor;
const UserSettings = @import("./user_settings.zig").UserSettings;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // TODO: move to state
    const user_settings = try UserSettings.load(allocator);
    try user_settings.save(allocator);

    const sdl_vulkan_extensions = try UI.getSDLVulkanExtensions(allocator);
    defer sdl_vulkan_extensions.deinit();

    const vulkan = try Vulkan.init(allocator, sdl_vulkan_extensions.items);
    defer vulkan.deinit();

    const capture = try Capture.init(allocator, vulkan);
    defer capture.deinit();

    const state_actor = try StateActor.init(allocator, capture, vulkan);
    defer state_actor.deinit();

    const StateThread = struct {
        pub fn run(_state: *StateActor) void {
            _state.run();
        }
    };
    const state_thread = try std.Thread.spawn(.{}, StateThread.run, .{state_actor});

    const ui = try UI.init(allocator, state_actor, vulkan);
    defer ui.deinit();

    state_thread.join();
}
