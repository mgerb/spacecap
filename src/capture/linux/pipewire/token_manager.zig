const std = @import("std");

pub const TokenManager = struct {
    const Self = @This();
    var request_counter: u64 = 0;
    var session_counter: u64 = 0;

    const RequestToken = struct {
        allocator: std.mem.Allocator,
        path: [:0]u8,
        token: [:0]u8,

        pub fn deinit(self: *const RequestToken) void {
            self.allocator.free(self.token);
            self.allocator.free(self.path);
        }
    };

    pub fn getRequestTokens(allocator: std.mem.Allocator, sender_name: [:0]const u8) std.mem.Allocator.Error!RequestToken {
        request_counter += 1;

        // Generate the token
        const token = try std.fmt.allocPrintSentinel(allocator, "spacecap{d}", .{request_counter}, 0);
        errdefer allocator.free(token);

        // Generate the path
        const path: [:0]u8 = try std.fmt.allocPrintSentinel(
            allocator,
            "/org/freedesktop/portal/desktop/request/{s}/spacecap{d}",
            .{ sender_name, request_counter },
            0,
        );

        return .{
            .allocator = allocator,
            .path = path,
            .token = token,
        };
    }

    const SessionToken = struct {
        allocator: std.mem.Allocator,
        path: [:0]u8,

        pub fn deinit(self: *const SessionToken) void {
            self.allocator.free(self.path);
        }
    };

    pub fn getSessionToken(allocator: std.mem.Allocator) std.mem.Allocator.Error!SessionToken {
        session_counter += 1;

        return SessionToken{
            .allocator = allocator,
            .path = try std.fmt.allocPrintSentinel(allocator, "spacecap{}", .{session_counter}, 0),
        };
    }
};

test "TokenManager" {
    const a = std.testing.allocator;

    const rp1 = try TokenManager.getRequestTokens(a, "sender_name");
    defer rp1.deinit();
    try std.testing.expectEqualStrings(rp1.token, "spacecap1");
    try std.testing.expectEqualStrings(rp1.path, "/org/freedesktop/portal/desktop/request/sender_name/spacecap1");

    const rp2 = try TokenManager.getRequestTokens(a, "sender_name");
    defer rp2.deinit();
    try std.testing.expectEqualStrings(rp2.token, "spacecap2");
    try std.testing.expectEqualStrings(rp2.path, "/org/freedesktop/portal/desktop/request/sender_name/spacecap2");

    const st1 = try TokenManager.getSessionToken(a);
    defer st1.deinit();
    try std.testing.expectEqualStrings(st1.path, "spacecap1");
    const st2 = try TokenManager.getSessionToken(a);
    defer st2.deinit();
    try std.testing.expectEqualStrings(st2.path, "spacecap2");
}
