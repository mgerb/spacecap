const std = @import("std");
const UI = @import("./ui/ui.zig").UI;
const Vulkan = @import("./vulkan/vulkan.zig").Vulkan;
const Util = @import("./util.zig");
const sdl = @import("./ui/sdl.zig");
const PlatformCaptureSetup = @import("./capture/platform_capture_setup.zig").PlatformCaptureSetup;
const args = @import("./args.zig");
const PlatformIpc = @import("./ipc/platform_ipc.zig").PlatformIpc;
const PlatformAudioCapture = @import("./capture/audio/platform_audio_capture.zig").PlatformAudioCapture;
const PlatformVideoCapture = @import("./capture/video/platform_video_capture.zig").PlatformVideoCapture;
const PlatformFilePicker = @import("./file_picker/platform_file_picker.zig").PlatformFilePicker;
const PlatformGlobalShortcuts = @import("./global_shortcuts/platform_global_shortcuts.zig").PlatformGlobalShortcuts;
const Store = @import("./state/store.zig").Store;
const ipc_module = @import("./ipc/ipc.zig");
const IpcCommand = ipc_module.IpcCommand;

const log = std.log.scoped(.main);

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
    if (!comptime Util.is_linux()) return false;
    const linux_args = parsed_args orelse return false;

    switch (linux_args) {
        .send => |send_cmd| {
            const ipc_command = IpcCommand.from_send_command(send_cmd);
            const _ipc = try PlatformIpc.init(allocator, null);
            var ipc = _ipc.ipc();
            defer ipc.deinit();

            ipc.send_command(ipc_command) catch |err| {
                switch (err) {
                    error.SpacecapNotRunning => {
                        log.err("[cli_app] Spacecap is not running.", .{});
                    },
                    error.IpcPermissionDenied => {
                        log.err("[cli_app] permission denied while contacting spacecap IPC socket.\n", .{});
                    },
                    else => {
                        log.err("[cli_app] failed to send IPC command '{s}': {}\n", .{ @tagName(send_cmd), err });
                    },
                }
                std.process.exit(1);
            };

            return true;
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
    var video_capture_interface = _video_capture.video_capture();
    defer video_capture_interface.deinit();

    const _audio_capture = try PlatformAudioCapture.init(allocator);
    var audio_capture_interface = _audio_capture.audio_capture();
    defer audio_capture_interface.deinit();

    var platform_file_picker = try PlatformFilePicker.init();
    defer platform_file_picker.deinit();
    var file_picker_interface = platform_file_picker.file_picker();

    const platform_global_shortcuts = try PlatformGlobalShortcuts.init(allocator);
    var global_shortcuts = platform_global_shortcuts.global_shortcuts();
    try global_shortcuts.run();
    defer global_shortcuts.deinit();

    var store = try Store.init(
        allocator,
        vulkan,
        &file_picker_interface,
        &audio_capture_interface,
        &video_capture_interface,
        &global_shortcuts,
    );
    defer store.deinit();

    store.dispatch_application_startup_messages();

    const store_thread = try std.Thread.spawn(.{}, struct {
        fn run(_store: *Store) void {
            _store.run();
        }
    }.run, .{store});

    const _ipc = try PlatformIpc.init(allocator, store);
    var ipc = _ipc.ipc();
    try ipc.start();
    defer ipc.deinit();

    const ui = try UI.init(allocator, store, vulkan);
    defer ui.deinit();

    store_thread.join();
}
