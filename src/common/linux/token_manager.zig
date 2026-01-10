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

test "TokenManager" {
    const a = std.testing.allocator;

    const rp1 = try getRequestPath(a, "sender_name");
    defer rp1.deinit();
    try std.testing.expectEqualStrings(rp1.token, "spacecap1");
    try std.testing.expectEqualStrings(rp1.path, "/org/freedesktop/portal/desktop/request/sender_name/spacecap1");

    const rp2 = try getRequestPath(a, "sender_name");
    defer rp2.deinit();
    try std.testing.expectEqualStrings(rp2.token, "spacecap2");
    try std.testing.expectEqualStrings(rp2.path, "/org/freedesktop/portal/desktop/request/sender_name/spacecap2");
}
