const std = @import("std");
const build_util = @import("./build_util.zig");

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

    // zlib is required for PNG image export
    exe.root_module.linkSystemLibrary("zlib", .{});
}

pub fn build_windows(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
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

    // zlib is required for PNG image export.
    const mingw_zlib_path = b.graph.environ_map.get("MINGW_ZLIB_PATH") orelse
        @panic("MINGW_ZLIB_PATH must be set when building the Windows target");
    exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ mingw_zlib_path, "lib" }) });
    try build_util.install_and_link_system_library(.{
        .allocator = b.allocator,
        .b = b,
        .exe = exe,
        .source_dir = b.pathJoin(&.{ mingw_zlib_path, "bin" }),
        .lib_name = "z.dll",
        .target = .windows,
        .file_name_override = "zlib1.dll",
        .link_options = .{ .use_pkg_config = .no },
    });
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
    // Include Vulkan headers for hardware decoding/encoding.
    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const build_ffmpeg_step = b.addSystemCommand(&.{"bash"});
    build_ffmpeg_step.addFileArg(b.path("build/ffmpeg_build.sh"));
    build_ffmpeg_step.addArg(name);
    const ffmpeg_output = build_ffmpeg_step.addOutputDirectoryArg2(output_dir_name, .{
        .make_absolute = true,
    });
    build_ffmpeg_step.addDirectoryArg2(ffmpeg.path(""), .{});
    build_ffmpeg_step.addDirectoryArg2(vulkan_headers.path(""), .{
        .make_absolute = true,
    });
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
    ffmpeg_c.addIncludePath(vulkan_headers.path("include"));
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
