const std = @import("std");
const VideoCaptureError = @import("../../video_capture.zig").VideoCaptureError;
const VideoCaptureSelection = @import("../../video_capture.zig").VideoCaptureSelection;
const TokenStorage = @import("../../../../common/linux/token_storage.zig");

const log = std.log.scoped(.portal);

const c = @import("../../../../tmp_bindings/libportal_bindings.zig");

fn free_maybe(ptr: ?*anyopaque) void {
    if (ptr != null) {
        c.g_free(ptr);
    }
}

fn free_error_maybe(err: ?*c.GError) void {
    if (err != null) {
        c.g_error_free(err);
    }
}

fn map_g_error(err: *c.GError) ?VideoCaptureError {
    // When the portal service is missing or the user cancels, match the old portal.zig errors.
    if (err.code == c.G_IO_ERROR_INVAL) {
        return VideoCaptureError.PortalServiceNotFound;
    }
    if (err.code == c.G_IO_ERROR_CANCELLED) {
        return VideoCaptureError.SourcePickerCancelled;
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
    io: std.Io,
    portal: *c.XdpPortal,
    session: ?*c.XdpSession = null,
    restore_token: ?[:0]u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Self {
        const portal = c.xdp_portal_new() orelse return error.XdpPortalNewFailed;

        const restore_token = TokenStorage.load_token_z(allocator, io, "restore_token") catch null;

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .portal = portal,
            .restore_token = restore_token,
        };
        return self;
    }

    pub fn select_source(self: *Self, selection: VideoCaptureSelection) (VideoCaptureError || anyerror)!u32 {
        // A stale restore token can fail before a session starts. Clear and continue.
        errdefer self.clear_restore_token();
        try self.create_session(selection);
        const node_id = try self.start_session(selection);
        return node_id;
    }

    pub fn open_pipewire_remote(self: *const Self) !i32 {
        if (self.session == null) {
            return error.SessionNotStarted;
        }

        const fd = c.xdp_session_open_pipewire_remote(self.session.?);

        if (fd < 0) {
            return error.OpenPipewireRemoteFailed;
        }

        return fd;
    }

    pub fn deinit(self: *Self) void {
        defer self.allocator.destroy(self);
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
    }

    const CreateSessionContext = struct {
        loop: *c.GMainLoop,
        session: ?*c.XdpSession = null,
        g_error: ?*c.GError = null,
    };

    fn create_session_callback(
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

    fn create_session(self: *Self, selection: VideoCaptureSelection) !void {
        if (self.session != null) {
            return error.SessionAlreadyExists;
        }

        // Keep portal callbacks on this worker thread's context. Running the
        // default context here can dispatch unrelated UI/tray GLib sources.
        const main_context = c.g_main_context_new() orelse return error.GMainContextNewFailed;
        defer c.g_main_context_unref(main_context);

        const loop = c.g_main_loop_new(main_context, 0) orelse return error.GMainLoopNewFailed;
        defer c.g_main_loop_unref(loop);
        var ctx = CreateSessionContext{ .loop = loop };

        const outputs: c.XdpOutputType = switch (selection) {
            .restore_session => c.XDP_OUTPUT_MONITOR | c.XDP_OUTPUT_WINDOW,
            .source_type => |source_type| switch (source_type) {
                .desktop => c.XDP_OUTPUT_MONITOR,
                .window => c.XDP_OUTPUT_WINDOW,
                .all => c.XDP_OUTPUT_MONITOR | c.XDP_OUTPUT_WINDOW,
            },
        };

        // libportal attaches async completion sources to the thread-default
        // context at call time.
        c.g_main_context_push_thread_default(main_context);
        c.xdp_portal_create_screencast_session(
            self.portal,
            outputs,
            c.XDP_SCREENCAST_FLAG_NONE,
            c.XDP_CURSOR_MODE_EMBEDDED,
            c.XDP_PERSIST_MODE_PERSISTENT,
            if (selection == .restore_session and self.restore_token != null) self.restore_token.?.ptr else null,
            null,
            create_session_callback,
            &ctx,
        );
        c.g_main_context_pop_thread_default(main_context);

        c.g_main_loop_run(loop);

        if (ctx.g_error) |err| {
            defer free_error_maybe(err);
            if (map_g_error(err)) |cerr| {
                return cerr;
            }
            return error.CreateScreencastSessionFailed;
        }

        const session = ctx.session orelse {
            return error.CreateScreencastSessionFailed;
        };

        self.session = session;
    }

    fn start_session_callback(
        source_object: ?*c.GObject,
        res: ?*c.GAsyncResult,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const ctx: *StartSessionContext = @ptrCast(@alignCast(user_data));
        var err: ?*c.GError = null;
        const success = c.xdp_session_start_finish(@ptrCast(source_object), res, &err) != 0;

        if (ctx.detached) {
            if (err) |gerr| {
                free_error_maybe(gerr);
            }
            ctx.deinit();
            return;
        }

        ctx.success = success;
        ctx.completed = true;
        ctx.g_error = err;
        if (ctx.loop) |loop| {
            c.g_main_loop_quit(loop);
        }
    }

    const StartSessionContext = struct {
        loop: ?*c.GMainLoop,
        cancellable: ?*c.GCancellable = null,
        success: bool = false,
        completed: bool = false,
        timed_out: bool = false,
        detached: bool = false,
        g_error: ?*c.GError = null,

        fn init(loop: *c.GMainLoop, cancellable: bool) !*StartSessionContext {
            // A restore timeout can return before libportal calls back. Use GLib
            // allocation so a late C callback can own and free this context.
            const ptr = c.g_malloc0(@sizeOf(StartSessionContext)) orelse return error.OutOfMemory;
            const self: *StartSessionContext = @ptrCast(@alignCast(ptr));
            self.* = .{ .loop = loop };
            if (cancellable) {
                self.cancellable = c.g_cancellable_new() orelse {
                    c.g_free(self);
                    return error.GCancellableNewFailed;
                };
            }
            return self;
        }

        fn deinit(self: *StartSessionContext) void {
            if (self.cancellable) |cancellable| {
                c.g_object_unref(cancellable);
                self.cancellable = null;
            }
            if (self.g_error) |err| {
                free_error_maybe(err);
                self.g_error = null;
            }
            c.g_free(self);
        }
    };

    fn restore_start_timeout_callback(user_data: ?*anyopaque) callconv(.c) c.gboolean {
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

    fn start_session(self: *Self, selection: VideoCaptureSelection) (VideoCaptureError || anyerror)!u32 {
        // Isolate this loop from the process default context; otherwise this
        // thread may dispatch unrelated GLib sources while waiting on the portal.
        const main_context = c.g_main_context_new() orelse return error.GMainContextNewFailed;
        defer c.g_main_context_unref(main_context);

        const loop = c.g_main_loop_new(main_context, 0) orelse return error.GMainLoopNewFailed;
        defer c.g_main_loop_unref(loop);

        var ctx: ?*StartSessionContext = try .init(
            loop,
            selection == .restore_session,
        );

        var restore_timeout_source: ?[*c]c.GSource = null;
        defer {
            if (restore_timeout_source) |source| {
                if (ctx) |active_ctx| {
                    if (!active_ctx.timed_out) {
                        c.g_source_destroy(source);
                    }
                }
                c.g_source_unref(source);
            }
            if (ctx) |active_ctx| {
                active_ctx.deinit();
            }
        }

        if (ctx.?.cancellable != null) {
            // g_timeout_add() always uses the global default context, so attach
            // an explicit timeout source to the private context instead.
            restore_timeout_source = c.g_timeout_source_new(SESSION_RESTORE_TIMEOUT_MS);
            if (restore_timeout_source == null) {
                return error.GTimeoutSourceNewFailed;
            }
            c.g_source_set_callback(restore_timeout_source.?, restore_start_timeout_callback, ctx.?, null);
            _ = c.g_source_attach(restore_timeout_source.?, main_context);
        }

        c.g_main_context_push_thread_default(main_context);
        defer c.g_main_context_pop_thread_default(main_context);

        c.xdp_session_start(
            self.session.?,
            null,
            ctx.?.cancellable,
            start_session_callback,
            ctx.?,
        );

        c.g_main_loop_run(loop);
        ctx.?.loop = null;

        if (ctx.?.timed_out) {
            if (!ctx.?.completed) {
                // The async callback may still arrive after we return. Transfer
                // ownership to that callback so shutdown is not blocked.
                ctx.?.detached = true;
                ctx = null;
            }
            return VideoCaptureError.SourcePickerCancelled;
        }

        if (ctx.?.g_error) |err| {
            if (map_g_error(err)) |cerr| {
                return cerr;
            }
            return error.StartSessionFailed;
        }

        if (!ctx.?.success) {
            return error.StartSessionFailed;
        }

        try self.update_restore_token(selection == .source_type);

        return try self.process_streams();
    }

    fn update_restore_token(self: *Self, clear_if_missing: bool) !void {
        const token_ptr = c.xdp_session_get_restore_token(self.session.?);
        defer free_maybe(token_ptr);
        if (token_ptr == null) {
            if (clear_if_missing) {
                self.clear_restore_token();
            }
            return;
        }

        const duped = try self.allocator.dupeZ(u8, std.mem.span(token_ptr));

        if (self.restore_token) |restore_token| {
            self.allocator.free(restore_token);
            self.restore_token = null;
        }
        self.restore_token = duped;

        TokenStorage.save_token(self.allocator, self.io, "restore_token", duped[0..duped.len]) catch |err| {
            log.err("failed to save restore token: {}", .{err});
        };
    }

    fn clear_restore_token(self: *Self) void {
        if (self.restore_token) |token| {
            self.allocator.free(token);
            self.restore_token = null;
        }
        TokenStorage.delete_token(self.allocator, self.io, "restore_token") catch |err| {
            log.warn("failed to delete restore token: {}", .{err});
        };
    }

    fn process_streams(self: *Self) !u32 {
        const streams = c.xdp_session_get_streams(self.session.?);
        if (streams == null) {
            return error.NoStreams;
        }
        defer c.g_variant_unref(streams);

        var iter: c.GVariantIter = undefined;
        _ = c.g_variant_iter_init(&iter, streams);

        var node_id: u32 = 0;
        var props: ?*c.GVariant = null;

        const has_stream = c.g_variant_iter_loop(&iter, "(u@a{sv})", &node_id, &props) != 0;
        if (!has_stream) {
            return error.NoStreams;
        }
        defer {
            if (props != null) {
                c.g_variant_unref(props.?);
            }
        }

        return node_id;
    }
};
