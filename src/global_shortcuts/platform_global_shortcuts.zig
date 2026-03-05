const Util = @import("../util.zig");

pub const PlatformGlobalShortcuts = if (Util.isLinux())
    @import("./linux/xdg_desktop_portal_global_shortcuts.zig").XdgDesktopPortalGlobalShortcuts
else
    @import("./windows/windows_global_shortcuts.zig").WindowsGlobalShortcuts;
