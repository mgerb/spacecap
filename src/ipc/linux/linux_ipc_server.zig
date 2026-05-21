const std = @import("std");
const assert = std.debug.assert;
const Store = @import("../../store/store.zig").Store;
const IpcCommand = @import("../ipc.zig").IpcCommand;

const SOCKET_FILE_NAME = "spacecap.sock";
const log = std.log.scoped(.linux_ipc_server);
const net = std.Io.net;
const posix = std.posix;

const RequestPayload = enum(u8) {
    wake = 0,
    save_replay = 1,
    start_replay_buffer = 2,
    stop_replay_buffer = 3,
    toggle_replay_buffer = 4,
    start_recording = 5,
    stop_recording = 6,
    toggle_recording = 7,

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
    io: std.Io,
    store: *Store,
    socket_path: ?[]u8 = null,
    listen_socket: ?net.Server = null,
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *Store) !Self {
        return .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .socket_path = try get_socket_path(allocator),
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
        self.listen_socket = bind_listening_socket(self.io, self.socket_path.?) catch |err| switch (err) {
            error.SocketAlreadyActive => {
                log.warn("[start] IPC server disabled: another process is listening on {s}", .{self.socket_path.?});
                return;
            },
            else => return err,
        };

        self.stop_requested.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, server_thread, .{self});
    }

    pub fn stop(self: *Self) void {
        if (self.listen_socket == null and self.thread == null) {
            return;
        }

        self.stop_requested.store(true, .release);

        if (self.socket_path) |socket_path| {
            const wake = connect_unix_socket(self.io, socket_path) catch null;
            if (wake) |stream| {
                defer stream.close(self.io);
                write_all(self.io, stream, &[_]u8{RequestPayload.wake.value()}) catch {};
            }
        }

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        if (self.listen_socket) |*listen_socket| {
            listen_socket.deinit(self.io);
            self.listen_socket = null;
        }

        if (self.socket_path) |socket_path| {
            remove_socket_file(self.io, socket_path) catch |err| {
                log.warn("[stop] failed to remove IPC socket file {s}: {}", .{ socket_path, err });
            };
        }
    }

    fn server_thread(self: *Self) void {
        assert(self.listen_socket != null);
        while (true) {
            if (self.stop_requested.load(.acquire)) {
                break;
            }

            const client_stream = self.listen_socket.?.accept(self.io) catch |err| {
                if (self.stop_requested.load(.acquire)) {
                    break;
                }
                switch (err) {
                    error.ConnectionAborted => continue,
                    else => {
                        log.err("[server_thread] IPC accept failed: {}", .{err});
                        continue;
                    },
                }
            };
            defer client_stream.close(self.io);

            handle_client(self, client_stream);
        }
    }

    fn handle_client(self: *Self, stream: net.Stream) void {
        var command_buffer: [1]u8 = undefined;
        const command_len = read_short(self.io, stream, &command_buffer) catch |err| switch (err) {
            error.ConnectionResetByPeer,
            => return,
            else => {
                log.warn("[handle_client] failed to read IPC command: {}", .{err});
                return;
            },
        };
        if (command_len == 0) {
            log.warn("[handle_client] command_len is 0", .{});
            return;
        }

        if (self.stop_requested.load(.acquire)) {
            return;
        }

        const payload = std.enums.fromInt(RequestPayload, command_buffer[0]) orelse {
            write_all(self.io, stream, &[_]u8{ResponsePayload.unknown_command.value()}) catch |err| {
                log.err("[handle_client] failed to write response: {}", .{err});
            };
            return;
        };

        log.info("[handle_client] message received: {}", .{payload});
        switch (payload) {
            // Used to close the socket.
            .wake => return,
            else => {
                dispatch_ipc_command(self.store, payload);
                write_all(self.io, stream, &[_]u8{ResponsePayload.ok.value()}) catch {};
                return;
            },
        }
    }

    /// Send a message to the server. This will only be used in
    /// Spacecap CLI mode (separate from the running process.
    pub fn send_ipc_command(allocator: std.mem.Allocator, io: std.Io, command: IpcCommand) !void {
        const socket_path = try get_socket_path(allocator);
        defer allocator.free(socket_path);
        log.debug("[send_ipc_command] using socket: {s}", .{socket_path});

        const stream = connect_unix_socket(io, socket_path) catch |err| switch (err) {
            error.FileNotFound,
            error.ConnectionRefused,
            => return error.SpacecapNotRunning,
            error.AccessDenied,
            error.PermissionDenied,
            => return error.IpcPermissionDenied,
            else => return err,
        };
        defer stream.close(io);

        const request_payload: RequestPayload = switch (command) {
            .save_replay => .save_replay,
            .start_replay_buffer => .start_replay_buffer,
            .stop_replay_buffer => .stop_replay_buffer,
            .toggle_replay_buffer => .toggle_replay_buffer,
            .start_recording => .start_recording,
            .stop_recording => .stop_recording,
            .toggle_recording => .toggle_recording,
        };
        try write_all(io, stream, &[_]u8{request_payload.value()});

        var response_buffer: [1]u8 = undefined;
        const response_len = read_short(io, stream, &response_buffer) catch |err| switch (err) {
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

        log.info("[send_ipc_command] response: {}", .{response_payload});

        switch (response_payload) {
            .ok => return,
            .request_failed => return error.RequestFailed,
            .unknown_command => return error.RequestRejected,
        }
    }

    fn bind_listening_socket(io: std.Io, socket_path: []const u8) !net.Server {
        var address = try net.UnixAddress.init(socket_path);
        return address.listen(io, .{ .kernel_backlog = 16 }) catch |err| switch (err) {
            error.AddressInUse => {
                const existing = connect_unix_socket(io, socket_path);
                if (existing) |stream| {
                    stream.close(io);
                    return error.SocketAlreadyActive;
                } else |_| {
                    try remove_socket_file(io, socket_path);
                    return try address.listen(io, .{ .kernel_backlog = 16 });
                }
            },
            else => return err,
        };
    }

    /// Must be freed by the caller.
    fn get_socket_path(allocator: std.mem.Allocator) ![]u8 {
        if (std.c.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
            return std.fs.path.join(allocator, &.{ std.mem.span(runtime_dir), SOCKET_FILE_NAME });
        }

        return std.fmt.allocPrint(allocator, "/tmp/spacecap-{}.sock", .{std.os.linux.getuid()});
    }

    fn remove_socket_file(io: std.Io, socket_path: []const u8) !void {
        std.Io.Dir.deleteFileAbsolute(io, socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    fn dispatch_ipc_command(store: *Store, command: RequestPayload) void {
        switch (command) {
            .wake => {},
            .save_replay => store.dispatch(.{ .capture = .save_replay }),
            .start_replay_buffer => store.dispatch(.{ .capture = .start_replay_buffer }),
            .stop_replay_buffer => store.dispatch(.{ .capture = .stop_replay_buffer }),
            .toggle_replay_buffer => {
                const is_replay_buffer_active = blk: {
                    const state_locked = store.state.lock();
                    defer state_locked.unlock();
                    break :blk state_locked.unwrap_ptr().capture.replay_buffer_active;
                };
                store.dispatch(.{ .capture = if (is_replay_buffer_active) .stop_replay_buffer else .start_replay_buffer });
            },
            .start_recording => store.dispatch(.{ .capture = .start_recording_to_disk }),
            .stop_recording => store.dispatch(.{ .capture = .stop_recording_to_disk }),
            .toggle_recording => {
                const recording_to_disk = blk: {
                    const state_locked = store.state.lock();
                    defer state_locked.unlock();
                    break :blk state_locked.unwrap_ptr().capture.recording_to_disk;
                };
                store.dispatch(.{ .capture = if (recording_to_disk) .stop_recording_to_disk else .start_recording_to_disk });
            },
        }
    }

    fn connect_unix_socket(io: std.Io, socket_path: []const u8) !net.Stream {
        _ = try net.UnixAddress.init(socket_path);

        const socket_fd = while (true) {
            const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
            switch (posix.errno(rc)) {
                .SUCCESS => break @as(posix.fd_t, @intCast(rc)),
                .INTR => continue,
                .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS, .NOMEM => return error.SystemResources,
                .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
                .PROTOTYPE => return error.SocketModeUnsupported,
                else => |err| return posix.unexpectedErrno(err),
            }
        };

        const stream: net.Stream = .{ .socket = .{
            .handle = socket_fd,
            .address = .{ .ip4 = .loopback(0) },
        } };
        errdefer stream.close(io);

        var address: posix.sockaddr.un = .{ .path = undefined };
        @memcpy(address.path[0..socket_path.len], socket_path);
        const path_len = if (address.path.len - socket_path.len > 0) blk: {
            address.path[socket_path.len] = 0;
            break :blk socket_path.len + 1;
        } else socket_path.len;
        const address_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + path_len);

        while (true) {
            switch (posix.errno(posix.system.connect(socket_fd, @ptrCast(&address), address_len))) {
                .SUCCESS => return stream,
                .INTR => continue,
                .CONNREFUSED => return error.ConnectionRefused,
                .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                .AGAIN, .INPROGRESS => return error.WouldBlock,
                .ACCES => return error.AccessDenied,
                .LOOP => return error.SymLinkLoop,
                .NOENT => return error.FileNotFound,
                .NOTDIR => return error.NotDir,
                .ROFS => return error.ReadOnlyFileSystem,
                .PERM => return error.PermissionDenied,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    fn read_short(io: std.Io, stream: net.Stream, buffer: []u8) !usize {
        var reader_buffer: [256]u8 = undefined;
        var reader = stream.reader(io, &reader_buffer);
        return reader.interface.readSliceShort(buffer) catch |err| return reader.err orelse err;
    }

    fn write_all(io: std.Io, stream: net.Stream, bytes: []const u8) !void {
        var writer_buffer: [256]u8 = undefined;
        var writer = stream.writer(io, &writer_buffer);
        writer.interface.writeAll(bytes) catch |err| return writer.err orelse err;
        writer.interface.flush() catch |err| return writer.err orelse err;
    }
};
