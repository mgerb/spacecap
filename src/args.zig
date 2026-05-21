const std = @import("std");
const clap = @import("clap");
const build_options = @import("build_options");
const Util = @import("./util.zig");

// TODO: Remove zig-clap and parse args manually. We probably don't need a dependency for this.

const log = std.log.scoped(.cli_args);

/// Params for all platforms should go here. Platform specific args should be added below.
const shared_params = (
    \\-h, --help             Display this help and exit.
    \\-v, --version          Display the Spacecap version and exit.
    \\
);

const linux_params = (
    \\-s, --send <command>   Send a command to a running Spacecap instance.
    \\                       Commands: save-replay, start-replay-buffer, stop-replay-buffer, toggle-replay-buffer, start-recording, stop-recording, toggle-recording
    \\
);

const windows_params =
    "";

const linux_params_parsed = clap.parseParamsComptime(shared_params ++ linux_params);
const windows_params_parsed = clap.parseParamsComptime(shared_params ++ windows_params);

pub const SendCommand = enum {
    @"save-replay",
    @"start-replay-buffer",
    @"stop-replay-buffer",
    @"toggle-replay-buffer",
    @"start-recording",
    @"stop-recording",
    @"toggle-recording",
};

pub const Args = if (Util.is_linux())
    union(enum) {
        /// Send a command to the IPC server.
        send: SendCommand,
    }
else
    struct {};

pub fn parse(init: std.process.Init) ?Args {
    if (comptime Util.is_linux()) {
        return parse_linux(init);
    } else if (comptime Util.is_windows()) {
        return parse_windows(init);
    } else {
        log.err("unsupported platform", .{});
        unreachable;
    }
}

fn print_version(io: std.Io) void {
    var stdout = std.Io.File.stdout().writer(io, &.{});
    stdout.interface.print("{s}\n", .{build_options.version}) catch unreachable;
}

fn parse_linux(init: std.process.Init) ?Args {
    const parsers = comptime .{
        .command = clap.parsers.enumeration(SendCommand),
    };

    var res = clap.parse(clap.Help, &linux_params_parsed, parsers, init.minimal.args, .{
        .allocator = init.gpa,
    }) catch |err| {
        log.err("Unable to parse args: {}", .{err});
        clap.helpToFile(init.io, .stderr(), clap.Help, &linux_params_parsed, .{ .markdown_lite = false }) catch {};
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.help > 0) {
        print_version(init.io);
        clap.helpToFile(init.io, .stdout(), clap.Help, &linux_params_parsed, .{ .markdown_lite = false }) catch {};
        std.process.exit(0);
    }

    if (res.args.version > 0) {
        print_version(init.io);
        std.process.exit(0);
    }

    if (res.args.send) |cmd| return .{ .send = cmd };

    return null;
}

fn parse_windows(init: std.process.Init) ?Args {
    var res = clap.parse(clap.Help, &windows_params_parsed, comptime .{}, init.minimal.args, .{
        .allocator = init.gpa,
    }) catch |err| {
        log.err("Unable to parse args: {}", .{err});
        clap.helpToFile(init.io, .stderr(), clap.Help, &windows_params_parsed, .{}) catch {};
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.help > 0) {
        print_version(init.io);
        clap.helpToFile(init.io, .stdout(), clap.Help, &windows_params_parsed, .{}) catch {};
        std.process.exit(0);
    }

    if (res.args.version > 0) {
        print_version(init.io);
        std.process.exit(0);
    }

    return null;
}
