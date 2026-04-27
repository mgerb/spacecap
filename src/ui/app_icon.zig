const imguiz = @import("imguiz").imguiz;

const APP_ICON_BLUE = @embedFile("logo_blue.png");
const APP_ICON_RED = @embedFile("logo_red.png");
const APP_ICON_GREEN = @embedFile("logo_green.png");

/// A utility for interacting app icons with SDL3.
pub const AppIcon = struct {
    const Self = @This();

    app_icon_surface_blue: *imguiz.SDL_Surface,
    app_icon_surface_red: *imguiz.SDL_Surface,
    app_icon_surface_green: *imguiz.SDL_Surface,

    pub fn init() Self {
        return .{
            .app_icon_surface_blue = imguiz.SDL_LoadPNG_IO(
                imguiz.SDL_IOFromConstMem(APP_ICON_BLUE.ptr, APP_ICON_BLUE.len).?,
                true,
            ).?,
            .app_icon_surface_red = imguiz.SDL_LoadPNG_IO(
                imguiz.SDL_IOFromConstMem(APP_ICON_RED.ptr, APP_ICON_RED.len).?,
                true,
            ).?,
            .app_icon_surface_green = imguiz.SDL_LoadPNG_IO(
                imguiz.SDL_IOFromConstMem(APP_ICON_GREEN.ptr, APP_ICON_GREEN.len).?,
                true,
            ).?,
        };
    }

    pub fn deinit(self: *Self) void {
        imguiz.SDL_DestroySurface(self.app_icon_surface_blue);
        imguiz.SDL_DestroySurface(self.app_icon_surface_red);
        imguiz.SDL_DestroySurface(self.app_icon_surface_green);
    }
};
