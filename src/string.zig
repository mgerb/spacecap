//! A String implementation that implements JSON parse/stringify methods.
//! See tests for details.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const String = struct {
    const Self = @This();
    bytes: []u8,
    allocator: Allocator,

    /// Create a new String. Memory is duped. Does not take ownership of bytes passed in.
    pub fn from(allocator: Allocator, bytes: []const u8) !String {
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            return error.InvalidUtf8;
        }
        return .{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, bytes),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bytes);
    }

    pub fn clone(self: *const Self, allocator: Allocator) !Self {
        return .{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, self.bytes),
        };
    }

    /// Required to satisfy the JSON encoding interface.
    /// See `std.json.Stringify.write` for details.
    pub fn jsonStringify(self: @This(), stringify: anytype) !void {
        try stringify.write(self.bytes);
    }

    /// Required to satisfy the JSON decoding interface.
    /// See `std.json.static.innerParse` for details.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !String {
        const token = try source.nextAllocMax(allocator, .alloc_always, options.max_value_len.?);
        const bytes = switch (token) {
            .allocated_string => |bytes| bytes,
            else => return error.UnexpectedToken,
        };
        errdefer allocator.free(bytes);

        if (!std.unicode.utf8ValidateSlice(bytes)) {
            return error.UnexpectedToken;
        }

        return .{ .allocator = allocator, .bytes = bytes };
    }
};

const TestUtil = struct {
    const Person = struct {
        name: String,
    };
};

test "String - should create from utf8 string" {
    var s = try String.from(std.testing.allocator, "test 123");
    defer s.deinit();
    try std.testing.expectEqualStrings(s.bytes, "test 123");
}

test "String - should clone" {
    var s1 = try String.from(std.testing.allocator, "test1");
    defer s1.deinit();

    var s2 = try s1.clone(std.testing.allocator);
    defer s2.deinit();
    @memcpy(s2.bytes[0..], "test2");

    try std.testing.expectEqualStrings(s1.bytes, "test1");
    try std.testing.expectEqualStrings(s2.bytes, "test2");
}

test "String - should encode json" {
    var person: TestUtil.Person = .{ .name = try .from(std.testing.allocator, "mitchell") };
    defer person.name.deinit();

    try std.testing.expectEqualStrings(person.name.bytes, "mitchell");

    const json_string = try std.json.Stringify.valueAlloc(std.testing.allocator, person, .{});
    defer std.testing.allocator.free(json_string);

    try std.testing.expectEqualStrings(json_string, "{\"name\":\"mitchell\"}");
}

test "String - should decode json" {
    const parsed = try std.json.parseFromSlice(TestUtil.Person, std.testing.allocator, "{\"name\":\"mitchell\"}", .{});
    defer parsed.deinit();
    const person = parsed.value;
    try std.testing.expectEqualStrings(person.name.bytes, "mitchell");
}
