const std = @import("std");

pub fn build_linux(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    build_for_target(
        b,
        exe,
        target,
        optimize,
        "linux",
        "ffmpeg-linux",
    );

    // Link Linux specific libs here.
    exe.root_module.linkSystemLibrary("zlib", .{});
}

pub fn build_windows(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    build_for_target(
        b,
        exe,
        target,
        optimize,
        "windows",
        "ffmpeg-windows",
    );

    // Link Windows specific libs here.
    exe.root_module.linkSystemLibrary("bcrypt", .{});
}

fn build_for_target(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    output_dir_name: []const u8,
) void {
    // ----------------------------------------------------------------------------
    // Build FFmpeg.
    // ----------------------------------------------------------------------------
    const ffmpeg = b.dependency("ffmpeg", .{});
    const build_ffmpeg_step = b.addSystemCommand(&.{"bash"});
    build_ffmpeg_step.addFileArg(b.path("build/ffmpeg_build.sh"));
    build_ffmpeg_step.addArg(name);
    const ffmpeg_output = build_ffmpeg_step.addOutputDirectoryArg2(output_dir_name, .{
        .make_absolute = true,
    });
    build_ffmpeg_step.addDirectoryArg2(ffmpeg.path(""), .{});
    build_ffmpeg_step.expectExitCode(0);
    build_ffmpeg_step.setName(output_dir_name);
    exe.step.dependOn(&build_ffmpeg_step.step);

    const include_dir = ffmpeg_output.path(b, "install/include");
    const lib_dir = ffmpeg_output.path(b, "install/lib");

    // ----------------------------------------------------------------------------
    // Add bindings.
    // ----------------------------------------------------------------------------
    const ffmpeg_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ffmpeg/ffmpeg_c.h"),
        .target = target,
        .optimize = optimize,
    });
    ffmpeg_c.addIncludePath(include_dir);
    exe.root_module.addImport("ffmpeg_c", ffmpeg_c.createModule());

    // ----------------------------------------------------------------------------
    // Link libraries.
    // ----------------------------------------------------------------------------
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
