const std = @import("std");
const VideoCaptureError = @import("../../video_capture.zig").VideoCaptureError;
const VideoCaptureSourceType = @import("../../video_capture.zig").VideoCaptureSourceType;
const TokenStorage = @import("../../../../common/linux/token_storage.zig");

const log = std.log.scoped(.portal);

const c = @cImport({
    @cInclude("libportal/portal.h");
});

fn freeMaybe(ptr: ?*anyopaque) void {
    if (ptr != null) {
        c.g_free(ptr);
    }
}

fn freeErrorMaybe(err: ?*c.GError) void {
    if (err != null) {
        c.g_error_free(err);
    }
}

fn mapGError(err: *c.GError) ?VideoCaptureError {
    // When the portal service is missing or the user cancels, match the old portal.zig errors.
    if (err.code == c.G_IO_ERROR_INVAL) {
        return VideoCaptureError.portal_service_not_found;
    }
    if (err.code == c.G_IO_ERROR_CANCELLED) {
        return VideoCaptureError.source_picker_cancelled;
    }
    return null;
}

pub const Portal = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    portal: *c.XdpPortal,
    session: ?*c.XdpSession = null,
    restore_token: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const portal = c.xdp_portal_new() orelse return error.xdp_portal_new_failed;

        const restore_token = TokenStorage.loadToken(allocator, "restore_token") catch null;

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .portal = portal,
            .restore_token = restore_token,
        };
        return self;
    }

    pub fn selectSource(
        self: *Self,
        source_type: VideoCaptureSourceType,
    ) (VideoCaptureError || anyerror)!u32 {
        try self.createSession(source_type);
        return try self.startSession();
    }

    pub fn openPipewireRemote(self: *const Self) !i32 {
        if (self.session == null) {
            return error.session_not_started;
        }

        const fd = c.xdp_session_open_pipewire_remote(self.session.?);

        if (fd < 0) {
            return error.open_pipewire_remote_failed;
        }

        return fd;
    }

    pub fn deinit(self: *Self) void {
        if (self.session) |session| {
            c.xdp_session_close(session);
            c.g_object_unref(session);
            self.session = null;
        }

        c.g_object_unref(self.portal);

        if (self.restore_token) |token| {
            self.allocator.free(token);
        }

        self.allocator.destroy(self);
    }

    const CreateSessionContext = struct {
        loop: *c.GMainLoop,
        session: ?*c.XdpSession = null,
        g_error: ?*c.GError = null,
    };

    fn createSessionCallback(
        source_object: ?*c.GObject,
        res: ?*c.GAsyncResult,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const ctx: *CreateSessionContext = @ptrCast(@alignCast(user_data));
        var err: ?*c.GError = null;
        ctx.session = c.xdp_portal_create_screencast_session_finish(@ptrCast(source_object), res, &err);
        ctx.g_error = err;
        c.g_main_loop_quit(ctx.loop);
    }

    fn createSession(self: *Self, source_type: VideoCaptureSourceType) !void {
        if (self.session != null) {
            return;
        }

        const loop = c.g_main_loop_new(null, 0) orelse return error.g_main_loop_new_failed;
        var ctx = CreateSessionContext{ .loop = loop };

        const outputs: c.XdpOutputType = switch (source_type) {
            .desktop => c.XDP_OUTPUT_MONITOR,
            .window => c.XDP_OUTPUT_WINDOW,
        };

        c.xdp_portal_create_screencast_session(
            self.portal,
            outputs,
            c.XDP_SCREENCAST_FLAG_NONE,
            c.XDP_CURSOR_MODE_EMBEDDED,
            c.XDP_PERSIST_MODE_PERSISTENT,
            if (self.restore_token) |token| token.ptr else null,
            null,
            createSessionCallback,
            &ctx,
        );

        c.g_main_loop_run(loop);
        c.g_main_loop_unref(loop);

        if (ctx.g_error) |err| {
            defer freeErrorMaybe(err);
            if (mapGError(err)) |cerr| {
                return cerr;
            }
            return error.create_screencast_session_failed;
        }

        if (ctx.session == null) {
            return error.create_screencast_session_failed;
        }

        self.session = ctx.session;
    }

    const StartSessionContext = struct {
        loop: *c.GMainLoop,
        session: *c.XdpSession,
        success: bool = false,
        g_error: ?*c.GError = null,
    };

    fn startSessionCallback(
        source_object: ?*c.GObject,
        res: ?*c.GAsyncResult,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        _ = source_object;
        const ctx: *StartSessionContext = @ptrCast(@alignCast(user_data));
        var err: ?*c.GError = null;
        ctx.success = c.xdp_session_start_finish(ctx.session, res, &err) != 0;
        ctx.g_error = err;
        c.g_main_loop_quit(ctx.loop);
    }

    fn startSession(self: *Self) (VideoCaptureError || anyerror)!u32 {
        const loop = c.g_main_loop_new(null, 0) orelse return error.g_main_loop_new_failed;
        var ctx = StartSessionContext{
            .loop = loop,
            .session = self.session.?,
        };

        c.xdp_session_start(
            self.session.?,
            null,
            null,
            startSessionCallback,
            &ctx,
        );

        c.g_main_loop_run(loop);
        c.g_main_loop_unref(loop);

        if (ctx.g_error) |err| {
            defer freeErrorMaybe(err);
            if (mapGError(err)) |cerr| {
                return cerr;
            }
            return error.start_session_failed;
        }

        if (!ctx.success) {
            return error.start_session_failed;
        }

        try self.updateRestoreToken();

        return try self.processStreams();
    }

    fn updateRestoreToken(self: *Self) !void {
        const token_ptr = c.xdp_session_get_restore_token(self.session.?);
        defer freeMaybe(token_ptr);
        if (token_ptr == null) {
            return;
        }

        const duped = try self.allocator.dupe(u8, std.mem.span(token_ptr));

        if (self.restore_token) |old| {
            self.allocator.free(old);
        }
        self.restore_token = duped;

        TokenStorage.saveToken(self.allocator, "restore_token", duped[0..duped.len]) catch |err| {
            log.err("failed to save restore token: {}", .{err});
        };
    }

    fn processStreams(self: *Self) !u32 {
        const streams = c.xdp_session_get_streams(self.session.?);
        if (streams == null) {
            return error.no_streams;
        }
        defer c.g_variant_unref(streams);

        var iter: c.GVariantIter = undefined;
        _ = c.g_variant_iter_init(&iter, streams);

        var node_id: u32 = 0;
        var props: ?*c.GVariant = null;

        const has_stream = c.g_variant_iter_loop(&iter, "(u@a{sv})", &node_id, &props) != 0;
        if (!has_stream) {
            return error.no_streams;
        }
        defer {
            if (props != null) {
                c.g_variant_unref(props.?);
            }
        }

        return node_id;
    }
};
