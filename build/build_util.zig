const std = @import("std");

/// Install a dynamic library in the <target>/lib directory
/// e.g. zig-out/windows/lib/zlib1.dll
///
/// Lib name should be the name of the lib without extensions
/// e.g. avformat NOT libavformat.so
pub fn install_and_link_system_library(args: struct {
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
