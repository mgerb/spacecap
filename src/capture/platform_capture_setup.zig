//// Various platform specific setup/teardown.

const Util = @import("../util.zig");

pub const PlatformCaptureSetup = if (Util.isLinux()) struct {
    const c = @import("./video/linux/pipewire/pipewire_include.zig").c;

    pub fn init() void {
        c.pw_init(null, null);
    }
    pub fn deinit() void {
        c.pw_deinit();
    }
} else struct {
    pub fn init() void {}
    pub fn deinit() void {}
};
