const std = @import("std");

pub const FfmpegBuild = struct {
    step: *std.Build.Step,
    /// Directory will contain the generated ffmpeg headers.
    include_dir: std.Build.LazyPath,
    /// Directory will contain the static libraries.
    lib_dir: std.Build.LazyPath,
};

fn build_for_target(
    b: *std.Build,
    target: []const u8,
    build_dir_name: []const u8,
    install_dir_name: []const u8,
) FfmpegBuild {
    const ffmpeg = b.dependency("ffmpeg", .{});
    const build_ffmpeg_step = b.addSystemCommand(&.{"bash"});
    build_ffmpeg_step.addFileArg(b.path("build/ffmpeg_build.sh"));
    build_ffmpeg_step.addArg(target);
    _ = build_ffmpeg_step.addOutputDirectoryArg(build_dir_name);
    const ffmpeg_install_prefix = build_ffmpeg_step.addOutputDirectoryArg(install_dir_name);
    build_ffmpeg_step.addArg(ffmpeg.path("").getPath(b));
    build_ffmpeg_step.expectExitCode(0);
    build_ffmpeg_step.setName(build_dir_name);

    return .{
        .step = &build_ffmpeg_step.step,
        .include_dir = ffmpeg_install_prefix.path(b, "include"),
        .lib_dir = ffmpeg_install_prefix.path(b, "lib"),
    };
}

pub fn build_linux(b: *std.Build) FfmpegBuild {
    return build_for_target(
        b,
        "linux",
        "ffmpeg-build",
        "ffmpeg-install",
    );
}

pub fn build_windows(b: *std.Build) FfmpegBuild {
    return build_for_target(
        b,
        "windows",
        "ffmpeg-build-windows",
        "ffmpeg-install-windows",
    );
}

pub fn link_libs(exe: *std.Build.Step.Compile, ffmpeg_build: FfmpegBuild) void {
    exe.step.dependOn(ffmpeg_build.step);
    exe.addIncludePath(ffmpeg_build.include_dir);
    exe.addLibraryPath(ffmpeg_build.lib_dir);
    exe.root_module.linkSystemLibrary("avformat", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("avcodec", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("avdevice", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("avfilter", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("avutil", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("swresample", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("swscale", .{ .preferred_link_mode = .static });
}
