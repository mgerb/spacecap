const Util = @import("../util.zig");

pub const PlatformIpc = if (Util.isLinux())
    @import("./linux/linux_ipc.zig").LinuxIpc
else
    @import("./windows/windows_ipc.zig").WindowsIpc;
