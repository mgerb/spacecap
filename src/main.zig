const std = @import("std");
const UI = @import("./ui/ui.zig").UI;
const Vulkan = @import("./vulkan/vulkan.zig").Vulkan;
const Actor = @import("./actor.zig").Actor;
const Util = @import("./util.zig");
const sdl = @import("./ui/sdl.zig");
const PlatformCaptureSetup = @import("./capture/platform_capture_setup.zig").PlatformCaptureSetup;
const args = @import("./args.zig");
const PlatformIpc = @import("./ipc/platform_ipc.zig").PlatformIpc;
const PlatformAudioCapture = @import("./capture/audio/platform_audio_capture.zig").PlatformAudioCapture;
const PlatformVideoCapture = @import("./capture/video/platform_video_capture.zig").PlatformVideoCapture;
const PlatformGlobalShortcuts = @import("./global_shortcuts/platform_global_shortcuts.zig").PlatformGlobalShortcuts;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const parsed_args: ?args.Args = args.parse(allocator);

    if (try cli_app(allocator, parsed_args)) {
        return;
    }
    try gui_app(allocator, parsed_args);
}

/// Handle command-line-only modes and return whether execution
/// should stop before launching the full app.
fn cli_app(allocator: std.mem.Allocator, parsed_args: ?args.Args) !bool {
    if (!comptime Util.isLinux()) return false;
    const linux_args = parsed_args orelse return false;

    switch (linux_args) {
        .send => |send_cmd| switch (send_cmd) {
            .@"save-replay" => {
                const _ipc = try PlatformIpc.init(allocator, null);
                var ipc = _ipc.ipc();
                defer ipc.deinit();

                ipc.sendCommand(.save_replay) catch |err| {
                    switch (err) {
                        error.SpacecapNotRunning => {
                            std.debug.print("spacecap is not running.\n", .{});
                        },
                        error.IpcPermissionDenied => {
                            std.debug.print("permission denied while contacting spacecap IPC socket.\n", .{});
                        },
                        else => {
                            std.debug.print("failed to send save replay command: {}\n", .{err});
                        },
                    }
                    std.process.exit(1);
                };

                return true;
            },
        },
    }

    return false;
}

/// Run the full Spacecap application, start global shortcuts + IPC server,
/// and launch the UI/event loop.
fn gui_app(allocator: std.mem.Allocator, parsed_args: ?args.Args) !void {
    _ = parsed_args;
    PlatformCaptureSetup.init();
    defer PlatformCaptureSetup.deinit();

    var sdl_vulkan_extensions = try sdl.get_sdl_vulkan_extensions(allocator);
    defer sdl_vulkan_extensions.deinit();

    const vulkan = try Vulkan.init(allocator, sdl_vulkan_extensions.list.items);
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

    const actor = try Actor.init(
        allocator,
        vulkan,
        &video_capture_interface,
        &audio_capture_interface,
        &global_shortcuts,
    );
    defer actor.deinit();

    global_shortcuts.registerShortcutHandler(.{ .ptr = actor, .handler = Actor.globalShortcutsHandler });

    const StateThread = struct {
        pub fn run(_state: *Actor) void {
            _state.run();
        }
    };
    const state_thread = try std.Thread.spawn(.{}, StateThread.run, .{actor});

    const _ipc = try PlatformIpc.init(allocator, actor);
    var ipc = _ipc.ipc();
    try ipc.start();
    defer ipc.deinit();

    const ui = try UI.init(allocator, actor, vulkan);
    defer ui.deinit();

    state_thread.join();
}
