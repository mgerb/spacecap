const Util = @import("../util.zig");

/// Any type of platform specific app init logic should go in here.
/// e.g. On Linux, register the app name over dbus.
pub const PlatformAppRegistration = if (Util.is_linux())
    @import("./linux/xdg_desktop_portal_app_registration.zig").XdgDesktopPortalAppRegistration
else
    struct {
        pub fn init() !@This() {
            return .{};
        }

        pub fn deinit(_: *@This()) void {}
    };
