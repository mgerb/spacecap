const util = @import("../util.zig");
const std = @import("std");

pub const CaptureSourceType = enum { window, desktop };

pub const Capture =
    if (util.isWindows())
        @import("./windows/capture_windows.zig").Capture
    else
        @import("./linux/capture_linux.zig").Capture;
