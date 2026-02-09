const std = @import("std");

/// Caller owns the memory
pub fn getRequestPath(allocator: std.mem.Allocator, unique_name: [:0]const u8, token: [:0]const u8) std.mem.Allocator.Error![:0]const u8 {
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

pub fn generateToken(allocator: std.mem.Allocator) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(
        allocator,
        "spacecap{x:0<7}",
        .{std.crypto.random.int(u28)},
        0,
    );
}

test "getRequestPath - formats and sanitizes unique name" {
    const a = std.testing.allocator;

    const path = try getRequestPath(a, "1.192", "spacecap123");
    defer a.free(path);
    try std.testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_192/spacecap123",
        path,
    );
}

test "generateToken - prefix and hex suffix" {
    const a = std.testing.allocator;

    const token = try generateToken(a);
    defer a.free(token);

    try std.testing.expect(std.mem.startsWith(u8, token, "spacecap"));
    try std.testing.expectEqual(@as(usize, "spacecap".len + 7), token.len);
    for (token["spacecap".len..]) |ch| {
        try std.testing.expect(std.ascii.isHex(ch));
    }
}
