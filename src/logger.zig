//! This module handles all logging for Spacecap. There is one instance of a
//! logger (LOGGER), which handles stdout/stderr (std.log.defaultLog) and file
//! logging. By default, only error logs get written to a file, however this
//! can be changed by the SPACECAP_LOG_LEVEL environment variable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Env = @import("./env.zig");
const Util = @import("./util.zig");
const BufferedChan = @import("./channel.zig").BufferedChan;

const CRASH_LOG_FILE_NAME = "crash.log";

/// Singleton instance of LoggerInternal.
var LOGGER: ?LoggerInternal = null;

/// Initialize the singleton instance of LoggerInternal.
pub fn init(allocator: Allocator, io: std.Io) Allocator.Error!void {
    LOGGER = try .init(allocator, io);
}

/// Deinit the singleton instance of LoggerInternal.
pub fn deinit() void {
    if (LOGGER) |*logger| {
        logger.deinit();
    }
}

/// Global log handler. Will call std.log.defaultLog if the global logger has
/// not been initialized yet.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    log_args: anytype,
) void {
    if (LOGGER) |*logger| {
        logger.log(level, scope, format, log_args) catch {
            // NOTE: Do nothing here. We can't log because we don't want to get
            // stuck in an infinite loop.
        };
    } else {
        std.log.defaultLog(level, scope, format, log_args);
    }
}

pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (LOGGER) |*logger| {
        logger.write_panic(msg, first_trace_addr) catch |err| {
            std.debug.print("[panicFn] failed to write crash log: {}\n", .{err});
        };
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

const LoggerInternal = struct {
    const Self = @This();

    allocator: Allocator,
    io: std.Io,
    console_log_level: std.log.Level,
    file_log_level: std.log.Level,
    crash_log_path: []const u8,
    log_path: []const u8,
    io_group: std.Io.Group = .init,
    log_chan: BufferedChan([]const u8, 1000),
    log_write_mutex: std.Io.Mutex = .init,

    pub fn init(allocator: Allocator, io: std.Io) Allocator.Error!Self {
        const data_dir = try Util.get_app_data_dir(allocator, io);
        defer allocator.free(data_dir);

        const env_var = Env.get_env_var_owned(allocator, Env.SPACECAP_LOG_LEVEL);
        defer if (env_var) |val| allocator.free(val);

        const user_provided_log_level = read_log_level(env_var);
        const console_log_level = user_provided_log_level orelse std.log.default_level;
        const file_log_level = user_provided_log_level orelse .err;

        const crash_log_path = try std.fs.path.join(allocator, &.{ data_dir, CRASH_LOG_FILE_NAME });
        errdefer allocator.free(crash_log_path);

        const log_path = try std.fs.path.join(allocator, &.{ data_dir, log_file_name(file_log_level) });
        errdefer allocator.free(log_path);

        return .{
            .allocator = allocator,
            .io = io,
            .crash_log_path = crash_log_path,
            .console_log_level = console_log_level,
            .file_log_level = file_log_level,
            .log_path = log_path,
            .log_chan = try .init(allocator, io),
        };
    }

    pub fn deinit(self: *Self) void {
        self.io_group.await(self.io) catch {
            // No sense in logging here since it'll end up using this wait group.
            @panic("self.io_group.await error.");
        };
        self.log_chan.deinit();
        self.allocator.free(self.crash_log_path);
        self.allocator.free(self.log_path);
    }

    pub fn log(
        self: *Self,
        comptime level: std.log.Level,
        comptime scope: @EnumLiteral(),
        comptime format: []const u8,
        args: anytype,
    ) !void {
        if (@intFromEnum(self.console_log_level) >= @intFromEnum(level)) {
            std.log.defaultLog(level, scope, format, args);
        }

        if (@intFromEnum(self.file_log_level) >= @intFromEnum(level)) {
            try self.write_log(level, scope, format, args);
        }
    }

    /// Queues up messages and writes to the log file asynchronously. This must
    /// not block! If the queue is full, messages will be discarded. This is
    /// thread safe.
    fn write_log(
        self: *Self,
        comptime level: std.log.Level,
        comptime scope: @EnumLiteral(),
        comptime format: []const u8,
        args: anytype,
    ) !void {
        const timestamp = Util.format_timestamp_utc(std.Io.Timestamp.now(self.io, .real).toMilliseconds());
        const message = blk: {
            if (scope != .default) {
                break :blk try std.fmt.allocPrint(self.allocator, "[{s}] {s}({t}): " ++ format ++ "\n", .{ &timestamp, log_level_label(level), scope } ++ args);
            }
            break :blk try std.fmt.allocPrint(self.allocator, "[{s}] {s}: " ++ format ++ "\n", .{ &timestamp, log_level_label(level) } ++ args);
        };
        errdefer self.allocator.free(message);

        // We must use a queue so that logs get written in order.
        if (!try self.log_chan.try_send(message)) {
            self.allocator.free(message);
        }

        self.io_group.async(self.io, struct {
            fn run(_self: *Self) void {
                write_log_async(_self) catch {
                    // WARNING: This will fail silently. We can't really do anything
                    // here because logging a write failure could cause an endless loop.
                };
            }
        }.run, .{self});
    }

    /// This function executes asynchronously. Lock so that multiple handlers
    /// don't write logs out of order to a file.
    fn write_log_async(self: *Self) !void {
        self.log_write_mutex.lockUncancelable(self.io);
        defer self.log_write_mutex.unlock(self.io);

        var writer_buffer: [4096]u8 = undefined;
        const file = try std.Io.Dir.createFileAbsolute(self.io, self.log_path, .{ .truncate = false });
        defer file.close(self.io);

        var writer = file.writer(self.io, &writer_buffer);
        try writer.seekTo(try file.length(self.io));
        while (try self.log_chan.try_recv()) |message| {
            defer self.allocator.free(message);

            try writer.interface.writeAll(message);
        }
        try writer.flush();
        try file.sync(self.io);
    }

    // NOTE: There should be no allocations in here.
    pub fn write_panic(self: *Self, msg: []const u8, first_trace_addr: ?usize) !void {
        const file = try std.Io.Dir.createFileAbsolute(self.io, self.crash_log_path, .{ .truncate = false });
        defer file.close(self.io);

        var offset = try file.length(self.io);
        var buffer: [512]u8 = undefined;
        var trace_buffer: [4096]u8 = undefined;

        const timestamp = Util.format_timestamp_utc(std.Io.Timestamp.now(self.io, .real).toMilliseconds());
        const header = if (first_trace_addr) |addr|
            try std.fmt.bufPrint(
                &buffer,
                \\----------------------------------------------------------------------------
                \\  PANIC: {s}
                \\  address: 0x{x}
                \\  message: 
            ,
                .{ &timestamp, addr },
            )
        else
            try std.fmt.bufPrint(
                &buffer,
                \\----------------------------------------------------------------------------
                \\  PANIC: {s}
                \\  message: 
            ,
                .{&timestamp},
            );

        try file.writePositionalAll(self.io, header, offset);
        offset += header.len;
        try file.writePositionalAll(self.io, msg, offset);
        offset += msg.len;
        try file.writePositionalAll(self.io, "\n", offset);
        offset += 1;

        var writer = file.writer(self.io, &trace_buffer);
        try writer.seekTo(offset);
        const terminal = std.Io.Terminal{
            .writer = &writer.interface,
            .mode = .no_color,
        };

        try writer.interface.writeAll(
            \\  stack trace:
            \\
            \\
        );
        try std.debug.writeCurrentStackTrace(.{
            .first_address = first_trace_addr orelse @returnAddress(),
            .allow_unsafe_unwind = true,
        }, terminal);
        try writer.interface.writeAll(
            \\----------------------------------------------------------------------------
            \\
            \\
        );
        try writer.flush();

        try file.sync(self.io);
    }

    /// Read the log level from user input.
    fn read_log_level(spacecap_log_level: ?[]const u8) ?std.log.Level {
        if (spacecap_log_level) |log_level| {
            const trimmed = std.mem.trim(u8, log_level, &std.ascii.whitespace);
            if (std.ascii.eqlIgnoreCase(trimmed, "debug")) return .debug;
            if (std.ascii.eqlIgnoreCase(trimmed, "info")) return .info;
            if (std.ascii.eqlIgnoreCase(trimmed, "warning")) return .warn;
            if (std.ascii.eqlIgnoreCase(trimmed, "error")) return .err;
        }
        return null;
    }

    fn log_file_name(level: std.log.Level) []const u8 {
        return switch (level) {
            .err => "error.log",
            .warn => "warn.log",
            .info => "info.log",
            .debug => "debug.log",
        };
    }

    fn log_level_label(comptime level: std.log.Level) []const u8 {
        return switch (level) {
            .err => "error",
            .warn => "warn",
            .info => "info",
            .debug => "debug",
        };
    }
};
