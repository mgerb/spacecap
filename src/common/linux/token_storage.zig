const std = @import("std");
const util = @import("../../util.zig");

const log = std.log.scoped(.token_storage);

/// Read token from user app directory.
/// Caller owns the memory.
pub fn load_token(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_file_name: []const u8,
) !?[]u8 {
    const dir = try util.get_app_data_dir(allocator, io);
    defer allocator.free(dir);
    const file_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.txt",
        .{ dir, token_file_name },
    );
    defer allocator.free(file_path);

    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
        if (err == std.Io.File.OpenError.FileNotFound) {
            log.info("token not found: {s}\n", .{token_file_name});
            return null;
        }
        return err;
    };
    defer file.close(io);
    const stat = file.stat(io) catch |err| {
        log.err("file stat error: {}\n", .{err});
        return err;
    };

    var reader = file.reader(io, &.{});
    const token = try reader.interface.readAlloc(allocator, stat.size);
    return token;
}

/// Read token from user app directory.
/// Caller owns the memory.
pub fn load_token_z(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_file_name: []const u8,
) !?[:0]u8 {
    if (try load_token(allocator, io, token_file_name)) |token| {
        defer allocator.free(token);
        const token_z = try allocator.dupeZ(u8, token);
        return token_z;
    }
    return null;
}

/// Write token to user app directory
pub fn save_token(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_file_name: []const u8,
    token_value: []const u8,
) !void {
    const dir = try util.get_app_data_dir(allocator, io);
    defer allocator.free(dir);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.txt", .{
        dir,
        token_file_name,
    });
    defer allocator.free(file_path);

    const file = std.Io.Dir.createFileAbsolute(io, file_path, .{}) catch |err| {
        log.err("create file error: {}\n", .{err});
        return err;
    };
    defer file.close(io);

    var writer_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &writer_buffer);
    try writer.interface.writeAll(token_value);
    try writer.interface.flush();
}

/// Delete token file from user app directory. Ignore if file not found.
pub fn delete_token(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_file_name: []const u8,
) !void {
    const dir = try util.get_app_data_dir(allocator, io);
    defer allocator.free(dir);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.txt", .{
        dir,
        token_file_name,
    });
    defer allocator.free(file_path);

    std.Io.Dir.deleteFileAbsolute(io, file_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}
