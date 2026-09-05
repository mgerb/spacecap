const std = @import("std");
const build_options = @import("build_options");
const app_identity = @import("../common/linux/app_identity.zig");
const util = @import("../util.zig");
const imguiz = @import("imguiz").imguiz;

const log = std.log.scoped(.sdl);

const SDL_INIT_FLAGS = imguiz.SDL_INIT_VIDEO | imguiz.SDL_INIT_GAMEPAD;

pub const SDLVulkanExtensions = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList([*:0]const u8),

    pub fn deinit(self: *SDLVulkanExtensions) void {
        for (self.list.items) |extension| {
            self.allocator.free(std.mem.span(extension));
        }
        self.list.deinit(self.allocator);
    }
};

/// Caller owns memory
pub fn get_sdl_vulkan_extensions(allocator: std.mem.Allocator) !SDLVulkanExtensions {
    var extensions: std.ArrayList([*:0]const u8) = .empty;
    var extensions_count: u32 = 0;
    const sdl_extensions = imguiz.SDL_Vulkan_GetInstanceExtensions(&extensions_count);
    if (sdl_extensions == null) {
        return error.SDLVulkanGetInstanceExtensionsFailure;
    }
    errdefer {
        for (extensions.items) |extension| allocator.free(std.mem.span(extension));
        extensions.deinit(allocator);
    }
    for (0..extensions_count) |i| {
        const copied = try allocator.dupeSentinel(u8, std.mem.span(sdl_extensions[i]), 0);
        try extensions.append(allocator, copied);
    }

    return .{
        .allocator = allocator,
        .list = extensions,
    };
}

/// If Linux, try Wayland, fallback to x11, which causes a panic because it's not supported.
pub fn init() !void {
    if (!imguiz.SDL_SetAppMetadata(
        app_identity.APP_NAME.ptr,
        build_options.version.ptr,
        app_identity.APP_ID.ptr,
    )) {
        log.err("[init] failed to set app metadata: {s}", .{imguiz.SDL_GetError()});
        return error.SDLSetAppMetadataFailure;
    }

    if (util.is_linux()) {
        if (try try_sdl_init_with_hint("wayland")) {
            log.info("[sdl_init] using wayland", .{});
        } else if (try try_sdl_init_with_hint("x11")) {
            const message = "[sdl_init] using x11, which is not supported.";
            log.err(message, .{});
            @panic(message);
        } else {
            return error.SDLInitFailure;
        }
    } else if (!imguiz.SDL_Init(SDL_INIT_FLAGS)) {
        log.err("[init] SDL initialization failed: {s}", .{imguiz.SDL_GetError()});
        return error.SDLInitFailure;
    }

    // Vulkan may not be initialized yet, so we need to make sure the lib is loaded.
    if (!imguiz.SDL_Vulkan_LoadLibrary(null)) {
        log.err("[init] failed to load Vulkan: {s}", .{imguiz.SDL_GetError()});
        return error.SDLVulkanLoadLibraryFailure;
    }

    if (!imguiz.SDL_InitSubSystem(imguiz.SDL_INIT_AUDIO)) {
        log.err("[init] audio initialization failed: {s}", .{imguiz.SDL_GetError()});
        return;
    }

    const driver = imguiz.SDL_GetCurrentAudioDriver();
    log.info("[init] using audio driver: {s}", .{driver});
}

pub fn deinit() void {
    imguiz.SDL_Vulkan_UnloadLibrary();
    imguiz.SDL_Quit();
}

fn try_sdl_init_with_hint(driver_name: [*:0]const u8) !bool {
    _ = imguiz.SDL_SetHint(imguiz.SDL_HINT_VIDEO_DRIVER, driver_name);
    if (!imguiz.SDL_Init(SDL_INIT_FLAGS)) {
        log.err("[try_sdl_init_with_hint] {s} initialization failed: {s}", .{
            driver_name,
            imguiz.SDL_GetError(),
        });
        return false;
    }

    const actual_driver = imguiz.SDL_GetCurrentVideoDriver() orelse {
        imguiz.SDL_Quit();
        return false;
    };

    if (std.mem.eql(u8, std.mem.span(actual_driver), std.mem.span(driver_name))) {
        return true;
    }

    imguiz.SDL_Quit();
    return false;
}
