const std = @import("std");

pub fn build_linux_app_image(
    b: *std.Build,
    linux_install_step: *std.Build.Step,
) *std.Build.Step {
    const appimage_step = b.step("appimage", "Build Linux AppImage");

    const cmd = b.addSystemCommand(&.{ "bash", "-lc" });
    cmd.addFileContentArg2(b.path("build/build_app_image.sh"), .{});

    cmd.step.dependOn(linux_install_step);
    appimage_step.dependOn(&cmd.step);

    return appimage_step;
}
