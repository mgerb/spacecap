//// Various platform specific setup/teardown.

const Util = @import("../util.zig");

pub const PlatformCaptureSetup = if (Util.isLinux()) struct {
    const pw = @import("pipewire").c;

    pub fn init() void {
        pw.pw_init(null, null);
    }
    pub fn deinit() void {
        pw.pw_deinit();
    }
} else struct {
    pub fn init() void {}
    pub fn deinit() void {}
};
