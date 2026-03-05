const std = @import("std");
const assert = std.debug.assert;
const StateActor = @import("../../state_actor.zig").StateActor;
const IpcCommand = @import("../ipc.zig").IpcCommand;

const SOCKET_FILE_NAME = "spacecap.sock";
const log = std.log.scoped(.linux_ipc_server);

const RequestPayload = enum(u8) {
    wake = 0,
    save_replay = 1,

    pub fn value(self: @This()) u8 {
        return @intFromEnum(self);
    }
};

const ResponsePayload = enum(u8) {
    ok = 0,
    unknown_command = 1,
    request_failed = 2,

    pub fn value(self: @This()) u8 {
        return @intFromEnum(self);
    }
};

pub const IpcServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    state_actor: *StateActor,
    socket_path: ?[]u8 = null,
    listen_socket: ?std.posix.socket_t = null,
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, state_actor: *StateActor) !Self {
        return .{
            .allocator = allocator,
            .state_actor = state_actor,
            .socket_path = try getSocketPath(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        if (self.socket_path) |socket_path| {
            self.allocator.free(socket_path);
            self.socket_path = null;
        }
    }

    pub fn start(self: *Self) !void {
        assert(self.socket_path != null);
        self.listen_socket = bindListeningSocket(self.socket_path.?) catch |err| switch (err) {
            error.SocketAlreadyActive => {
                log.warn("[start] IPC server disabled: another process is listening on {s}", .{self.socket_path.?});
                return;
            },
            else => return err,
        };

        self.stop_requested.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, serverThread, .{self});
    }

    pub fn stop(self: *Self) void {
        if (self.listen_socket == null and self.thread == null) {
            return;
        }

        self.stop_requested.store(true, .release);

        if (self.socket_path) |socket_path| {
            const wake = std.net.connectUnixSocket(socket_path) catch null;
            if (wake) |stream| {
                defer stream.close();
                stream.writeAll(&[_]u8{RequestPayload.wake.value()}) catch {};
            }
        }

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        if (self.listen_socket) |listen_socket| {
            std.posix.close(listen_socket);
            self.listen_socket = null;
        }

        if (self.socket_path) |socket_path| {
            removeSocketFile(socket_path) catch |err| {
                log.warn("[stop] failed to remove IPC socket file {s}: {}", .{ socket_path, err });
            };
        }
    }

    fn serverThread(self: *Self) void {
        assert(self.listen_socket != null);
        while (true) {
            if (self.stop_requested.load(.acquire)) {
                break;
            }

            const client_socket = std.posix.accept(
                self.listen_socket.?,
                null,
                null,
                std.posix.SOCK.CLOEXEC,
            ) catch |err| {
                if (self.stop_requested.load(.acquire)) {
                    break;
                }
                switch (err) {
                    error.ConnectionAborted,
                    error.ConnectionResetByPeer,
                    => continue,
                    else => {
                        log.err("[serverThread] IPC accept failed: {}", .{err});
                        continue;
                    },
                }
            };
            defer std.posix.close(client_socket);

            handleClient(self, client_socket);
        }
    }

    fn handleClient(self: *Self, client_socket: std.posix.socket_t) void {
        const stream: std.net.Stream = .{ .handle = client_socket };
        var command_buffer: [1]u8 = undefined;
        const command_len = stream.read(&command_buffer) catch |err| switch (err) {
            error.ConnectionResetByPeer,
            => return,
            else => {
                log.warn("[handleClient] failed to read IPC command: {}", .{err});
                return;
            },
        };
        if (command_len == 0) {
            log.warn("[handleClient] command_len is 0", .{});
            return;
        }

        if (self.stop_requested.load(.acquire)) {
            return;
        }

        const payload = std.enums.fromInt(RequestPayload, command_buffer[0]) orelse {
            stream.writeAll(&[_]u8{ResponsePayload.unknown_command.value()}) catch |err| {
                log.err("[handleClient] failed to write response: {}", .{err});
            };
            return;
        };

        log.info("[handleClient] message received: {}", .{payload});
        switch (payload) {
            // Used to close the socket.
            .wake => return,
            .save_replay => {
                self.state_actor.dispatch(.save_replay) catch |err| {
                    log.err("[handleClient] failed to dispatch save_replay from IPC command: {}", .{err});
                    stream.writeAll(&[_]u8{ResponsePayload.request_failed.value()}) catch {};
                    return;
                };
                stream.writeAll(&[_]u8{ResponsePayload.ok.value()}) catch {};
                return;
            },
        }
    }

    /// Send a message to the server. This will only be used in
    /// Spacecap CLI mode (separate from the running process.
    pub fn sendIpcCommand(allocator: std.mem.Allocator, command: IpcCommand) !void {
        const socket_path = try getSocketPath(allocator);
        defer allocator.free(socket_path);
        log.debug("[sendIpcCommand] using socket: {s}", .{socket_path});

        const stream = std.net.connectUnixSocket(socket_path) catch |err| switch (err) {
            error.FileNotFound,
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            => return error.SpacecapNotRunning,
            error.AccessDenied,
            error.PermissionDenied,
            => return error.IpcPermissionDenied,
            else => return err,
        };
        defer stream.close();

        const request_payload: RequestPayload = switch (command) {
            .save_replay => .save_replay,
        };
        try stream.writeAll(&[_]u8{request_payload.value()});

        var response_buffer: [1]u8 = undefined;
        const response_len = stream.read(&response_buffer) catch |err| switch (err) {
            error.ConnectionResetByPeer,
            => return error.RequestFailed,
            else => return err,
        };
        if (response_len == 0) {
            return error.EmptyResponse;
        }

        const response_payload = std.enums.fromInt(ResponsePayload, response_buffer[0]) orelse {
            return error.InvalidResponse;
        };

        log.info("[sendIpcCommand] response: {}", .{response_payload});

        switch (response_payload) {
            .ok => return,
            .request_failed => return error.RequestFailed,
            .unknown_command => return error.RequestRejected,
        }
    }

    fn bindListeningSocket(socket_path: []const u8) !std.posix.socket_t {
        const listen_socket = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            0,
        );
        errdefer std.posix.close(listen_socket);

        var address = try std.net.Address.initUnix(socket_path);
        std.posix.bind(listen_socket, &address.any, address.getOsSockLen()) catch |err| switch (err) {
            error.AddressInUse => {
                const existing = std.net.connectUnixSocket(socket_path);
                if (existing) |stream| {
                    stream.close();
                    return error.SocketAlreadyActive;
                } else |connect_err| switch (connect_err) {
                    error.ConnectionRefused,
                    error.FileNotFound,
                    => {
                        try removeSocketFile(socket_path);
                        try std.posix.bind(listen_socket, &address.any, address.getOsSockLen());
                    },
                    else => return err,
                }
            },
            else => return err,
        };

        try std.posix.listen(listen_socket, 16);
        return listen_socket;
    }

    /// Must be freed by the caller.
    fn getSocketPath(allocator: std.mem.Allocator) ![]u8 {
        if (std.posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
            return std.fs.path.join(allocator, &.{ runtime_dir, SOCKET_FILE_NAME });
        }

        return std.fmt.allocPrint(allocator, "/tmp/spacecap-{}.sock", .{std.posix.getuid()});
    }

    fn removeSocketFile(socket_path: []const u8) !void {
        std.fs.cwd().deleteFile(socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};
