const std = @import("std");
const c = @import("./pipewire_include.zig").c;
const c_def = @import("./pipewire_include.zig").c_def;
const CaptureError = @import("../../capture_error.zig").CaptureError;
const TokenManager = @import("./token_manager.zig").TokenManager;
const UserSettings = @import("../../../user_settings.zig");
const CaptureSourceType = @import("../../capture.zig").CaptureSourceType;

/// check for specific error codes, otherwise default to return_error
fn handleGError(err: ?*c.GError, comptime return_error: anyerror!void) !void {
    if (err) |e| {
        std.debug.print("GError: {}, message: {s}\n", .{ e, e.message });
        // This error SHOULD mean that org.freedesktop.portal.Desktop is not available
        if (e.code == c.G_IO_ERROR_INVAL) {
            return CaptureError.portal_service_not_found;
        }
        return return_error;
    }
}

fn freeMaybe(ptr: ?*anyopaque) void {
    if (ptr != null) c.g_free(ptr);
}

fn unrefMaybe(ptr: ?*anyopaque) void {
    if (ptr != null) c.g_object_unref(ptr);
}

pub const Portal = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    conn: ?*c.GDBusConnection = null,
    screen_cast: ?*c.GDBusProxy = null,
    sender_name: ?[:0]u8 = null,
    session_handle: ?[*c]u8 = null,
    restore_token: ?[]u8 = null,
    selected_screen_name: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
    ) !*Self {
        var err: ?*c.GError = null;
        defer freeMaybe(err);
        const conn = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, @ptrCast(&err));
        try handleGError(err, error.g_bus_get_sync);

        const unique_name = c.g_dbus_connection_get_unique_name(conn);

        if (unique_name == null) {
            return error.g_dbus_connection_get_unique_name;
        }

        std.debug.print("name: {s}\n", .{unique_name});

        const len = std.mem.len(unique_name);
        const sender_name: [:0]u8 = try allocator.allocSentinel(u8, len - 1, 0);
        std.mem.copyForwards(u8, sender_name, unique_name[1..len]);

        for (sender_name) |*s| {
            if (s.* == '.') {
                s.* = '_';
            }
        }
        errdefer allocator.free(sender_name);

        std.debug.print("sender_name: {s}\n", .{sender_name});

        const screen_cast = c.g_dbus_proxy_new_sync(
            conn,
            c.G_DBUS_PROXY_FLAGS_NONE,
            null,
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.ScreenCast",
            null,
            &err,
        );
        try handleGError(err, error.g_bus_get_sync);
        errdefer unrefMaybe(screen_cast);

        const restore_token = readRestoreTokenFromFile(allocator) catch |_err| blk: {
            std.debug.print("error reading restore token file: {}\n", .{_err});
            break :blk null;
        };

        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .conn = conn,
            .sender_name = sender_name,
            .screen_cast = screen_cast,
            .restore_token = restore_token,
        };

        return self;
    }

    pub fn createScreenCastSession(self: *Self) !void {
        std.debug.print("create_screen_cast_session\n", .{});

        const request_tokens = try TokenManager.getRequestTokens(self.allocator, self.sender_name.?);
        defer request_tokens.deinit();
        std.debug.print("request path: {s}, request token: {s}\n", .{ request_tokens.path, request_tokens.token });

        const session_token = try TokenManager.getSessionToken(self.allocator);
        defer session_token.deinit();

        std.debug.print("session token: {s}\n", .{session_token.path});

        var callback = std.mem.zeroes(DBusCallback);

        self.callbackRegister(&callback, request_tokens.path, Portal.createSessionCallback);
        defer self.callbackUnregister(&callback);

        std.debug.print("db id: {}\n", .{callback.id});

        var builder = std.mem.zeroes(c.GVariantBuilder);
        c.g_variant_builder_init(&builder, c_def.G_VARIANT_TYPE_VARDICT);
        c.g_variant_builder_add(&builder, "{sv}", "handle_token", c.g_variant_new_string(request_tokens.token.ptr));
        c.g_variant_builder_add(&builder, "{sv}", "session_handle_token", c.g_variant_new_string(session_token.path.ptr));
        var err: ?*c.GError = null;
        defer freeMaybe(err);
        const response = c.g_dbus_proxy_call_sync(
            self.screen_cast,
            "CreateSession",
            c.g_variant_new("(a{sv})", &builder),
            c.G_DBUS_CALL_FLAGS_NONE,
            -1,
            null,
            &err,
        );
        defer freeMaybe(response);

        try handleGError(err, error.g_dbus_proxy_call_sync);

        while (!callback.completed) {
            _ = c.g_main_context_iteration(null, 1);
        }

        const handle: [*c]u8 = @ptrCast(callback.opaque_);
        defer freeMaybe(handle);
        const len = std.mem.len(handle);
        const session_handle = try self.allocator.allocSentinel(u8, len, 0);
        std.mem.copyForwards(u8, session_handle, handle[0..len]);
        self.session_handle = session_handle;

        std.debug.print("session_handle: {?s}\ngdb: {}\n", .{ self.session_handle, callback });
    }

    pub fn selectSource(
        self: *Self,
        source_type: CaptureSourceType,
    ) !u32 {
        if (self.session_handle == null) {
            try self.createScreenCastSession();
        }

        const request_tokens = try TokenManager.getRequestTokens(self.allocator, self.sender_name.?);
        defer request_tokens.deinit();

        var callback = std.mem.zeroes(DBusCallback);
        self.callbackRegister(&callback, request_tokens.path, Portal.selectSourceCallback);
        defer self.callbackUnregister(&callback);

        var builder = std.mem.zeroes(c.GVariantBuilder);
        c.g_variant_builder_init(&builder, c_def.G_VARIANT_TYPE_VARDICT);

        const source: u32 = switch (source_type) {
            .desktop => c_def.PIPEWIRE_CAPTURE_DESKTOP,
            .window => c_def.PIPEWIRE_CAPTURE_WINDOW,
        };

        c.g_variant_builder_add(&builder, "{sv}", "types", c.g_variant_new_uint32(source));
        c.g_variant_builder_add(&builder, "{sv}", "multiple", c.g_variant_new_boolean(c.FALSE));
        c.g_variant_builder_add(&builder, "{sv}", "persist_mode", c.g_variant_new_uint32(2));
        c.g_variant_builder_add(&builder, "{sv}", "handle_token", c.g_variant_new_string(request_tokens.token));

        if (self.restore_token) |restore_token| {
            c.g_variant_builder_add(&builder, "{sv}", "restore_token", c.g_variant_new_string(restore_token.ptr));
        }

        const cursor_modes_ = c.g_dbus_proxy_get_cached_property(self.screen_cast, "AvailableCursorModes");
        const cursor_modes = if (cursor_modes_ != null) c.g_variant_get_uint32(cursor_modes_) else 0;

        // NOTE: not supporting mode 4
        std.debug.print("cursor_mode: {}\n", .{cursor_modes});
        if (cursor_modes & 2 > 0) {
            c.g_variant_builder_add(&builder, "{sv}", "cursor_mode", c.g_variant_new_uint32(2));
        } else if (cursor_modes & 1 > 0) {
            c.g_variant_builder_add(&builder, "{sv}", "cursor_mode", c.g_variant_new_uint32(1));
        } else {
            return error.no_cursor_mode_found;
        }

        var err: ?*c.GError = null;
        defer freeMaybe(err);
        const response = c.g_dbus_proxy_call_sync(
            self.screen_cast,
            "SelectSources",
            c.g_variant_new("(oa{sv})", self.session_handle.?, &builder),
            c.G_DBUS_CALL_FLAGS_NONE,
            -1,
            null,
            &err,
        );
        defer freeMaybe(response);

        try handleGError(err, error.g_dbus_proxy_call_sync);

        while (!callback.completed) {
            _ = c.g_main_context_iteration(null, 1);
        }

        if (@intFromPtr(callback.opaque_) == 0) {
            return error.selectSourceError;
        }

        return try self.startSourcePicker();
    }

    const DBusCallback = extern struct {
        id: u32 = 0,
        completed: bool = false,
        opaque_: ?*anyopaque = null,
        cancelled: bool = false,
    };

    fn createSessionCallback(
        conn: ?*c.GDBusConnection,
        sender_name: [*c]const u8,
        object_path: [*c]const u8,
        interface_name: [*c]const u8,
        signal_name: [*c]const u8,
        params: ?*c.GVariant,
        opaque_: ?*anyopaque,
    ) callconv(.c) void {
        _ = conn;
        _ = sender_name;
        _ = object_path;
        _ = interface_name;
        _ = signal_name;
        std.debug.print("[createSessionCallback]\n", .{});
        const callback: *DBusCallback = @alignCast(@ptrCast(opaque_));
        var status: u32 = undefined;
        var result: ?*c.GVariant = null;
        defer freeMaybe(result);
        c.g_variant_get(params, "(u@a{sv})", &status, &result);

        if (status != 0) {
            std.debug.print("g_variant_get error: {}\n", .{status});
        }

        const session_handle_variant = c.g_variant_lookup_value(result, "session_handle", null);
        defer freeMaybe(session_handle_variant);
        callback.opaque_ = c.g_variant_dup_string(session_handle_variant, null);

        callback.completed = true;
    }

    const SourcePickerContext = struct {
        portal: *Self,
        result: *u32,
    };

    fn startSourcePicker(self: *Self) (CaptureError || anyerror)!u32 {
        const request_tokens = try TokenManager.getRequestTokens(self.allocator, self.sender_name.?);
        defer request_tokens.deinit();

        var callback = std.mem.zeroes(DBusCallback);
        var result: u32 = 0;
        var context = SourcePickerContext{
            .portal = self,
            .result = &result,
        };
        callback.opaque_ = &context;
        self.callbackRegister(&callback, request_tokens.path, Portal.sourcePickerCallback);
        defer self.callbackUnregister(&callback);
        var builder = std.mem.zeroes(c.GVariantBuilder);
        c.g_variant_builder_init(&builder, c_def.G_VARIANT_TYPE_VARDICT);
        c.g_variant_builder_add(&builder, "{sv}", "handle_token", c.g_variant_new_string(request_tokens.token));

        if (self.restore_token) |restore_token| {
            c.g_variant_builder_add(&builder, "{sv}", "restore_token", c.g_variant_new_string(restore_token.ptr));
        }

        var err: ?*c.GError = null;
        defer freeMaybe(err);
        const response = c.g_dbus_proxy_call_sync(
            self.screen_cast,
            "Start",
            c.g_variant_new("(osa{sv})", self.session_handle.?, "", &builder),
            c.G_DBUS_CALL_FLAGS_NONE,
            -1,
            null,
            &err,
        );
        defer freeMaybe(response);

        try handleGError(err, error.g_dbus_proxy_call_sync);

        while (!callback.completed) {
            _ = c.g_main_context_iteration(null, 1);
        }

        if (callback.cancelled) {
            return CaptureError.source_picker_cancelled;
        }

        return result;
    }

    pub fn openPipewireRemote(self: *const Self) !i32 {
        var err: ?*c.GError = null;
        defer freeMaybe(err);
        var fd_list: ?*c.GUnixFDList = null;
        defer unrefMaybe(fd_list);

        var builder = std.mem.zeroes(c.GVariantBuilder);
        c.g_variant_builder_init(&builder, c_def.G_VARIANT_TYPE_VARDICT);

        const response = c.g_dbus_proxy_call_with_unix_fd_list_sync(
            self.screen_cast,
            "OpenPipeWireRemote",
            c.g_variant_new("(oa{sv})", self.session_handle.?, &builder),
            c.G_DBUS_CALL_FLAGS_NONE,
            -1,
            null,
            &fd_list,
            null,
            &err,
        );
        defer freeMaybe(response);
        try handleGError(err, error.g_dbus_proxy_call_with_unix_fd_list_sync);

        var index: i32 = undefined;
        c.g_variant_get(response, "(h)", &index, &err);

        try handleGError(err, error.g_variant_get);

        const fd = c.g_unix_fd_list_get(fd_list, index, &err);

        try handleGError(err, error.g_unix_fd_list_get);

        return fd;
    }

    fn sourcePickerCallback(
        conn: ?*c.GDBusConnection,
        sender_name: [*c]const u8,
        object_path: [*c]const u8,
        interface_name: [*c]const u8,
        signal_name: [*c]const u8,
        params: ?*c.GVariant,
        opaque_: ?*anyopaque,
    ) callconv(.c) void {
        _ = conn;
        _ = sender_name;
        _ = object_path;
        _ = interface_name;
        _ = signal_name;
        std.debug.print("[sourcePickerCallback]", .{});
        const callback: *DBusCallback = @alignCast(@ptrCast(opaque_));
        const context: *SourcePickerContext = @alignCast(@ptrCast(callback.opaque_));
        const self = context.portal;
        callback.completed = true;

        var status: u32 = undefined;
        var result: ?*c.GVariant = null;
        defer freeMaybe(result);
        c.g_variant_get(params, "(u@a{sv})", &status, &result);

        if (status != 0) {
            std.debug.print("g_variant_get error: {}\n", .{status});
            callback.cancelled = true;
            return;
        }

        const streams = c.g_variant_lookup_value(result, "streams", c_def.G_VARIANT_TYPE_ARRAY);
        defer freeMaybe(streams);

        const token_variant = c.g_variant_lookup_value(result, "restore_token", c.g_variant_type_new("s"));
        defer freeMaybe(token_variant);

        if (token_variant != null) {
            const token_str = c.g_variant_get_string(token_variant, null);
            const token_len = std.mem.len(token_str);
            const new_token = self.allocator.alloc(u8, token_len) catch unreachable;
            std.mem.copyForwards(u8, new_token, token_str[0..token_len]);
            if (self.restore_token) |restore_token| {
                self.allocator.free(restore_token);
            }
            self.restore_token = new_token;
            std.debug.print("restore_token: {s}", .{self.restore_token.?});
            writeRestoreTokenToFile(self.allocator, new_token) catch |err| {
                std.debug.print("write restore_token error: {}\n", .{err});
            };
        } else {
            std.debug.print("No restore_token found", .{});
        }

        var iter: c.GVariantIter = undefined;
        _ = c.g_variant_iter_init(@ptrCast(&iter), streams);
        var count = c.g_variant_iter_n_children(&iter);
        std.debug.print("count: {}\n", .{count});

        if (count != 1) {
            std.debug.print("Received more than one stream, discarding all but last one\n", .{});

            while (count > 1) {
                count -= 1;
                const prop: ?*c.GVariant = null;
                defer freeMaybe(prop);
                const node: u32 = 0;
                _ = c.g_variant_iter_loop(&iter, "(u@a{sv})", &node, &prop);
            }
        }

        var prop: ?*c.GVariant = null;
        defer freeMaybe(prop);

        _ = c.g_variant_iter_loop(
            &iter,
            "(u@a{sv})",
            @as(*u32, @alignCast(@ptrCast(context.result))),
            &prop,
        );

        // TODO: currently not working!!
        // Extract and save the screen name
        if (prop) |p| {
            const source_type_variant = c.g_variant_lookup_value(p, "source_type", c.g_variant_type_new("u"));
            defer freeMaybe(source_type_variant);
            const size_variant = c.g_variant_lookup_value(p, "size", c.g_variant_type_new("(ii)"));
            defer freeMaybe(size_variant);
            var stream_description: []u8 = undefined;
            if (source_type_variant != null) {
                const source_type = c.g_variant_get_uint32(source_type_variant);
                const type_str = switch (source_type) {
                    1 => "Monitor",
                    2 => "Window",
                    else => "Unknown",
                };
                if (size_variant != null) {
                    var width: i32 = undefined;
                    var height: i32 = undefined;
                    c.g_variant_get(size_variant, "(ii)", &width, &height);
                    if (std.fmt.allocPrint(context.portal.allocator, "{s} ({}x{})", .{ type_str, width, height })) |desc| {
                        stream_description = desc;
                    } else |err| {
                        std.debug.print("Error allocating stream description: {}\n", .{err});
                        callback.cancelled = true;
                        return;
                    }
                } else {
                    if (context.portal.allocator.dupe(u8, type_str)) |desc| {
                        stream_description = desc;
                    } else |err| {
                        std.debug.print("Error allocating stream description: {}\n", .{err});
                        callback.cancelled = true;
                        return;
                    }
                }
            } else {
                if (context.portal.allocator.dupe(u8, "Unknown Stream")) |desc| {
                    stream_description = desc;
                } else |err| {
                    std.debug.print("Error allocating stream description: {}\n", .{err});
                    callback.cancelled = true;
                    return;
                }
            }
            if (context.portal.selected_screen_name) |old_name| {
                context.portal.allocator.free(old_name);
            }
            context.portal.selected_screen_name = stream_description;
            std.debug.print("Selected stream: {s}\n", .{context.portal.selected_screen_name.?});
        } else {
            std.debug.print("No stream properties found in D-Bus response.\n", .{});
        }
    }

    fn selectSourceCallback(
        conn: ?*c.GDBusConnection,
        sender_name: [*c]const u8,
        object_path: [*c]const u8,
        interface_name: [*c]const u8,
        signal_name: [*c]const u8,
        params: ?*c.GVariant,
        opaque_: ?*anyopaque,
    ) callconv(.c) void {
        _ = conn;
        _ = sender_name;
        _ = object_path;
        _ = interface_name;
        _ = signal_name;
        std.debug.print("[selectSourceCallback]", .{});
        const callback: *DBusCallback = @alignCast(@ptrCast(opaque_));
        var status: u32 = undefined;
        var result: ?*c.GVariant = null;
        defer freeMaybe(result);
        c.g_variant_get(params, "(u@a{sv})", &status, &result);

        if (status != 0) {
            std.debug.print("g_variant_get error: {}\n", .{status});
        }
        callback.opaque_ = @ptrFromInt(1);
        callback.completed = true;
    }

    fn callbackRegister(
        self: *const Self,
        data: *DBusCallback,
        path: [:0]const u8,
        func: c.GDBusSignalCallback,
    ) void {
        data.id = c.g_dbus_connection_signal_subscribe(
            self.conn,
            "org.freedesktop.portal.Desktop",
            "org.freedesktop.portal.Request",
            "Response",
            path.ptr,
            null,
            c.G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE,
            func,
            data,
            null,
        );
    }

    fn callbackUnregister(self: *const Self, data: ?*DBusCallback) void {
        if (data) |d| {
            std.debug.print("unregisterring\n", .{});
            c.g_dbus_connection_signal_unsubscribe(self.conn, d.id);
        }
    }

    /// Read restore token from user app directory
    fn readRestoreTokenFromFile(
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const dir = try UserSettings.getAppDataDir(allocator);
        defer allocator.free(dir);
        const file_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ dir, "restore_token.txt" },
        );
        defer allocator.free(file_path);
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const stat = try file.stat();

        var reader = file.reader(&.{});
        return reader.interface.readAlloc(allocator, stat.size);
    }

    /// Write restore token to user app directory
    fn writeRestoreTokenToFile(allocator: std.mem.Allocator, restore_token: []u8) !void {
        const dir = try UserSettings.getAppDataDir(allocator);
        defer allocator.free(dir);
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
            dir,
            "restore_token.txt",
        });
        defer allocator.free(file_path);

        const file = try std.fs.createFileAbsolute(file_path, .{});
        defer file.close();

        try file.writeAll(restore_token);
    }

    pub fn destroySession(self: *Self) void {
        if (self.session_handle) |handle| {
            _ = c.g_dbus_connection_call_sync(
                self.conn,
                "org.freedesktop.portal.Desktop",
                handle,
                "org.freedesktop.portal.Session",
                "Close",
                null,
                null,
                c.G_DBUS_CALL_FLAGS_NONE,
                -1,
                null,
                null,
            );
            self.allocator.free(std.mem.sliceTo(handle, 0));
            self.session_handle = null;
        }
    }

    pub fn deinit(self: *Self) void {
        self.destroySession();

        unrefMaybe(self.screen_cast);

        if (self.sender_name) |sender_name| {
            self.allocator.free(sender_name);
        }

        if (self.restore_token) |restore_token| {
            self.allocator.free(restore_token);
        }

        if (self.selected_screen_name) |selected_screen_name| {
            self.allocator.free(selected_screen_name);
        }

        self.allocator.destroy(self);
    }
};
