const std = @import("std");

/// Caller owns the memory
pub fn get_request_path(allocator: std.mem.Allocator, unique_name: [:0]const u8, token: [:0]const u8) std.mem.Allocator.Error![:0]const u8 {
    // Generate the path
    const path: [:0]u8 = try std.fmt.allocPrintSentinel(
        allocator,
        "/org/freedesktop/portal/desktop/request/{s}/{s}",
        .{ unique_name, token },
        0,
    );

    // Sanitize the unique name by replacing every `.` with `_`.
    // In effect, this will turn a unique name like `:1.192` into `1_192`.
    // Valid D-Bus object path components never contain `.`s anyway, so we're
    // free to replace all instances of `.` here and avoid extra allocation.
    std.mem.replaceScalar(u8, path, '.', '_');
    return path;
}

pub fn generate_token(allocator: std.mem.Allocator, io: std.Io) ![:0]const u8 {
    const rng_impl: std.Random.IoSource = .{ .io = io };
    const rng = rng_impl.interface();
    return std.fmt.allocPrintSentinel(
        allocator,
        "spacecap{x:0<7}",
        .{rng.int(u28)},
        0,
    );
}

test "TokenManager - get_request_path - formats and sanitizes unique name" {
    const a = std.testing.allocator;

    const path = try get_request_path(a, "1.192", "spacecap123");
    defer a.free(path);
    try std.testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_192/spacecap123",
        path,
    );
}

test "TokenManager - generate_token - prefix and hex suffix" {
    const a = std.testing.allocator;

    const token = try generate_token(a, std.testing.io);
    defer a.free(token);

    try std.testing.expect(std.mem.startsWith(u8, token, "spacecap"));
    try std.testing.expectEqual(@as(usize, "spacecap".len + 7), token.len);
    for (token["spacecap".len..]) |ch| {
        try std.testing.expect(std.ascii.isHex(ch));
    }
}
