const std = @import("std");
const UI = @import("./ui/ui.zig").UI;
const Vulkan = @import("./vulkan/vulkan.zig").Vulkan;
const StateActor = @import("./state_actor.zig").StateActor;
const UserSettings = @import("./user_settings.zig").UserSettings;
const Util = @import("./util.zig");
const PlatformCaptureSetup = @import("./capture/platform_capture_setup.zig").PlatformCaptureSetup;

const PlatformVideoCapture = if (Util.isLinux())
    @import("./capture/video/linux/linux_pipewire_dma_capture.zig").LinuxPipewireDmaCapture
else
    @import("./capture/video/windows/windows_video_capture.zig").WindowsVideoCapture;

const PlatformAudioCapture = if (Util.isLinux())
    @import("./capture/audio/linux/linux_audio_capture.zig").LinuxAudioCapture
else
    @import("./capture/audio/windows/windows_audio_capture.zig").WindowsAudioCapture;

const PlatformGlobalShortcuts = if (Util.isLinux())
    @import("./global_shortcuts/xdg_desktop_portal_global_shortcuts.zig").XdgDesktopPortalGlobalShortcuts
else
    @import("./global_shortcuts/windows_global_shortcuts.zig").WindowsGlobalShortcuts;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // if (comptime Util.isLinux()) {
    //     try @import("./linux_audio_example.zig").record_audio_clip(allocator);
    // }

    PlatformCaptureSetup.init();
    defer PlatformCaptureSetup.deinit();

    // TODO: move to state
    const user_settings = try UserSettings.load(allocator);
    try user_settings.save(allocator);

    var sdl_vulkan_extensions = try UI.getSDLVulkanExtensions(allocator);
    defer sdl_vulkan_extensions.deinit(allocator);

    const vulkan = try Vulkan.init(allocator, sdl_vulkan_extensions.items);
    defer vulkan.deinit();

    // TODO: create dropdown selector in UI to select capture method when more are implemented.
    const _video_capture = try PlatformVideoCapture.init(allocator, vulkan);
    var video_capture_interface = _video_capture.videoCapture();
    defer video_capture_interface.deinit();

    const _audio_capture = try PlatformAudioCapture.init(allocator);
    var audio_capture_interface = _audio_capture.audioCapture();
    defer audio_capture_interface.deinit();

    const platform_global_shortcuts = try PlatformGlobalShortcuts.init(allocator);
    var global_shortcuts = platform_global_shortcuts.global_shortcuts();
    try global_shortcuts.run();
    defer global_shortcuts.deinit();

    const state_actor = try StateActor.init(
        allocator,
        vulkan,
        &video_capture_interface,
        &audio_capture_interface,
        &global_shortcuts,
    );
    defer state_actor.deinit();

    global_shortcuts.registerShortcutHandler(.{ .ptr = state_actor, .handler = StateActor.globalShortcutsHandler });

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
