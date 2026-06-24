const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.util);
const Env = @import("./env.zig");

pub const DEBUG = @import("builtin").mode == .Debug;
pub var test_app_data_dir: ?[]const u8 = null;

pub fn is_windows() bool {
    return @import("builtin").os.tag == .windows;
}

pub fn is_linux() bool {
    return @import("builtin").os.tag == .linux;
}

pub fn print_elapsed(io: std.Io, start_time: i128, prefix: []const u8) void {
    const end: i128 = @intCast(std.Io.Clock.real.now(io).nanoseconds);
    const total_time = @divFloor(end - start_time, @as(i128, @intCast(std.time.ns_per_ms)));
    log.debug("[{s}] time elapsed {}ms\n", .{ prefix, total_time });
}

pub fn format_duration_label(allocator: std.mem.Allocator, args: struct {
    seconds: f64,
    max: ?u32 = null,
}) ![:0]u8 {
    const input_seconds = @max(args.seconds, 0.0);
    // If max is provided, round seconds up and then take
    // the min of the two. This prevents any flicker on the UI
    // when a number changes from 9.9 to 10.0 for example.
    const total_seconds: u64 = if (args.max) |max_seconds|
        @min(
            @as(u64, @intFromFloat(@ceil(input_seconds))),
            max_seconds,
        )
    else
        @intFromFloat(@trunc(input_seconds));

    const hours = total_seconds / 3600;
    const minutes = (total_seconds % 3600) / 60;
    const seconds = total_seconds % 60;

    if (hours > 0 and minutes > 0 and seconds > 0) {
        return std.fmt.allocPrintSentinel(allocator, "{d}h {d}m {d}s", .{ hours, minutes, seconds }, 0);
    }
    if (hours > 0 and minutes > 0) {
        return std.fmt.allocPrintSentinel(allocator, "{d}h {d}m", .{ hours, minutes }, 0);
    }
    if (hours > 0 and seconds > 0) {
        return std.fmt.allocPrintSentinel(allocator, "{d}h {d}s", .{ hours, seconds }, 0);
    }
    if (hours > 0) {
        return std.fmt.allocPrintSentinel(allocator, "{d}h", .{hours}, 0);
    }
    if (minutes > 0 and seconds > 0) {
        return std.fmt.allocPrintSentinel(allocator, "{d}m {d}s", .{ minutes, seconds }, 0);
    }
    if (minutes > 0) {
        return std.fmt.allocPrintSentinel(allocator, "{d}m", .{minutes}, 0);
    }
    return std.fmt.allocPrintSentinel(allocator, "{d}s", .{seconds}, 0);
}

const TimestampString = [27]u8;
pub fn format_timestamp_utc(timestamp_ms: i64) TimestampString {
    const epoch_ms: u64 = @intCast(@max(timestamp_ms, 0));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = epoch_ms / std.time.ms_per_s };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    var buffer: TimestampString = undefined;
    _ = std.fmt.bufPrint(
        &buffer,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} UTC",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            epoch_ms % std.time.ms_per_s,
        },
    ) catch @panic("std.fmt.bufPrint error");
    return buffer;
}

/// Write bgrx data to a .bmp file - used for testing
pub fn write_bmp_bgrx(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_name: []const u8,
    width: u32,
    height: u32,
    bgrx_data: []const u8, // expected to be width * height * 4
) !void {
    const file = try std.Io.Dir.cwd().createFile(io, file_name, .{});
    defer file.close(io);

    const row_bytes = width * 4;
    const pad_bytes: u8 = @intCast((4 - (row_bytes % 4)) % 4);
    const padded_row_bytes = row_bytes + pad_bytes;

    const pixel_data_size = padded_row_bytes * height;
    const file_header_size = 14;
    const info_header_size = 40;
    const file_size = file_header_size + info_header_size + pixel_data_size;

    var writer_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &writer_buffer);

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

    try writer.interface.flush();
}

pub fn check_fd(fd: i64) !void {
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
pub fn get_app_data_dir(allocator: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error![]u8 {
    if (@import("builtin").is_test) {
        const TEST_APP_DATA_DIR = @import("./test.zig").TEST_APP_DATA_DIR;
        // NOTE: See test.zig for usage.
        assert(TEST_APP_DATA_DIR != null);
        return std.testing.allocator.dupe(u8, TEST_APP_DATA_DIR.?);
    }

    // TODO: Test on Windows.
    const base_dir: ?[]u8 = if (comptime is_windows()) blk: {
        // On Windows, use %APPDATA%
        break :blk Env.get_env_var_owned(allocator, "APPDATA");
    } else if (comptime is_linux()) blk: {
        // On Linux, use $XDG_CONFIG_HOME or $HOME/.config
        if (Env.get_env_var_owned(allocator, "XDG_CONFIG_HOME")) |xdg_config_home| {
            if (xdg_config_home.len > 0 and std.fs.path.isAbsolute(xdg_config_home)) {
                break :blk xdg_config_home;
            }
            allocator.free(xdg_config_home);
        }

        const home = Env.get_env_var_owned(allocator, "HOME") orelse break :blk null;
        defer allocator.free(home);
        break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
    } else {
        @compileError("Unsupported OS");
    };

    if (base_dir) |_base_dir| {
        defer allocator.free(_base_dir);

        const app_config_dir = try std.fs.path.join(allocator, &.{ _base_dir, "spacecap" });
        errdefer allocator.free(app_config_dir);

        if (std.Io.Dir.cwd().createDirPath(io, app_config_dir)) {
            return app_config_dir;
        } else |err| {
            log.err("[get_app_data_dir] failed to create app data directory {s}: {}", .{ app_config_dir, err });
            allocator.free(app_config_dir);
        }
    }

    log.warn("[get_app_data_dir] falling back to current working directory", .{});
    return std.process.currentPathAlloc(io, allocator) catch |err| {
        log.err("[get_app_data_dir] failed to get current working directory: {}", .{err});
        return allocator.dupe(u8, ".");
    };
}

// Falls back to the current working directory when
// the home-based output directory cannot be resolved or created.
//
// Caller owns the memory.
// e.g. ~/Videos/spacecap
pub fn get_default_video_output_dir(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    if (@import("builtin").is_test) {
        const TEST_APP_DATA_DIR = @import("./test.zig").TEST_APP_DATA_DIR;
        assert(TEST_APP_DATA_DIR != null);
        return allocator.dupe(u8, TEST_APP_DATA_DIR.?);
    }

    // TODO: Test on Windows.
    const home_dir: ?[]u8 = if (comptime is_windows()) blk: {
        if (Env.get_env_var_owned(allocator, "USERPROFILE")) |user_profile| {
            break :blk user_profile;
        }
        break :blk Env.get_env_var_owned(allocator, "HOME");
    } else if (comptime is_linux()) blk: {
        break :blk Env.get_env_var_owned(allocator, "HOME");
    } else {
        @compileError("Unsupported OS");
    };

    if (home_dir) |_home_dir| {
        defer allocator.free(_home_dir);

        const output_dir = try std.fs.path.join(allocator, &.{ _home_dir, "Videos", "spacecap" });
        errdefer allocator.free(output_dir);

        if (std.Io.Dir.cwd().createDirPath(io, output_dir)) {
            return output_dir;
        } else |err| {
            log.err("[get_default_video_output_dir] failed to create output directory {s}: {}", .{ output_dir, err });
            allocator.free(output_dir);
        }
    }

    log.warn("[get_default_video_output_dir] falling back to current working directory", .{});
    return std.process.currentPathAlloc(io, allocator) catch |err| {
        log.err("[get_default_video_output_dir] failed to get current working directory: {}", .{err});
        return allocator.dupe(u8, ".");
    };
}

pub fn LinkedListIterator(comptime T: type) type {
    return struct {
        current: ?*@FieldType(T, "node"),

        pub fn init(list: anytype) @This() {
            return .{ .current = list.first };
        }

        pub fn next(self: *@This()) ?*T {
            const current = self.current orelse return null;
            self.current = current.next;
            return @fieldParentPtr("node", current);
        }
    };
}

test "Util - format_duration_label formats compact duration strings" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        seconds: u32,
        expected: []const u8,
    }{
        .{ .seconds = 0, .expected = "0s" },
        .{ .seconds = 45, .expected = "45s" },
        .{ .seconds = 60, .expected = "1m" },
        .{ .seconds = 65, .expected = "1m 5s" },
        .{ .seconds = 3600, .expected = "1h" },
        .{ .seconds = 3605, .expected = "1h 5s" },
        .{ .seconds = 3660, .expected = "1h 1m" },
        .{ .seconds = 3665, .expected = "1h 1m 5s" },
    };

    for (cases) |case| {
        const label = try format_duration_label(allocator, .{ .seconds = @floatFromInt(case.seconds) });
        defer allocator.free(label);

        try std.testing.expectEqualStrings(case.expected, label);
    }

    const replay_cases = [_]struct {
        seconds: f64,
        max: u32,
        expected: []const u8,
    }{
        .{ .seconds = 8.9, .max = 10, .expected = "9s" },
        .{ .seconds = 9.1, .max = 10, .expected = "10s" },
        .{ .seconds = 10.2, .max = 10, .expected = "10s" },
    };

    for (replay_cases) |case| {
        const label = try format_duration_label(allocator, .{
            .seconds = case.seconds,
            .max = case.max,
        });
        defer allocator.free(label);

        try std.testing.expectEqualStrings(case.expected, label);
    }
}

test "Util - LinkedListIterator iterates doubly linked list data in order" {
    const TestNode = struct {
        value: u32,
        node: std.DoublyLinkedList.Node = .{},
    };

    var list: std.DoublyLinkedList = .{};
    var first = TestNode{ .value = 1 };
    var second = TestNode{ .value = 2 };
    var third = TestNode{ .value = 3 };

    list.append(&first.node);
    list.append(&second.node);
    list.append(&third.node);

    var iter = LinkedListIterator(TestNode).init(&list);
    try std.testing.expectEqual(1, iter.next().?.value);
    try std.testing.expectEqual(2, iter.next().?.value);
    try std.testing.expectEqual(3, iter.next().?.value);
    try std.testing.expectEqual(null, iter.next());
}

test "Util - LinkedListIterator iterates singly linked list data in order" {
    const TestNode = struct {
        value: u32,
        node: std.SinglyLinkedList.Node = .{},
    };

    var list: std.SinglyLinkedList = .{};
    var first = TestNode{ .value = 1 };
    var second = TestNode{ .value = 2 };
    var third = TestNode{ .value = 3 };

    list.prepend(&third.node);
    list.prepend(&second.node);
    list.prepend(&first.node);

    var iter = LinkedListIterator(TestNode).init(&list);
    try std.testing.expectEqual(1, iter.next().?.value);
    try std.testing.expectEqual(2, iter.next().?.value);
    try std.testing.expectEqual(3, iter.next().?.value);
    try std.testing.expectEqual(null, iter.next());
}
