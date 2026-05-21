const std = @import("std");
const Store = @import("../../store/store.zig").Store;
const Ipc = @import("../ipc.zig").Ipc;
const IpcCommand = @import("../ipc.zig").IpcCommand;
const IpcServer = @import("./linux_ipc_server.zig").IpcServer;

const log = std.log.scoped(.linux_ipc);

pub const LinuxIpc = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    store: ?*Store,
    server: ?IpcServer = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: ?*Store) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .server = null,
        };
        return self;
    }

    pub fn deinit(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        defer self.allocator.destroy(self);
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }
    }

    pub fn start(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.server != null) {
            return;
        }

        const store = self.store orelse return error.StoreRequired;
        self.server = try IpcServer.init(self.allocator, self.io, store);
        errdefer {
            if (self.server) |*server| {
                server.deinit();
                self.server = null;
            }
        }
        try self.server.?.start();
    }

    pub fn send_command(context: *anyopaque, command: IpcCommand) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        try IpcServer.send_ipc_command(self.allocator, self.io, command);
    }

    pub fn ipc(self: *Self) Ipc {
        return .{
            .ptr = self,
            .vtable = &.{
                .start = start,
                .send_command = send_command,
                .deinit = deinit,
            },
        };
    }
};
