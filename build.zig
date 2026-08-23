const std = @import("std");
const ffmpeg_build_util = @import("build/ffmpeg_build.zig");
const version = @import("build/version.zig");
const build_linux_app_image = @import("./build/app_image.zig").build_linux_app_image;

const EXE_NAME = "spacecap";
const PackageVersion = version.PackageVersion;

// TODO: There are still some issues with the Zig backend. Use LLMV for now...
const USE_LLVM = true;

fn compile_shader(
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

fn add_shared_dependencies(
    allocator: std.mem.Allocator,
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    try compile_shader(allocator, b, exe, "random.frag", "random_frag_shader");
    try compile_shader(allocator, b, exe, "random.vert", "random_vert_shader");
    try compile_shader(allocator, b, exe, "bgr-ycbcr-shader-2plane.comp", "bgr-ycbcr-shader-2plane");

    inline for (.{ "logo_blue.png", "logo_red.png", "logo_green.png" }) |logo_file| {
        exe.root_module.addAnonymousImport(logo_file, .{
            .root_source_file = b.path("packaging/" ++ logo_file),
        });
    }

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
    exe.root_module.addIncludePath(vulkan_headers.path(""));

    // NOTE: SDL3 is statically linked by imguiz.
    const imguiz = b.dependency("imguiz", .{
        .target = target,
        .optimize = optimize,
        .freetype = true,
    }).module("imguiz");
    exe.root_module.addImport("imguiz", imguiz);
}

fn add_linux_dependencies(
    allocator: std.mem.Allocator,
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    _ = allocator;
    const pipewire = b.dependency("pipewire", .{
        .optimize = optimize,
        .target = target,
    });

    // For Zig projects, add the `pipewire` module.
    exe.root_module.addImport("pipewire", pipewire.module("pipewire"));

    const libportal = b.dependency("libportal_zig", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("libportal", libportal.module("libportal"));
    exe.root_module.addObjectFile(libportal.namedLazyPath("portal"));

    // Vulkan is linked directly, because it is required that the
    // system has the libs installed.
    exe.root_module.linkSystemLibrary("vulkan", .{});

    ffmpeg_build_util.build_linux(b, exe, target, optimize);

    const linux_c = b.addTranslateC(.{
        .root_source_file = b.path("src/common/linux/linux_c.h"),
        .target = target,
        .optimize = optimize,
    });
    linux_c.linkSystemLibrary("wayland-client", .{});
    exe.root_module.addImport("linux_c", linux_c.createModule());
}

fn add_windows_dependencies(
    allocator: std.mem.Allocator,
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    _ = allocator;
    ffmpeg_build_util.build_windows(b, exe, target, optimize);
    const vulkan_sdk_path_windows = b.graph.environ_map.get("VULKAN_SDK_PATH_WINDOWS").?;
    exe.root_module.addLibraryPath(.{ .cwd_relative = vulkan_sdk_path_windows });

    exe.root_module.linkSystemLibrary("vulkan-1", .{});
}

/// NOTE: This is not used anymore. We are statically linking everything we can
/// and it is not necessary. Keeping it around in case we need it for Windows
/// things.
///
/// Install a dynamic library in the <target>/lib directory
/// e.g. zig-out/linux/lib/SDL3.so
///
/// Lib name should be the name of the lib without extensions
/// e.g. avformat NOT libavformat.so
fn install_and_link_system_library(args: struct {
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

fn build_windows(
    allocator: std.mem.Allocator,
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    package_version: PackageVersion,
    options: *std.Build.Step.Options,
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
    module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = EXE_NAME,
        .root_module = module,
        .version = package_version.semantic_version,
        .use_llvm = USE_LLVM,
    });

    try add_shared_dependencies(allocator, b, exe, target, optimize);
    try add_windows_dependencies(allocator, b, exe, target, optimize);

    const install_step = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "windows" } },
    });
    b.getInstallStep().dependOn(&install_step.step);
}

fn build_linux(
    allocator: std.mem.Allocator,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    nix: bool,
    package_version: PackageVersion,
    options: *std.Build.Step.Options,
) !*std.Build.Step {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = EXE_NAME,
        .root_module = module,
        .version = package_version.semantic_version,
        .use_llvm = USE_LLVM,
    });

    if (!nix) {
        // This prevents linker errors when building for generic Linux target on NixOS.
        exe.linker_allow_shlib_undefined = true;
        // NixOS can't run dynamically linked executables, so there
        // is no need to change the rpath.
        exe.root_module.addRPathSpecial("$ORIGIN/lib");
    }

    try add_shared_dependencies(allocator, b, exe, target, optimize);
    try add_linux_dependencies(allocator, b, exe, target, optimize);

    const install_step = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "linux" } },
    });
    b.getInstallStep().dependOn(&install_step.step);

    const run_cmd = b.addRunFile(b.graph.path(.install_prefix, "linux/" ++ EXE_NAME));
    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    return &install_step.step;
}

fn build_unit_tests(
    allocator: std.mem.Allocator,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
) !void {
    const unit_test_files = [_][]const u8{
        "./src/main.zig",
    };

    const test_step = b.step("test", "Run unit tests");

    for (unit_test_files) |f| {
        const module = b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        module.addOptions("build_options", options);
        const exe = b.addTest(.{
            .root_module = module,
            .test_runner = .{ .path = b.path("./src/test_runner.zig"), .mode = .simple },
            .use_llvm = USE_LLVM,
        });

        try add_shared_dependencies(allocator, b, exe, target, optimize);
        try add_linux_dependencies(allocator, b, exe, target, optimize);

        const run_exe_unit_tests = b.addRunArtifact(exe);

        // Similar to creating the run step earlier, this exposes a `test` step to
        // the `zig build --help` menu, providing a way for the user to request
        // running the unit tests.
        test_step.dependOn(&run_exe_unit_tests.step);
    }
}

// NOTE: build only works on linux for now
pub fn build(b: *std.Build) !void {
    const allocator = b.allocator;

    // Build Options
    const nix_option = b.option(bool, "nix", "If on NixOS, use this flag to run") orelse false;
    const appimage_option = b.option(bool, "appimage", "Build Linux AppImage after install") orelse false;
    const release_version_option = b.option(bool, "release-version", "Build the stable Spacecap version from build.zig.zon instead of a git-derived dev version.") orelse false;
    const ignore_version_check = b.option(
        bool,
        "ignore-version-check",
        \\Ignore version check based on git tags. By default, Spacecap compares the latest git tag to the version in
        \\build.zig.zon. It will fail the build if they match. This is done so that we don't accidentally build pre-release
        \\builds for a version that has already been released. This option should only be used on the automated release build.
        ,
    ) orelse false;

    var package_version = try version.get_package_version(b, allocator, ignore_version_check);
    defer package_version.deinit();

    const resolved_version = if (release_version_option)
        package_version.release_version
    else
        package_version.nightly_version;

    const options = b.addOptions();
    options.addOption([]const u8, "version", resolved_version);

    if (appimage_option and nix_option == true) {
        std.log.err("AppImage builds require generic linux target. Run without -Dnix.", .{});
        return error.InvalidBuildConfig;
    }

    const optimize = b.standardOptimizeOption(.{});
    if (appimage_option and optimize == .debug) {
        std.log.err("AppImage builds require a release optimize mode. Use -Doptimize=ReleaseSafe, -Doptimize=ReleaseFast, or -Doptimize=ReleaseSmall.", .{});
        return error.InvalidBuildConfig;
    }

    try build_windows(
        allocator,
        b,
        optimize,
        package_version,
        options,
    );

    const linux_target = if (nix_option == true) b.standardTargetOptions(.{}) else b.resolveTargetQuery(.{
        .os_tag = .linux,
        .abi = .gnu,
        .cpu_arch = .x86_64,
    });

    const linux_install_step = try build_linux(
        allocator,
        b,
        linux_target,
        optimize,
        nix_option,
        package_version,
        options,
    );

    if (appimage_option) {
        const appimage_step = build_linux_app_image(b, linux_install_step);
        b.getInstallStep().dependOn(appimage_step);
    }

    try build_unit_tests(
        allocator,
        b,
        linux_target,
        optimize,
        options,
    );
}
