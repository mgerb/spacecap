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
const Store = @import("./store/store.zig").Store;
const ipc_module = @import("./ipc/ipc.zig");
const IpcCommand = ipc_module.IpcCommand;
const Env = @import("./env.zig");

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    Env.init(init.io, init.environ_map);

    const parsed_args: ?args.Args = args.parse(init);

    if (try cli_app(allocator, init.io, parsed_args)) {
        return;
    }
    try gui_app(allocator, init.io, parsed_args);
}

/// Handle command-line-only modes and return whether execution
/// should stop before launching the full app.
fn cli_app(allocator: std.mem.Allocator, io: std.Io, parsed_args: ?args.Args) !bool {
    if (!comptime Util.is_linux()) return false;
    const linux_args = parsed_args orelse return false;

    switch (linux_args) {
        .send => |send_cmd| {
            const ipc_command = IpcCommand.from_send_command(send_cmd);
            const _ipc = try PlatformIpc.init(allocator, io, null);
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
fn gui_app(allocator: std.mem.Allocator, io: std.Io, parsed_args: ?args.Args) !void {
    _ = parsed_args;
    PlatformCaptureSetup.init();
    defer PlatformCaptureSetup.deinit();

    var sdl_vulkan_extensions = try sdl.get_sdl_vulkan_extensions(allocator);
    defer sdl_vulkan_extensions.deinit();

    const vulkan = try Vulkan.init(allocator, io, sdl_vulkan_extensions.list.items);
    defer vulkan.deinit();

    // TODO: create dropdown selector in UI to select capture method when more are implemented.
    const platform_video_capture = try PlatformVideoCapture.init(allocator, io, vulkan);
    defer platform_video_capture.deinit();

    const platform_audio_capture = try PlatformAudioCapture.init(allocator, io);
    defer platform_audio_capture.deinit();

    var platform_file_picker = try PlatformFilePicker.init();
    defer platform_file_picker.deinit();

    const platform_global_shortcuts = try PlatformGlobalShortcuts.init(allocator, io);
    defer platform_global_shortcuts.deinit();
    var global_shortcuts = platform_global_shortcuts.global_shortcuts();
    try global_shortcuts.run();

    var store = try Store.init(
        allocator,
        io,
        vulkan,
        platform_file_picker.file_picker(),
        platform_audio_capture.audio_capture(),
        platform_video_capture.video_capture(),
        global_shortcuts,
    );
    defer store.deinit();

    store.dispatch_application_startup_messages();

    const store_thread = try std.Thread.spawn(.{}, struct {
        fn run(_store: *Store) void {
            _store.run(.{});
        }
    }.run, .{store});

    const _ipc = try PlatformIpc.init(allocator, io, store);
    var ipc = _ipc.ipc();
    try ipc.start();
    defer ipc.deinit();

    const ui = try UI.init(allocator, io, store, vulkan);
    defer ui.deinit();

    store_thread.join();
}
