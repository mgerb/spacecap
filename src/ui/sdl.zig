const std = @import("std");
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
    try init();
    defer imguiz.SDL_Quit();

    var extensions = try std.ArrayList([*:0]const u8).initCapacity(allocator, 0);
    var extensions_count: u32 = 0;
    const sdl_extensions = imguiz.SDL_Vulkan_GetInstanceExtensions(&extensions_count);
    if (sdl_extensions == null) {
        return error.SDL_Vulkan_GetInstanceExtensionsFailure;
    }
    errdefer {
        for (extensions.items) |extension| allocator.free(std.mem.span(extension));
        extensions.deinit(allocator);
    }
    for (0..extensions_count) |i| {
        const copied = try allocator.dupeZ(u8, std.mem.span(sdl_extensions[i]));
        try extensions.append(allocator, copied);
    }

    return .{
        .allocator = allocator,
        .list = extensions,
    };
}

/// If Linux, try Wayland, fallback to x11.
pub fn init() !void {
    if (util.isLinux()) {
        if (try try_sdl_init_with_hint("wayland")) {
            log.info("[sdl_init] using wayland", .{});
            return;
        }
        if (try try_sdl_init_with_hint("x11")) {
            log.info("[sdl_init] using x11", .{});
            return;
        }
        return error.SDL_initFailure;
    }

    if (!imguiz.SDL_Init(SDL_INIT_FLAGS)) {
        return error.SDL_initFailure;
    }
}

fn try_sdl_init_with_hint(driver_name: [*:0]const u8) !bool {
    _ = imguiz.SDL_SetHint(imguiz.SDL_HINT_VIDEO_DRIVER, driver_name);
    if (!imguiz.SDL_Init(SDL_INIT_FLAGS)) {
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
