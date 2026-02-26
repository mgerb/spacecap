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
    const sdl = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
    });
    exe.linkLibrary(sdl.artifact("SDL3"));

    // imguiz
    const imguiz = b.dependency("imguiz", .{}).module("imguiz");
    exe.root_module.addImport("imguiz", imguiz);

    // zigrc
    const zigrc = b.dependency("zigrc", .{});
    exe.root_module.addImport("zigrc", zigrc.module("zigrc"));

    // ffmpeg headers are shared across platforms; libs are platform-specific.
    const ffmpeg = b.dependency("ffmpeg", .{});
    exe.addIncludePath(ffmpeg.path(""));
}

const FfmpegBuild = struct {
    step: *std.Build.Step,
    /// Directory will contain the static libraries.
    lib_dir: std.Build.LazyPath,
};

// Build ffmpeg static libraries.
// NOTE: If any new ffmpeg functionality is added, then features will
// need to be enabled here.
fn build_ffmpeg(b: *std.Build) FfmpegBuild {
    const ffmpeg = b.dependency("ffmpeg", .{});
    const build_ffmpeg_step = b.addSystemCommand(&.{
        "bash",
        "-lc",
        \\set -euo pipefail
        \\./configure \
        \\  --prefix="$1" \
        \\  --disable-all \
        \\  --disable-debug \
        \\  --disable-autodetect \
        \\  --disable-doc \
        \\  --disable-network \
        \\  --disable-programs \
        \\  --disable-shared \
        \\  --enable-avutil \
        \\  --enable-avcodec \
        \\  --enable-avformat \
        \\  --enable-avdevice \
        \\  --enable-avfilter \
        \\  --enable-swresample \
        \\  --enable-swscale \
        \\  --enable-small \
        \\  --disable-runtime-cpudetect \
        \\  --enable-protocol=file \
        \\  --enable-muxer=mov,mp4,wav \
        \\  --enable-encoder=aac,pcm_f32le
        \\make -j
        \\make install
        ,
        "ffmpeg-build",
    });
    build_ffmpeg_step.setCwd(ffmpeg.path(""));
    const ffmpeg_install_prefix = build_ffmpeg_step.addOutputDirectoryArg("ffmpeg-install");
    build_ffmpeg_step.expectExitCode(0);

    return .{
        .step = &build_ffmpeg_step.step,
        .lib_dir = ffmpeg_install_prefix.path(b, "lib"),
    };
}

fn addLinuxDependencies(
    allocator: std.mem.Allocator,
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ffmpeg_build: FfmpegBuild,
) !void {
    _ = allocator;
    const pipewire = b.dependency("pipewire", .{
        .optimize = optimize,
        .target = target,
    });

    // For Zig projects, add the `pipewire` module.
    exe.root_module.addImport("pipewire", pipewire.module("pipewire"));

    const gobject = b.dependency("gobject", .{});
    exe.root_module.addImport("glib", gobject.module("glib2"));
    exe.root_module.addImport("gio", gobject.module("gio2"));
    exe.root_module.addImport("gobject", gobject.module("gobject2"));

    exe.root_module.linkSystemLibrary("glib-2.0", .{});
    exe.root_module.linkSystemLibrary("gio-2.0", .{});
    exe.root_module.linkSystemLibrary("gobject-2.0", .{});
    exe.root_module.linkSystemLibrary("portal", .{});

    // Vulkan is linked directly, because it is required that the
    // system has the libs installed.
    exe.root_module.linkSystemLibrary("vulkan", .{});

    exe.step.dependOn(ffmpeg_build.step);
    exe.addLibraryPath(ffmpeg_build.lib_dir);
    exe.root_module.linkSystemLibrary("avformat", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("avcodec", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("avutil", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("swresample", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("avdevice", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("avfilter", .{ .preferred_link_mode = .static });
    exe.root_module.linkSystemLibrary("swscale", .{ .preferred_link_mode = .static });
}

/// Install a dynamic library in the <target>/lib directory
/// e.g. zig-out/linux/lib/SDL3.so
///
/// Lib name should be the name of the lib without extensions
/// e.g. avformat NOT libavformat.so
fn installAndLinkSystemLibrary(args: struct {
    allocator: std.mem.Allocator,
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    source_dir: []const u8,
    lib_name: []const u8,
    target: enum { linux, windows },
    file_name_override: ?[]const u8 = null,
    link_options: std.Build.Module.LinkSystemLibraryOptions = .{},
}) !void {
    const file_name = args.file_name_override orelse switch (args.target) {
        .linux => try std.fmt.allocPrint(args.allocator, "lib{s}.so", .{args.lib_name}),
        .windows => try std.fmt.allocPrint(args.allocator, "{s}.dll", .{args.lib_name}),
    };
    defer {
        if (args.file_name_override == null) {
            args.allocator.free(file_name);
        }
    }

    const full_file_path = try std.fmt.allocPrint(args.allocator, "{s}/{s}", .{ args.source_dir, file_name });
    defer args.allocator.free(full_file_path);

    const target_name = switch (args.target) {
        .linux => "linux/lib",
        .windows => "windows/lib",
    };

    const dest_path = try std.fmt.allocPrint(args.allocator, "{s}/{s}", .{ target_name, file_name });
    defer args.allocator.free(dest_path);

    const step = args.b.addInstallFile(.{ .cwd_relative = full_file_path }, dest_path);
    args.exe.step.dependOn(&step.step);

    args.exe.root_module.linkSystemLibrary(args.lib_name, args.link_options);
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

    try installAndLinkSystemLibrary(.{
        .allocator = allocator,
        .b = b,
        .exe = exe,
        .source_dir = std.posix.getenv("VULKAN_SDK_PATH_WINDOWS").?,
        .lib_name = "vulkan-1",
        .target = .windows,
    });

    // All windows machines should be able to link to this by default
    exe.linkSystemLibrary("gdi32");

    const zigwin32 = b.dependency("zigwin32", .{});
    exe.root_module.addImport("win32", zigwin32.module("win32"));

    // ffmpeg
    const ffmpeg_windows = b.dependency("ffmpeg_windows", .{});
    exe.addLibraryPath(ffmpeg_windows.path("bin"));

    const ffmpeg_path = ffmpeg_windows.path("bin").getPath(b);
    try installAndLinkSystemLibrary(.{
        .allocator = allocator,
        .b = b,
        .exe = exe,
        .source_dir = ffmpeg_path,
        .lib_name = "avformat-62",
        .target = .windows,
    });
    try installAndLinkSystemLibrary(.{
        .allocator = allocator,
        .b = b,
        .exe = exe,
        .source_dir = ffmpeg_path,
        .lib_name = "avcodec-62",
        .target = .windows,
    });
    try installAndLinkSystemLibrary(.{
        .allocator = allocator,
        .b = b,
        .exe = exe,
        .source_dir = ffmpeg_path,
        .lib_name = "avdevice-62",
        .target = .windows,
    });
    try installAndLinkSystemLibrary(.{
        .allocator = allocator,
        .b = b,
        .exe = exe,
        .source_dir = ffmpeg_path,
        .lib_name = "avfilter-11",
        .target = .windows,
    });
    try installAndLinkSystemLibrary(.{
        .allocator = allocator,
        .b = b,
        .exe = exe,
        .source_dir = ffmpeg_path,
        .lib_name = "avutil-60",
        .target = .windows,
    });

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
    nix: bool,
    ffmpeg_build: FfmpegBuild,
) !*std.Build.Step {
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

    if (!nix) {
        // This prevents linker errors when building for generic Linux target on NixOS.
        exe.linker_allow_shlib_undefined = true;
        // NixOS can't run dynamically linked executables, so there
        // is no need to change the rpath.
        exe.root_module.addRPathSpecial("$ORIGIN/lib");
    }

    try addSharedDependencies(allocator, b, exe, target, optimize);
    try addLinuxDependencies(allocator, b, exe, target, optimize, ffmpeg_build);

    const install_step = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "linux" } },
    });
    b.getInstallStep().dependOn(&install_step.step);

    const run_cmd = b.addSystemCommand(&.{
        b.getInstallPath(.prefix, "linux/" ++ EXE_NAME),
    });
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    return &install_step.step;
}

fn buildLinuxAppImage(
    b: *std.Build,
    allocator: std.mem.Allocator,
    linux_install_step: *std.Build.Step,
) *std.Build.Step {
    const appimage_step = b.step("appimage", "Build Linux AppImage");

    const file = std.fs.cwd().openFile("./build_app_image.sh", .{ .mode = .read_only }) catch unreachable;
    defer file.close();
    const stat = file.stat() catch unreachable;

    var reader = file.reader(&.{});
    const buffer = reader.interface.readAlloc(allocator, stat.size) catch unreachable;
    defer allocator.free(buffer);

    const cmd = b.addSystemCommand(&.{ "bash", "-lc", buffer });

    cmd.step.dependOn(linux_install_step);
    appimage_step.dependOn(&cmd.step);

    return appimage_step;
}

fn buildUnitTestsDefault(
    allocator: std.mem.Allocator,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ffmpeg_build: FfmpegBuild,
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
            // Keep test linking behavior aligned with Linux executable builds.
            .use_llvm = true,
        });

        exe.linkLibC();

        try addSharedDependencies(allocator, b, exe, target, optimize);
        try addLinuxDependencies(allocator, b, exe, target, optimize, ffmpeg_build);

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

    const nix = b.option(bool, "nix", "If on NixOS, use this flag to run") orelse false;
    const appimage = b.option(bool, "appimage", "Build Linux AppImage after install") orelse false;

    if (appimage and nix == true) {
        std.log.err("AppImage builds require generic linux target. Run without -Dnix.", .{});
        return error.InvalidBuildConfig;
    }

    const optimize = b.standardOptimizeOption(.{});
    if (appimage and optimize == .Debug) {
        std.log.err("AppImage builds require a release optimize mode. Use -Doptimize=ReleaseFast, -Doptimize=ReleaseSafe, or -Doptimize=ReleaseSmall.", .{});
        return error.InvalidBuildConfig;
    }

    try buildWindows(allocator, b, optimize);

    const ffmpeg_build = build_ffmpeg(b);

    const linux_target = if (nix == true) b.standardTargetOptions(.{}) else b.resolveTargetQuery(.{
        .os_tag = .linux,
        .abi = .gnu,
        .cpu_arch = .x86_64,
    });

    const linux_install_step = try buildLinux(
        allocator,
        b,
        linux_target,
        optimize,
        nix,
        ffmpeg_build,
    );
    const appimage_step = buildLinuxAppImage(b, allocator, linux_install_step);

    if (appimage) {
        b.getInstallStep().dependOn(appimage_step);
    }

    try buildUnitTestsDefault(allocator, b, linux_target, optimize, ffmpeg_build);
}
