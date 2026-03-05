const std = @import("std");
const clap = @import("clap");
const Util = @import("./util.zig");

const log = std.log.scoped(.cli_args);

/// Params for all platforms should go here. Platform specific args should be added below.
const shared_params =
    "-h, --help             Display this help and exit.\n";

const linux_params =
    "-s, --send <command>   Send a command to a running Spacecap instance. Commands: save-replay\n";

const windows_params =
    "";

const linux_params_parsed = clap.parseParamsComptime(shared_params ++ linux_params);
const windows_params_parsed = clap.parseParamsComptime(shared_params ++ windows_params);

pub const SendCommand = enum {
    @"save-replay",
};

pub const Args = if (Util.isLinux())
    union(enum) {
        /// Send a command to the IPC server.
        send: SendCommand,
    }
else
    struct {};

pub fn parse(allocator: std.mem.Allocator) ?Args {
    if (comptime Util.isLinux()) {
        return parseLinux(allocator);
    } else if (comptime Util.isWindows()) {
        return parseWindows(allocator);
    } else {
        log.err("unsupported platform", .{});
        unreachable;
    }
}

fn parseLinux(allocator: std.mem.Allocator) ?Args {
    const parsers = comptime .{
        .command = clap.parsers.enumeration(SendCommand),
    };

    var res = clap.parse(clap.Help, &linux_params_parsed, parsers, .{
        .allocator = allocator,
    }) catch |err| {
        log.err("Unable to parse args: {}", .{err});
        clap.helpToFile(.stderr(), clap.Help, &linux_params_parsed, .{}) catch {};
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.help > 0) {
        clap.helpToFile(.stderr(), clap.Help, &linux_params_parsed, .{}) catch {};
        std.process.exit(0);
    }

    if (res.args.send) |cmd| return .{ .send = cmd };

    return null;
}

fn parseWindows(allocator: std.mem.Allocator) ?Args {
    var res = clap.parse(clap.Help, &windows_params_parsed, comptime .{}, .{
        .allocator = allocator,
    }) catch |err| {
        log.err("Unable to parse args: {}", .{err});
        clap.helpToFile(.stderr(), clap.Help, &windows_params_parsed, .{}) catch {};
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.help > 0) {
        clap.helpToFile(.stderr(), clap.Help, &windows_params_parsed, .{}) catch {};
        std.process.exit(0);
    }

    return null;
}
