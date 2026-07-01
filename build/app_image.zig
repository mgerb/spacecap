const std = @import("std");

pub fn build_linux_app_image(
    b: *std.Build,
    allocator: std.mem.Allocator,
    linux_install_step: *std.Build.Step,
) *std.Build.Step {
    const appimage_step = b.step("appimage", "Build Linux AppImage");

    const buffer = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "./build/build_app_image.sh",
        allocator,
        .limited(1024 * 1024),
    ) catch |err| {
        @panic(@errorName(err));
    };
    defer allocator.free(buffer);

    const cmd = b.addSystemCommand(&.{ "bash", "-lc", buffer });

    cmd.step.dependOn(linux_install_step);
    appimage_step.dependOn(&cmd.step);

    return appimage_step;
}
