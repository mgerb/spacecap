//! Wayland does not expose an API to check if windows
//! in are minimized, hidden, or generally waiting to present
//! (https://wiki.libsdl.org/SDL3/README-wayland#minimizerestored-window-events-are-not-sent-and-the-sdl_window_minimized-flag-is-not-set).
//! This module exposes Wayland specific methods to register a frame callback,
//! which enables the consumer to check if a frame is ready. The consumer
//! can skip render/present if a frame is not ready.

const std = @import("std");
const imguiz = @import("imguiz").imguiz;
const util = @import("../util.zig");

pub const WaylandPresentGate = if (util.is_linux()) LinuxWaylandPresentGate else StubWaylandPresentGate;

const LinuxWaylandPresentGate = struct {
    const Self = @This();
    const c = @cImport({
        @cInclude("wayland-client-core.h");
        @cInclude("wayland-client-protocol.h");
    });
    const log = std.log.scoped(.wayland_present_gate);

    const frame_listener = c.struct_wl_callback_listener{
        .done = frame_done,
    };

    display: ?*c.struct_wl_display = null,
    surface: ?*c.struct_wl_surface = null,
    frame_callback: ?*c.struct_wl_callback = null,

    /// Initialize display/surface pointers. Will return null on anything
    /// other than Wayland.
    pub fn init(window: ?*imguiz.struct_SDL_Window) ?Self {
        const current_video_driver = imguiz.SDL_GetCurrentVideoDriver() orelse return null;
        if (!std.mem.eql(u8, std.mem.span(current_video_driver), "wayland")) {
            log.debug("[init] current video driver is not using wayland", .{});
            return null;
        }

        const window_properties = imguiz.SDL_GetWindowProperties(window);
        if (window_properties == 0) {
            log.warn("[init] SDL_GetWindowProperties returned 0 for a Wayland window", .{});
            return null;
        }

        const display_ptr = imguiz.SDL_GetPointerProperty(window_properties, imguiz.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
        const surface_ptr = imguiz.SDL_GetPointerProperty(window_properties, imguiz.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null);
        if (display_ptr == null or surface_ptr == null) {
            log.warn(
                "[init] missing Wayland window properties: display_present={} surface_present={}",
                .{ display_ptr != null, surface_ptr != null },
            );
            return null;
        }

        log.info("[init] enabled wl_surface.frame present gating", .{});
        return .{
            .display = @ptrCast(display_ptr.?),
            .surface = @ptrCast(surface_ptr.?),
        };
    }

    pub fn deinit(self: *Self) void {
        self.cancel_callback();
    }

    /// The frame is ready when we don't have a callback. This _should_ be true
    /// when the window is not minimized or hidden.
    pub fn frame_ready(self: *const Self) bool {
        return self.frame_callback == null;
    }

    /// Dispatches already queued Wayland events so frame callbacks can flip the
    /// gate back to ready when the compositor requests another redraw.
    pub fn dispatch_pending(self: *Self) void {
        if (self.display == null or self.surface == null) {
            return;
        }

        const result = c.wl_display_dispatch_pending(self.display);
        if (result < 0) {
            log.warn("[dispatch_pending] wl_display_dispatch_pending failed: {}", .{result});
        }
    }

    /// Returns false if a frame is not ready. If a frame is ready,
    /// register a frame done callback, then return true.
    pub fn register_present_callback(self: *Self) !bool {
        if (self.display == null or self.surface == null) {
            return true;
        }
        if (!self.frame_ready()) {
            return false;
        }

        const callback = c.wl_surface_frame(self.surface) orelse {
            return error.WaylandSurfaceFrameFailure;
        };
        errdefer c.wl_callback_destroy(callback);

        if (c.wl_callback_add_listener(callback, &frame_listener, self) != 0) {
            return error.WaylandCallbackListenerAddFailure;
        }

        self.frame_callback = callback;
        return true;
    }

    /// Cancels any pending callbacks.
    pub fn cancel_callback(self: *Self) void {
        if (self.frame_callback) |callback| {
            c.wl_callback_destroy(callback);
            self.frame_callback = null;
        }
    }

    fn frame_done(data: ?*anyopaque, callback: ?*c.struct_wl_callback, callback_data: u32) callconv(.c) void {
        _ = callback_data;

        if (callback) |_callback| {
            c.wl_callback_destroy(_callback);
        }

        const self: *Self = @ptrCast(@alignCast(data));
        self.frame_callback = null;
    }
};

const StubWaylandPresentGate = struct {
    const Self = @This();
    pub fn frame_ready(_: *const Self) bool {
        return true;
    }

    /// Non-Wayland targets never create a real gate.
    pub fn init(_: ?*imguiz.struct_SDL_Window) ?Self {
        return null;
    }

    pub fn deinit(_: *Self) void {}

    pub fn dispatch_pending(_: *Self) void {}

    pub fn register_present_callback(_: *Self) !bool {
        return true;
    }

    pub fn cancel_callback(_: *Self) void {}
};
