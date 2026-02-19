const std = @import("std");
const VideoCaptureError = @import("../../video_capture.zig").VideoCaptureError;
const VideoCaptureSelection = @import("../../video_capture.zig").VideoCaptureSelection;
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

/// HACK: This is a bit of a hack. When the app starts up it tries to start a capture session
/// if there was a capture session when the app closed. It does this by checking the restore
/// token. There is no way of knowing that a restore token applies to a valid window. If it
/// doesn't, then the desktop portal screencast popup will open (seems like there is no way
/// to prevent this). This timeout will wait this long for the session to be restored, and
/// if it doesn't start, then it will be cancelled so that the source picker closes. This
/// will only occur during app startup if there is a cached refresh token.
/// This will cause the source picker to flash for this long upon app startup, but there
/// don't seem like many other options at this point. Maybe we can revisit this later.
const SESSION_RESTORE_TIMEOUT_MS = 250;

pub const Portal = struct {
    const Self = @This();
    // Successful restore starts should return quickly. If they stall, assume the
    // portal is falling back to the interactive picker and cancel instead.
    allocator: std.mem.Allocator,
    portal: *c.XdpPortal,
    session: ?*c.XdpSession = null,
    restore_token: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const portal = c.xdp_portal_new() orelse return error.xdp_portal_new_failed;

        const restore_token = TokenStorage.loadToken(allocator, "restore_token") catch null;

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .portal = portal,
            .restore_token = restore_token,
        };
        return self;
    }

    pub fn selectSource(self: *Self, selection: VideoCaptureSelection) (VideoCaptureError || anyerror)!u32 {
        // A stale restore token can fail before a session starts. Clear and continue.
        errdefer self.clearRestoreToken();
        try self.createSession(selection);
        const node_id = try self.startSession(selection);
        return node_id;
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
            self.restore_token = null;
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

    fn createSession(self: *Self, selection: VideoCaptureSelection) !void {
        if (self.session != null) {
            return error.session_already_exists;
        }

        const loop = c.g_main_loop_new(null, 0) orelse return error.g_main_loop_new_failed;
        var ctx = CreateSessionContext{ .loop = loop };

        const outputs: c.XdpOutputType = switch (selection) {
            .restore_session => c.XDP_OUTPUT_MONITOR | c.XDP_OUTPUT_WINDOW,
            .source_type => |source_type| switch (source_type) {
                .desktop => c.XDP_OUTPUT_MONITOR,
                .window => c.XDP_OUTPUT_WINDOW,
            },
        };

        c.xdp_portal_create_screencast_session(
            self.portal,
            outputs,
            c.XDP_SCREENCAST_FLAG_NONE,
            c.XDP_CURSOR_MODE_EMBEDDED,
            c.XDP_PERSIST_MODE_PERSISTENT,
            if (selection == .restore_session and self.restore_token != null) self.restore_token.?.ptr else null,
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
        allocator: std.mem.Allocator,
        loop: ?*c.GMainLoop,
        session: *c.XdpSession,
        cancellable: ?*c.GCancellable = null,
        success: bool = false,
        completed: bool = false,
        timed_out: bool = false,
        detached: bool = false,
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
        const success = c.xdp_session_start_finish(ctx.session, res, &err) != 0;

        if (ctx.detached) {
            if (err) |gerr| {
                freeErrorMaybe(gerr);
            }
            return;
        }

        ctx.success = success;
        ctx.completed = true;
        ctx.g_error = err;
        if (ctx.loop) |loop| {
            c.g_main_loop_quit(loop);
        }
    }

    fn restoreStartTimeoutCallback(user_data: ?*anyopaque) callconv(.c) c.gboolean {
        const ctx: *StartSessionContext = @ptrCast(@alignCast(user_data));
        ctx.timed_out = true;
        if (ctx.cancellable) |gc| {
            c.g_cancellable_cancel(gc);
        }
        if (ctx.loop) |loop| {
            c.g_main_loop_quit(loop);
        }
        return 0;
    }

    fn startSession(self: *Self, selection: VideoCaptureSelection) (VideoCaptureError || anyerror)!u32 {
        const loop = c.g_main_loop_new(null, 0) orelse return error.g_main_loop_new_failed;
        const ctx = try self.allocator.create(StartSessionContext);
        defer self.allocator.destroy(ctx);
        ctx.* = .{
            .allocator = self.allocator,
            .loop = loop,
            .session = self.session.?,
            .cancellable = if (selection == .restore_session) c.g_cancellable_new() else null,
        };

        var restore_timeout_id: ?c_uint = null;
        defer {
            if (!ctx.timed_out) {
                if (restore_timeout_id) |id| {
                    _ = c.g_source_remove(id);
                }
            }
            if (ctx.cancellable) |cancellable| {
                c.g_object_unref(cancellable);
                ctx.cancellable = null;
            }
            c.g_main_loop_unref(loop);
        }

        if (ctx.cancellable != null) {
            restore_timeout_id = c.g_timeout_add(SESSION_RESTORE_TIMEOUT_MS, restoreStartTimeoutCallback, ctx);
        }

        c.xdp_session_start(
            self.session.?,
            null,
            ctx.cancellable,
            startSessionCallback,
            ctx,
        );

        c.g_main_loop_run(loop);
        ctx.loop = null;

        if (ctx.timed_out and !ctx.completed) {
            // The restore attempt likely fell through to the interactive picker.
            // Return immediately and let a late callback free the detached context.
            ctx.detached = true;
            return VideoCaptureError.source_picker_cancelled;
        }

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

        try self.updateRestoreToken(selection == .source_type);

        return try self.processStreams();
    }

    fn updateRestoreToken(self: *Self, clear_if_missing: bool) !void {
        const token_ptr = c.xdp_session_get_restore_token(self.session.?);
        defer freeMaybe(token_ptr);
        if (token_ptr == null) {
            if (clear_if_missing) {
                self.clearRestoreToken();
            }
            return;
        }

        const duped = try self.allocator.dupe(u8, std.mem.span(token_ptr));

        if (self.restore_token) |restore_token| {
            self.allocator.free(restore_token);
            self.restore_token = null;
        }
        self.restore_token = duped;

        TokenStorage.saveToken(self.allocator, "restore_token", duped[0..duped.len]) catch |err| {
            log.err("failed to save restore token: {}", .{err});
        };
    }

    fn clearRestoreToken(self: *Self) void {
        if (self.restore_token) |token| {
            self.allocator.free(token);
            self.restore_token = null;
        }
        TokenStorage.deleteToken(self.allocator, "restore_token") catch |err| {
            log.warn("failed to delete restore token: {}", .{err});
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
