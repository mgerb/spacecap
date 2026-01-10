const std = @import("std");

pub fn isWindows() bool {
    return @import("builtin").os.tag == .windows;
}

pub fn isLinux() bool {
    return @import("builtin").os.tag == .linux;
}

pub fn printElapsed(start_time: i128, prefix: []const u8) void {
    const end = std.time.nanoTimestamp();
    const total_time = @divFloor(end - start_time, @as(i128, @intCast(std.time.ns_per_ms)));
    std.debug.print("[{s}] time elapsed {}ms\n", .{ prefix, total_time });
}

/// Write bgrx data to a .bmp file - used for testing
pub fn write_bmp_bgrx(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    width: u32,
    height: u32,
    bgrx_data: []const u8, // expected to be width * height * 4
) !void {
    const file = try std.fs.cwd().createFile(file_name, .{});
    defer file.close();

    const row_bytes = width * 4;
    const pad_bytes: u8 = @intCast((4 - (row_bytes % 4)) % 4);
    const padded_row_bytes = row_bytes + pad_bytes;

    const pixel_data_size = padded_row_bytes * height;
    const file_header_size = 14;
    const info_header_size = 40;
    const file_size = file_header_size + info_header_size + pixel_data_size;

    var writer = file.writer(&.{});

    // BITMAPFILEHEADER (14 bytes)
    try writer.interface.writeAll(&[_]u8{
        'B',                                'M', // Signature
        @intCast(file_size & 0xFF),         @intCast((file_size >> 8) & 0xFF),
        @intCast((file_size >> 16) & 0xFF), @intCast((file_size >> 24) & 0xFF),
        0, 0, 0, 0, // Reserved
        file_header_size + info_header_size, 0, 0, 0, // Offset to pixel data
    });

    // BITMAPINFOHEADER (40 bytes)
    try writer.interface.writeAll(&[_]u8{
        40,                      0,                              0,                               0, // Header size
        @intCast(width & 0xFF),  @intCast((width >> 8) & 0xFF),  @intCast((width >> 16) & 0xFF),  @intCast((width >> 24) & 0xFF),
        @intCast(height & 0xFF), @intCast((height >> 8) & 0xFF), @intCast((height >> 16) & 0xFF), @intCast((height >> 24) & 0xFF),
        1, 0, // Planes
        32, 0, // Bits per pixel
        0, 0, 0, 0, // Compression (none)
        0, 0, 0, 0, // Image size (can be zero for BI_RGB)
        0, 0, 0, 0, // X pixels per meter
        0, 0, 0, 0, // Y pixels per meter
        0, 0, 0, 0, // Colors used
        0, 0, 0, 0, // Important colors
    });

    // Pixel data (bottom-up, each row padded to 4 bytes)
    var row_buf = try allocator.alloc(u8, padded_row_bytes);
    defer allocator.free(row_buf);

    var row: usize = 0;
    while (row < height) : (row += 1) {
        const src_row_index = (height - 1 - row) * row_bytes;
        std.mem.copyForwards(u8, row_buf[0..row_bytes], bgrx_data[src_row_index .. src_row_index + row_bytes]);

        if (pad_bytes > 0) {
            @memset(row_buf[row_bytes..padded_row_bytes], 0);
        }

        try writer.interface.writeAll(row_buf);
    }
}

pub fn checkFd(fd: i64) !void {
    var buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/proc/self/fd/{}", .{fd});
    var target_buf: [4096]u8 = undefined;
    const n = try std.fs.readLinkAbsolute(path, &target_buf);
    const target = target_buf[0..n.len];

    std.debug.print("FD {} points to: {s}\n", .{ fd, target });
}

/// Returns the platform-specific application data directory.
/// For example:
/// - Windows: %APPDATA%\spacecap
/// - Linux: $XDG_CONFIG_HOME/spacecap or $HOME/.config/spacecap
/// The returned path is owned by the caller and must be freed.
/// This function will create the directory if it does not exist.
pub fn getAppDataDir(allocator: std.mem.Allocator) ![]u8 {
    // TODO: test on windows
    const base_dir: []u8 = if (@import("builtin").os.tag == .windows) blk: {
        // On Windows, use %APPDATA%
        break :blk try std.process.getEnvVarOwned(allocator, "APPDATA");
    } else if (@import("builtin").os.tag == .linux) blk: {
        // On Linux, use $XDG_CONFIG_HOME or $HOME/.config
        if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg_config_home| {
            break :blk xdg_config_home;
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                const home = try std.process.getEnvVarOwned(allocator, "HOME");
                defer allocator.free(home);
                break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
            },
            else => return err,
        }
    } else {
        @compileError("Unsupported OS");
    };
    defer allocator.free(base_dir);

    const app_config_dir = try std.fs.path.join(allocator, &.{ base_dir, "spacecap" });

    // Ensure the directory exists
    std.fs.makeDirAbsolute(app_config_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    return app_config_dir;
}
