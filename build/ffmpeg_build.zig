const std = @import("std");

pub fn build_linux(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
) void {
    const ffmpeg_build = build_for_target(
        b,
        exe,
        "linux",
        "ffmpeg-build",
        "ffmpeg-install",
    );
    link_libs(exe, ffmpeg_build.include_dir, ffmpeg_build.lib_dir);
    exe.root_module.linkSystemLibrary("zlib", .{});
}

pub fn build_windows(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
) void {
    const ffmpeg_build = build_for_target(
        b,
        exe,
        "windows",
        "ffmpeg-build-windows",
        "ffmpeg-install-windows",
    );
    link_libs(exe, ffmpeg_build.include_dir, ffmpeg_build.lib_dir);
    exe.root_module.linkSystemLibrary("bcrypt", .{});
}

fn build_for_target(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: []const u8,
    build_dir_name: []const u8,
    install_dir_name: []const u8,
) struct { include_dir: std.Build.LazyPath, lib_dir: std.Build.LazyPath } {
    const ffmpeg = b.dependency("ffmpeg", .{});
    const build_ffmpeg_step = b.addSystemCommand(&.{"bash"});
    build_ffmpeg_step.addFileArg(b.path("build/ffmpeg_build.sh"));
    build_ffmpeg_step.addArg(target);
    _ = build_ffmpeg_step.addOutputDirectoryArg(build_dir_name);
    const ffmpeg_install_prefix = build_ffmpeg_step.addOutputDirectoryArg(install_dir_name);
    build_ffmpeg_step.addArg(ffmpeg.path("").getPath(b));
    build_ffmpeg_step.expectExitCode(0);
    build_ffmpeg_step.setName(build_dir_name);
    exe.step.dependOn(&build_ffmpeg_step.step);

    return .{
        .include_dir = ffmpeg_install_prefix.path(b, "include"),
        .lib_dir = ffmpeg_install_prefix.path(b, "lib"),
    };
}

fn link_libs(
    exe: *std.Build.Step.Compile,
    include_dir: std.Build.LazyPath,
    lib_dir: std.Build.LazyPath,
) void {
    exe.root_module.addIncludePath(include_dir);
    exe.root_module.addLibraryPath(lib_dir);
    exe.root_module.linkSystemLibrary("avformat", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("avcodec", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("avdevice", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("avfilter", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("avutil", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("swresample", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("swscale", .{ .preferred_link_mode = .static });
}
