//! Spacecap's custom argument parsing logic.

const std = @import("std");

const log = std.log.scoped(.argparse);

/// All command line functionality is derived from arguments defined here.
/// To add a new argument - simply add another value to this list.
const ARGUMENT_DEFINITIONS: []const ArgDef = &.{
    .{
        .full_name = "help",
        .short_name = "h",
        .description = "Display this help and exit.",
    },
    .{
        .full_name = "version",
        .short_name = "v",
        .description = "Display the Spacecap version and exit.",
    },
    .{
        .full_name = "send",
        .short_name = "s",
        .value_name = "COMMAND",
        .value_type = SendCommand,
        .description =
        \\Send a command to a running Spacecap instance.
        \\
        \\COMMANDS:
        \\
        ++ SendCommand.to_string("  "),
    },
};

/// A tagged union type derived from ARGUMENT_DEFINITIONS.
pub const Arg = MakeArgType(ARGUMENT_DEFINITIONS);

pub const SendCommand = enum {
    @"save-replay",
    screenshot,
    @"start-replay-buffer",
    @"stop-replay-buffer",
    @"toggle-replay-buffer",
    @"start-recording",
    @"stop-recording",
    @"toggle-recording",

    /// Convert values to a string for the help menu.
    fn to_string(comptime padding: []const u8) []const u8 {
        comptime {
            var result: []const u8 = "";

            for (std.meta.fieldNames(@This()), 0..) |name, i| {
                result = std.fmt.comptimePrint(
                    "{s}{s}{s}",
                    .{
                        result,
                        if (i == 0) padding else "\n" ++ padding,
                        name,
                    },
                );
            }

            return result;
        }
    }
};

/// Parse command line arguments and return a single Arg.
/// Only one Arg is supported at this time.
pub fn parse_args(init: std.process.Init) !?Arg {
    // ----------------------------------------------------------------------------
    // Init writers.
    // ----------------------------------------------------------------------------
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, stderr_buf[0..]);
    var stderr_writer_interface = &stderr_writer.interface;
    defer stderr_writer_interface.flush() catch @panic("[parse_args] failed to flush stderr writer");

    // ----------------------------------------------------------------------------
    // Convert args iter to array list.
    // ----------------------------------------------------------------------------
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();

    var all_args: std.ArrayList([]const u8) = .empty;
    defer all_args.deinit(init.gpa);

    while (iter.next()) |arg| {
        try all_args.append(init.gpa, arg);
    }

    // ----------------------------------------------------------------------------
    // Tokenize the args.
    // ----------------------------------------------------------------------------
    var tokens = try tokenize_args(init.gpa, all_args.items);
    defer tokens.deinit(init.gpa);

    if (tokens.items.len == 0) {
        return null;
    }

    if (tokens.items.len > 1) {
        try stderr_writer_interface.print(
            \\
            \\----------------------------------------------------------------------------
            \\ERROR: Only one argument is supported.
            \\----------------------------------------------------------------------------
            \\
        , .{});
        try print_help_menu(init.io, stderr_writer_interface);
        return error.InvalidArguments;
    }

    const token = tokens.items[0];
    const arg = token.get_arg() catch {
        // Just treat all errors as invalid arguments for now. We could
        // eventually have more fine grained error reporting because get_arg
        // does return more specific errors.
        try stderr_writer_interface.print(
            \\
            \\----------------------------------------------------------------------------
            \\ERROR: Invalid arguments: {s}{s} {s}
            \\----------------------------------------------------------------------------
            \\
        ,
            .{
                if (token.arg_type == .short) "-" else "--",
                token.name,
                token.value orelse "",
            },
        );
        try print_help_menu(init.io, stderr_writer_interface);
        return error.InvalidArguments;
    };
    return arg;
}

/// Print the help menu to stdout.
pub fn print_help_menu(io: std.Io, writer_override: ?*std.Io.Writer) std.Io.Writer.Error!void {
    var writer: *std.Io.Writer = undefined;

    if (writer_override) |_writer_override| {
        writer = _writer_override;
    } else {
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, stdout_buf[0..]);
        writer = &stdout_writer.interface;
    }

    defer writer.flush() catch @panic("[print_help_menu] failed to flush stdout writer");

    try writer.print("\nUSAGE:\n  spacecap [OPTIONS]\n\nOPTIONS", .{});
    inline for (ARGUMENT_DEFINITIONS) |a| {
        try writer.print("\n", .{});

        if (a.short_name) |short_name| {
            try writer.print("  -{s}, ", .{short_name});
        } else {
            try writer.print("  ", .{});
        }

        try writer.print("--{s}", .{a.full_name});

        if (a.value_name) |value_name| {
            try writer.print(" {s}", .{value_name});
        }

        try writer.print("\n", .{});

        var split_iter = std.mem.splitAny(u8, a.description, "\n");
        while (split_iter.next()) |si| {
            try writer.print("    {s}\n", .{si});
        }
    }
    try writer.print("\n", .{});
}

/// The definition of a valid command line argument for Spacecap.
const ArgDef = struct {
    /// e.g. h
    short_name: ?[]const u8 = null,
    /// e.g. help
    full_name: []const u8,
    /// This is listed in the help menu.
    description: []const u8,
    /// An argument can optionally have a value associated with it.
    /// This `value_name` is just used for the description in the help menu.
    value_name: ?[]const u8 = null,
    /// The type of the value.
    value_type: ?type = null,
};

/// Represents a command line argument (and optional value).
const Token = struct {
    const Error = error{
        InvalidArgumentType,
        InvalidEnumValue,
        MissingArgument,
        UnexpectedArgument,
        UnknownOption,
    };

    arg_type: enum {
        /// If it is a short argument.
        /// e.g. -s
        short,
        /// If it is a long argument.
        /// e.g. --send
        full,
    },
    /// The name of the arg.
    /// - short
    ///   e.g. s
    /// - full
    ///   e.g. send
    name: []const u8,
    /// The optional value of the arg.
    /// e.g. save-replay
    value: ?[]const u8 = null,

    fn get_arg(
        self: @This(),
    ) Error!Arg {
        inline for (ARGUMENT_DEFINITIONS) |choice| {
            const match: ?Token = blk: switch (self.arg_type) {
                .full => {
                    if (std.mem.eql(u8, self.name, choice.full_name)) {
                        break :blk self;
                    }
                    break :blk null;
                },
                .short => {
                    if (choice.short_name != null and std.mem.eql(u8, self.name, choice.short_name.?)) {
                        break :blk self;
                    }
                    break :blk null;
                },
            };

            if (match != null) {
                if (choice.value_type) |value_type| {
                    const raw = match.?.value orelse return Error.MissingArgument;
                    const value = parse_value(value_type, raw) catch return Error.InvalidArgumentType;

                    // option.full_name is comptime-known because of inline for.
                    return @unionInit(Arg, choice.full_name, value);
                }

                if (match.?.value != null) return Error.UnexpectedArgument;
                return @unionInit(Arg, choice.full_name, {});
            }
        }

        log.err("[get_arg] unknown option: {s}", .{self.name});
        return Error.UnknownOption;
    }

    fn parse_value(comptime T: type, raw: []const u8) (std.fmt.ParseFloatError || std.fmt.ParseIntError || Error)!T {
        if (T == []const u8) {
            return raw;
        }

        return switch (@typeInfo(T)) {
            .int => std.fmt.parseInt(T, raw, 10),
            .float => std.fmt.parseFloat(T, raw),
            .@"enum" => std.meta.stringToEnum(T, raw) orelse
                Error.InvalidEnumValue,
            else => @compileError(
                "unsupported argument type: " ++ @typeName(T),
            ),
        };
    }
};

/// Creates a tagged union type from a list of argument definitions.
fn MakeArgType(comptime fields: []const ArgDef) type {
    comptime {
        var names: [fields.len][]const u8 = undefined;
        var types: [fields.len]type = undefined;
        var enum_values: [fields.len]u8 = undefined;

        for (fields, 0..) |field, i| {
            names[i] = field.full_name;
            types[i] = field.value_type orelse void;
            enum_values[i] = @intCast(i);
        }

        const Tag = @Enum(
            u8,
            .exhaustive,
            &names,
            &enum_values,
        );

        return @Union(
            .auto,
            Tag,
            &names,
            &types,
            &@splat(.{}),
        );
    }
}

/// Create a list of tokens from raw command line arguments.
fn tokenize_args(allocator: std.mem.Allocator, args: []const []const u8) !std.ArrayList(Token) {
    var tokens: std.ArrayList(Token) = .empty;

    // Start at 1 because the first arg is always the program name.
    for (args[1..], 1..) |arg, index| {
        var split = std.mem.splitScalar(u8, arg, '=');
        const name = split.next().?;
        const value = split.next();

        if (std.mem.startsWith(u8, name, "--")) {
            try tokens.append(allocator, .{
                .arg_type = .full,
                .name = std.mem.trimStart(u8, name, "--"),
                .value = value,
            });
        } else if (std.mem.startsWith(u8, name, "-")) {
            try tokens.append(allocator, .{
                .arg_type = .short,
                .name = std.mem.trimStart(u8, name, "-"),
                .value = value,
            });
        } else {
            // Should be a value.
            if (index > 1 and tokens.items.len > 0 and tokens.items[tokens.items.len - 1].value == null) {
                tokens.items[tokens.items.len - 1].value = name;
            } else {
                log.warn("[tokenize_args] invalid argument: {s}", .{name});
            }
        }
    }

    return tokens;
}

test "Argparse - tokenize_args - should tokenize no args" {
    var tokens = try tokenize_args(std.testing.allocator, &.{"spacecap"});
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, tokens.items.len);
}

test "Argparse - tokenize_args - should tokenize even with an invalid argument" {
    var tokens = try tokenize_args(std.testing.allocator, &.{ "spacecap", "version" });
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, tokens.items.len);
}

test "Argparse - tokenize_args - should tokenize full arg" {
    var tokens = try tokenize_args(std.testing.allocator, &.{ "spacecap", "--help" });
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, tokens.items.len);
    try std.testing.expectEqualStrings("help", tokens.items[0].name);
    try std.testing.expectEqual(.full, tokens.items[0].arg_type);
}

test "Argparse - tokenize_args - should tokenize short arg" {
    var tokens = try tokenize_args(std.testing.allocator, &.{ "spacecap", "-h" });
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, tokens.items.len);
    try std.testing.expectEqualStrings("h", tokens.items[0].name);
    try std.testing.expectEqual(.short, tokens.items[0].arg_type);
}

test "Argparse - tokenize_args - should tokenize full arg with value (space separator)" {
    var tokens = try tokenize_args(std.testing.allocator, &.{ "spacecap", "--send", "save-replay" });
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, tokens.items.len);
    try std.testing.expectEqualStrings("send", tokens.items[0].name);
    try std.testing.expectEqualStrings("save-replay", tokens.items[0].value.?);
    try std.testing.expectEqual(.full, tokens.items[0].arg_type);
}

test "Argparse - tokenize_args - should tokenize short arg with value (space separator)" {
    var tokens = try tokenize_args(std.testing.allocator, &.{ "spacecap", "-s", "save-replay" });
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, tokens.items.len);
    try std.testing.expectEqualStrings("s", tokens.items[0].name);
    try std.testing.expectEqualStrings("save-replay", tokens.items[0].value.?);
    try std.testing.expectEqual(.short, tokens.items[0].arg_type);
}

test "Argparse - tokenize_args - should tokenize full arg with value (= separator)" {
    var tokens = try tokenize_args(std.testing.allocator, &.{ "spacecap", "--send=save-replay" });
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, tokens.items.len);
    try std.testing.expectEqualStrings("send", tokens.items[0].name);
    try std.testing.expectEqualStrings("save-replay", tokens.items[0].value.?);
    try std.testing.expectEqual(.full, tokens.items[0].arg_type);
}

test "Argparse - tokenize_args - should tokenize short arg with value (= separator)" {
    var tokens = try tokenize_args(std.testing.allocator, &.{ "spacecap", "-s=save-replay" });
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, tokens.items.len);
    try std.testing.expectEqualStrings("s", tokens.items[0].name);
    try std.testing.expectEqualStrings("save-replay", tokens.items[0].value.?);
    try std.testing.expectEqual(.short, tokens.items[0].arg_type);
}

test "Argparse - tokenize_args - should set value to empty string when value is empty (= separator)" {
    var tokens = try tokenize_args(std.testing.allocator, &.{ "spacecap", "-s=" });
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, tokens.items.len);
    try std.testing.expectEqualStrings("s", tokens.items[0].name);
    try std.testing.expectEqualStrings("", tokens.items[0].value.?);
    try std.testing.expectEqual(.short, tokens.items[0].arg_type);
}

test "Argparse - Token.get_arg - should get help arg (short)" {
    var tokens = try tokenize_args(std.testing.allocator, &.{ "spacecap", "-h" });
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(.help, try tokens.items[0].get_arg());
}

test "Argparse - Token.get_arg - should get help arg (full)" {
    var tokens = try tokenize_args(std.testing.allocator, &.{ "spacecap", "--help" });
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(.help, try tokens.items[0].get_arg());
}

test "Argparse - Token.get_arg - should get send command" {
    var tokens = try tokenize_args(std.testing.allocator, &.{ "spacecap", "-s", "save-replay" });
    defer tokens.deinit(std.testing.allocator);

    const expected: Arg = .{
        .send = .@"save-replay",
    };
    try std.testing.expectEqual(expected, try tokens.items[0].get_arg());
}

test "Argparse - Token.get_arg - should handle invalid send command" {
    var tokens = try tokenize_args(std.testing.allocator, &.{ "spacecap", "-s", "save-replay123" });
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectError(Token.Error.InvalidArgumentType, tokens.items[0].get_arg());
}
