const util = @import("src/util.zig");
const std = @import("std");

const EXE_NAME = "spacecap";

fn compileShader(
    allocator: std.mem.Allocator,
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    shader: []const u8,
    importName: []const u8,
) !void {
    const vert_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.4",
        "-o",
    });
    const shaderPath = try std.fs.path.join(allocator, &[_][]const u8{ "common", "shaders", shader });
    defer allocator.free(shaderPath);

    const outputFile = vert_cmd.addOutputFileArg(shader);
    vert_cmd.addFileArg(b.path(shaderPath));

    exe.root_module.addAnonymousImport(importName, .{
        .root_source_file = outputFile,
    });
}

fn addSharedDependencies(
    allocator: std.mem.Allocator,
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    _ = target;
    _ = optimize;
    try compileShader(allocator, b, exe, "random.frag", "random_frag_shader");
    try compileShader(allocator, b, exe, "random.vert", "random_vert_shader");
    try compileShader(allocator, b, exe, "bgr-ycbcr-shader-2plane.comp", "bgr-ycbcr-shader-2plane");

    // vulkan
    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan = b.dependency(
        "vulkan_zig",
        .{
            .registry = vulkan_headers.path("registry/vk.xml"),
            .video = vulkan_headers.path("registry/video.xml"),
        },
    ).module("vulkan-zig");
    exe.root_module.addImport("vulkan", vulkan);
    exe.addIncludePath(vulkan_headers.path(""));

    // SDL3
    exe.addIncludePath(.{ .cwd_relative = std.posix.getenv("SDL3_DEV").? });

    // imguiz
    const imguiz = b.dependency("imguiz", .{}).module("imguiz");
    exe.root_module.addImport("imguiz", imguiz);

    // ffmpeg
    // Add ffmpeg headers here. They can be shared cross platform. Libs
    // are added separately because they are platform specific.
    const ffmpeg = b.dependency("ffmpeg", .{});
    const ffmpeg_path = ffmpeg.path("").getPath3(b, null).root_dir.path.?;
    exe.addIncludePath(ffmpeg.path(""));

    // TODO: Make sure this only runs once. Currently during fresh install
    // it runs 3 times - one for each type of build.
    (try std.fs.openDirAbsolute(ffmpeg_path, .{})).access("libavutil/avconfig.h", .{}) catch {
        std.debug.print("configuring ffmpeg... this may take a minute\n", .{});
        const ffmpeg_configure_step = b.addSystemCommand(&.{"./configure"});
        ffmpeg_configure_step.setCwd(ffmpeg.path(""));
        exe.step.dependOn(&ffmpeg_configure_step.step);
    };
}

fn addLinuxDependencies(allocator: std.mem.Allocator, b: *std.Build, exe: *std.Build.Step.Compile) !void {
    // sdl3
    exe.addLibraryPath(.{ .cwd_relative = std.posix.getenv("SDL3").? });
    try installAndLinkSystemLibrary(allocator, b, exe, std.posix.getenv("SDL3").?, "SDL3", .linux, "libSDL3.so.0");

    // xkbcommon
    // NOTE: may not be used actually?
    // exe.addLibraryPath(.{ .cwd_relative = std.posix.getenv("LIBXKBCOMMON").? });
    // try installAndLinkSystemLibrary(allocator, b, exe, std.posix.getenv("LIBXKBCOMMON").?, "xkbcommon", .linux);

    // pipewire headers
    const pipewire_dev = std.posix.getenv("PIPEWIRE_DEV").?;
    const pipewire_pipewire = try std.fmt.allocPrint(allocator, "{s}/pipewire-0.3", .{pipewire_dev});
    defer allocator.free(pipewire_pipewire);
    exe.addIncludePath(.{ .cwd_relative = pipewire_pipewire });

    // pipewire lib
    const pipewire_lib = try std.fmt.allocPrint(allocator, "{s}/lib", .{std.posix.getenv("PIPEWIRE_LIB").?});
    defer allocator.free(pipewire_lib);
    exe.addLibraryPath(.{ .cwd_relative = pipewire_lib });
    try installAndLinkSystemLibrary(allocator, b, exe, pipewire_lib, "pipewire-0.3", .linux, "libpipewire-0.3.so.0");

    // spa
    const pipewire_spa = try std.fmt.allocPrint(allocator, "{s}/spa-0.2", .{pipewire_dev});
    defer allocator.free(pipewire_spa);
    exe.addIncludePath(.{ .cwd_relative = pipewire_spa });
    const pipewire_lib_spa = try std.fmt.allocPrint(allocator, "{s}/lib/spa-0.2", .{std.posix.getenv("PIPEWIRE_LIB").?});
    defer allocator.free(pipewire_lib_spa);
    exe.addLibraryPath(.{ .cwd_relative = pipewire_lib_spa });
    try installAndLinkSystemLibrary(allocator, b, exe, pipewire_lib_spa, "spa", .linux, null);

    // glib
    exe.addLibraryPath(.{ .cwd_relative = std.posix.getenv("GLIB").? });
    exe.addIncludePath(.{ .cwd_relative = std.posix.getenv("GLIB_DEV").? });
    exe.addIncludePath(.{ .cwd_relative = std.posix.getenv("GLIB_OUT").? }); // glibconfig.h
    try installAndLinkSystemLibrary(allocator, b, exe, std.posix.getenv("GLIB").?, "glib-2.0", .linux, "libglib-2.0.so");
    try installAndLinkSystemLibrary(allocator, b, exe, std.posix.getenv("GLIB").?, "gio-2.0", .linux, "libgio-2.0.so");
    try installAndLinkSystemLibrary(allocator, b, exe, std.posix.getenv("GLIB").?, "gobject-2.0", .linux, "libgobject-2.0.so.0");

    const gobject = b.dependency("gobject", .{});
    exe.root_module.addImport("glib", gobject.module("glib2"));
    exe.root_module.addImport("gio", gobject.module("gio2"));
    exe.root_module.addImport("gobject", gobject.module("gobject2"));

    // drm
    const libdrm_dev = std.posix.getenv("LIBDRM_DEV").?;
    const libdrm_libdrm = try std.fmt.allocPrint(allocator, "{s}/libdrm", .{libdrm_dev});
    defer allocator.free(libdrm_libdrm);
    exe.addIncludePath(.{ .cwd_relative = libdrm_dev });
    exe.addIncludePath(.{ .cwd_relative = libdrm_libdrm });
    exe.addLibraryPath(.{ .cwd_relative = std.posix.getenv("LIBDRM").? });
    try installAndLinkSystemLibrary(allocator, b, exe, std.posix.getenv("LIBDRM").?, "drm", .linux, "libdrm.so.2");

    // vulkan
    exe.addLibraryPath(.{ .cwd_relative = std.posix.getenv("VULKAN_SDK_PATH").? });
    try installAndLinkSystemLibrary(allocator, b, exe, std.posix.getenv("VULKAN_SDK_PATH").?, "vulkan", .linux, "libvulkan.so.1");

    // ffmpeg
    const ffmpeg_linux = b.dependency("ffmpeg_linux", .{});
    exe.addLibraryPath(ffmpeg_linux.path("lib"));
    const ffmpeg_path = ffmpeg_linux.path("lib").getPath(b);

    try installAndLinkSystemLibrary(allocator, b, exe, ffmpeg_path, "avformat", .linux, "libavformat.so.61");
    try installAndLinkSystemLibrary(allocator, b, exe, ffmpeg_path, "avcodec", .linux, "libavcodec.so.61");
    try installAndLinkSystemLibrary(allocator, b, exe, ffmpeg_path, "avdevice", .linux, "libavdevice.so.61");
    try installAndLinkSystemLibrary(allocator, b, exe, ffmpeg_path, "avfilter", .linux, "libavfilter.so.10");
    try installAndLinkSystemLibrary(allocator, b, exe, ffmpeg_path, "avutil", .linux, "libavutil.so.59");
    try installAndLinkSystemLibrary(allocator, b, exe, ffmpeg_path, "swresample", .linux, "libswresample.so.5");
}

/// Install a dynamic library in the <target>/lib directory
/// e.g. zig-out/linux/lib/SDL3.so
///
/// Lib name should be the name of the lib without extensions
/// e.g. avformat NOT libavformat.so
fn installAndLinkSystemLibrary(
    allocator: std.mem.Allocator,
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    source_dir: []const u8,
    lib_name: []const u8,
    target: enum { linux, windows },
    file_name_override: ?[]const u8,
) !void {
    const file_name = file_name_override orelse switch (target) {
        .linux => try std.fmt.allocPrint(allocator, "lib{s}.so", .{lib_name}),
        .windows => try std.fmt.allocPrint(allocator, "{s}.dll", .{lib_name}),
    };
    defer {
        if (file_name_override == null) {
            allocator.free(file_name);
        }
    }

    const full_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_dir, file_name });
    defer allocator.free(full_file_path);

    const target_name = switch (target) {
        .linux => "linux/lib",
        .windows => "windows/lib",
    };

    const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ target_name, file_name });
    defer allocator.free(dest_path);

    const step = b.addInstallFile(.{ .cwd_relative = full_file_path }, dest_path);
    exe.step.dependOn(&step.step);

    exe.linkSystemLibrary(lib_name);
}

fn buildWindows(
    allocator: std.mem.Allocator,
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
) !void {
    const target = b.resolveTargetQuery(.{
        .os_tag = .windows,
        .abi = .gnu,
        .cpu_arch = .x86_64,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = EXE_NAME,
        .root_module = module,
    });
    // TODO: seems like rpath is not working
    exe.addRPath(b.path("./lib"));

    try addSharedDependencies(allocator, b, exe, target, optimize);

    exe.addLibraryPath(.{ .cwd_relative = std.posix.getenv("VULKAN_SDK_PATH_WINDOWS").? });
    exe.addLibraryPath(.{ .cwd_relative = std.posix.getenv("SDL3_WINDOWS").? });

    try installAndLinkSystemLibrary(allocator, b, exe, std.posix.getenv("VULKAN_SDK_PATH_WINDOWS").?, "vulkan-1", .windows, null);

    // All windows machines should be able to link to this by default
    exe.linkSystemLibrary("gdi32");

    try installAndLinkSystemLibrary(allocator, b, exe, std.posix.getenv("SDL3_WINDOWS").?, "SDL3", .windows, null);

    const zigwin32 = b.dependency("zigwin32", .{});
    exe.root_module.addImport("win32", zigwin32.module("win32"));

    // ffmpeg
    const ffmpeg_windows = b.dependency("ffmpeg_windows", .{});
    exe.addLibraryPath(ffmpeg_windows.path("bin"));

    const ffmpeg_path = ffmpeg_windows.path("bin").getPath(b);
    try installAndLinkSystemLibrary(allocator, b, exe, ffmpeg_path, "avformat-61", .windows, null);
    try installAndLinkSystemLibrary(allocator, b, exe, ffmpeg_path, "avcodec-61", .windows, null);
    try installAndLinkSystemLibrary(allocator, b, exe, ffmpeg_path, "avdevice-61", .windows, null);
    try installAndLinkSystemLibrary(allocator, b, exe, ffmpeg_path, "avfilter-10", .windows, null);
    try installAndLinkSystemLibrary(allocator, b, exe, ffmpeg_path, "avutil-59", .windows, null);

    const install_step = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "windows" } },
    });
    b.getInstallStep().dependOn(&install_step.step);
}

fn buildLinux(
    allocator: std.mem.Allocator,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = EXE_NAME,
        .root_module = module,
        // TODO: There are currently some pointer alignment issues
        // with pipewire using the Zig backend. Just stick to LLVM for now...
        .use_llvm = true,
    });
    exe.addRPath(b.path("./lib"));

    try addSharedDependencies(allocator, b, exe, target, optimize);
    try addLinuxDependencies(allocator, b, exe);

    const install_step = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "linux" } },
    });
    b.getInstallStep().dependOn(&install_step.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn buildUnitTestsDefault(
    allocator: std.mem.Allocator,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const unit_test_files = [_][]const u8{
        "./src/test.zig",
    };

    const test_step = b.step("test", "Run unit tests");

    for (unit_test_files) |f| {
        const root_module = b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
        });
        const exe = b.addTest(.{
            .root_module = root_module,
            .test_runner = .{ .path = b.path("./src/test_runner.zig"), .mode = .simple },
        });

        exe.linkLibC();

        try addSharedDependencies(allocator, b, exe, target, optimize);
        try addLinuxDependencies(allocator, b, exe);

        const run_exe_unit_tests = b.addRunArtifact(exe);

        // Similar to creating the run step earlier, this exposes a `test` step to
        // the `zig build --help` menu, providing a way for the user to request
        // running the unit tests.
        test_step.dependOn(&run_exe_unit_tests.step);
    }
}

// NOTE: build only works on linux for now
pub fn build(b: *std.Build) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const nix = b.option(bool, "nix", "If on NixOS, use this flag to run");

    const optimize = b.standardOptimizeOption(.{});

    try buildWindows(allocator, b, optimize);

    // TODO: Linux build is currently broken due to llvm linker errors. Check back
    // when switched back to zig linker when it's fixed.
    const target = if (nix == true) b.standardTargetOptions(.{}) else b.resolveTargetQuery(.{
        .os_tag = .linux,
        .abi = .gnu,
        .cpu_arch = .x86_64,
    });

    try buildLinux(allocator, b, target, optimize);
    try buildUnitTestsDefault(allocator, b, target, optimize);
}
