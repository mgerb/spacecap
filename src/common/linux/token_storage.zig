const std = @import("std");
const UserSettings = @import("../../user_settings.zig");

const log = std.log.scoped(.token_storage);

/// Read token from user app directory.
/// Caller owns the memory.
pub fn loadToken(
    allocator: std.mem.Allocator,
    token_file_name: []const u8,
) !?[]u8 {
    const dir = try UserSettings.getAppDataDir(allocator);
    defer allocator.free(dir);
    const file_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.txt",
        .{ dir, token_file_name },
    );
    defer allocator.free(file_path);
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == std.fs.File.OpenError.FileNotFound) {
            log.info("token not found: {s}\n", .{token_file_name});
            return null;
        }
        return err;
    };
    defer file.close();
    const stat = file.stat() catch |err| {
        log.err("file stat error: {}\n", .{err});
        return err;
    };

    var reader = file.reader(&.{});
    const token = try reader.interface.readAlloc(allocator, stat.size);
    return token;
}

/// Read token from user app directory.
/// Caller owns the memory.
pub fn loadTokenZ(
    allocator: std.mem.Allocator,
    token_file_name: []const u8,
) !?[:0]u8 {
    if (try loadToken(allocator, token_file_name)) |token| {
        defer allocator.free(token);
        const token_z = try allocator.dupeZ(u8, token);
        return token_z;
    }
    return null;
}

/// Write token to user app directory
pub fn saveToken(
    allocator: std.mem.Allocator,
    token_file_name: []const u8,
    token_value: []const u8,
) !void {
    const dir = try UserSettings.getAppDataDir(allocator);
    defer allocator.free(dir);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.txt", .{
        dir,
        token_file_name,
    });
    defer allocator.free(file_path);

    const file = std.fs.createFileAbsolute(file_path, .{}) catch |err| {
        log.err("create file error: {}\n", .{err});
        return err;
    };
    defer file.close();

    try file.writeAll(token_value);
}
