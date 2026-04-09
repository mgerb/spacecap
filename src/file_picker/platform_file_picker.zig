const Util = @import("../util.zig");

pub const PlatformFilePicker = if (Util.is_linux())
    @import("./linux/xdg_desktop_portal_file_picker.zig").XdgDesktopPortalFilePicker
else
    @import("./windows/windows_file_picker.zig").WindowsFilePicker;
