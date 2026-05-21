const std = @import("std");
const Allocator = std.mem.Allocator;
const TokenManager = @import("../../common/linux/token_manager.zig");
const FilePicker = @import("../file_picker.zig").FilePicker;
const FilePickerError = @import("../file_picker.zig").FilePickerError;

const c = @import("../../tmp_bindings/gio_bindings.zig");

const log = std.log.scoped(.xdg_desktop_portal_file_picker);

const DBUS_DESTINATION: [:0]const u8 = "org.freedesktop.portal.Desktop";
const DBUS_OBJECT_PATH: [:0]const u8 = "/org/freedesktop/portal/desktop";
const FILE_CHOOSER_INTERFACE: [:0]const u8 = "org.freedesktop.portal.FileChooser";
const REQUEST_INTERFACE: [:0]const u8 = "org.freedesktop.portal.Request";
const OPEN_FILE_METHOD: [:0]const u8 = "OpenFile";
const RESPONSE_SIGNAL: [:0]const u8 = "Response";

fn variant_type(comptime signature: [:0]const u8) *const c.GVariantType {
    return @ptrCast(signature.ptr);
}

fn map_g_error(err: *c.GError) ?(FilePickerError || anyerror) {
    if (err.domain == c.g_dbus_error_quark()) {
        if (err.code == c.G_DBUS_ERROR_SERVICE_UNKNOWN or err.code == c.G_DBUS_ERROR_NAME_HAS_NO_OWNER) {
            return error.PortalServiceNotFound;
        }
    }
    if (err.domain == c.g_io_error_quark() and err.code == c.G_IO_ERROR_CANCELLED) {
        return FilePickerError.PickerCancelled;
    }
    return null;
}

const OpenDirectoryPickerContext = struct {
    loop: *c.GMainLoop,
    response_code: u32 = 2,
    response_data: ?*c.GVariant = null,
};

pub const XdgDesktopPortalFilePicker = struct {
    const Self = @This();

    dbus: *c.GDBusConnection,

    pub fn init() !Self {
        var err: ?*c.GError = null;
        defer if (err) |e| c.g_error_free(e);

        const dbus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &err) orelse {
            if (err) |g_err| {
                if (map_g_error(g_err)) |picker_err| {
                    return picker_err;
                }
            }
            return error.Dbus;
        };

        return .{
            .dbus = dbus,
        };
    }

    fn open_directory_picker_response(
        _: ?*c.GDBusConnection,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        parameters: ?*c.GVariant,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const ctx: *OpenDirectoryPickerContext = @ptrCast(@alignCast(user_data));
        c.g_variant_get(parameters.?, "(u@a{sv})", &ctx.response_code, &ctx.response_data);
        c.g_main_loop_quit(ctx.loop);
    }

    fn make_open_directory_picker_payload(request_token: [:0]const u8, initial_directory: ?[:0]const u8) *c.GVariant {
        var options: c.GVariantBuilder = undefined;
        c.g_variant_builder_init(&options, variant_type("a{sv}"));
        c.g_variant_builder_add(&options, "{sv}", "handle_token", c.g_variant_new_string(request_token.ptr));
        c.g_variant_builder_add(&options, "{sv}", "directory", c.g_variant_new_boolean(1));
        c.g_variant_builder_add(&options, "{sv}", "modal", c.g_variant_new_boolean(1));
        if (initial_directory) |directory| {
            c.g_variant_builder_add(&options, "{sv}", "current_folder", c.g_variant_new_bytestring(directory.ptr));
        }

        return c.g_variant_new(
            "(ss@a{sv})",
            "",
            "Select Output Directory",
            c.g_variant_builder_end(&options),
        ).?;
    }

    fn selected_directory_from_result(allocator: Allocator, result: *c.GVariant) ![]u8 {
        var result_dict: c.GVariantDict = undefined;
        c.g_variant_dict_init(&result_dict, result);
        defer c.g_variant_dict_clear(&result_dict);

        const uris = c.g_variant_dict_lookup_value(&result_dict, "uris", variant_type("as")) orelse {
            return error.PickerResultMissingUris;
        };
        defer c.g_variant_unref(uris);

        var uri_count: usize = 0;
        const uri_values = c.g_variant_get_strv(uris, &uri_count);
        defer c.g_free(@ptrCast(@constCast(uri_values)));

        if (uri_count == 0) {
            return error.PickerResultMissingUris;
        }

        const first_uri = uri_values[0] orelse return error.PickerResultMissingUris;
        const file_path = c.g_filename_from_uri(first_uri, null, null) orelse return error.FileUriToPathFailed;
        defer c.g_free(file_path);

        return allocator.dupe(u8, std.mem.span(file_path));
    }

    pub fn open_directory_picker(
        context: *anyopaque,
        allocator: Allocator,
        io: std.Io,
        initial_directory: ?[]const u8,
    ) ![]u8 {
        const self: *Self = @ptrCast(@alignCast(context));

        const request_token = try TokenManager.generate_token(allocator, io);
        defer allocator.free(request_token);

        const initial_directory_z = if (initial_directory) |directory|
            try allocator.dupeZ(u8, directory)
        else
            null;
        defer if (initial_directory_z) |directory| allocator.free(directory);

        const unique_name = std.mem.span(c.g_dbus_connection_get_unique_name(self.dbus).?);
        const request_path = try TokenManager.get_request_path(allocator, unique_name[1..], request_token);
        defer allocator.free(request_path);

        const loop = c.g_main_loop_new(null, 0) orelse return error.GMainLoopNewFailed;
        defer c.g_main_loop_unref(loop);

        var ctx = OpenDirectoryPickerContext{ .loop = loop };
        var subscription_id = c.g_dbus_connection_signal_subscribe(
            self.dbus,
            null,
            REQUEST_INTERFACE.ptr,
            RESPONSE_SIGNAL.ptr,
            request_path.ptr,
            null,
            c.G_DBUS_SIGNAL_FLAGS_NONE,
            open_directory_picker_response,
            &ctx,
            null,
        );
        defer {
            if (subscription_id != 0) {
                c.g_dbus_connection_signal_unsubscribe(self.dbus, subscription_id);
            }
        }

        const payload = make_open_directory_picker_payload(request_token, initial_directory_z);
        var err: ?*c.GError = null;
        const request_handle = c.g_dbus_connection_call_sync(
            self.dbus,
            DBUS_DESTINATION.ptr,
            DBUS_OBJECT_PATH.ptr,
            FILE_CHOOSER_INTERFACE.ptr,
            OPEN_FILE_METHOD.ptr,
            payload,
            null,
            c.G_DBUS_CALL_FLAGS_NONE,
            -1,
            null,
            &err,
        );
        defer {
            if (request_handle != null) {
                c.g_variant_unref(request_handle.?);
            }
        }

        if (err) |g_err| {
            defer c.g_error_free(g_err);
            if (map_g_error(g_err)) |picker_err| {
                return picker_err;
            }
            log.err("directory picker request failed: {s}", .{g_err.message.?});
            return error.OpenDirectoryPickerFailed;
        }

        const request_handle_value = request_handle orelse return error.OpenDirectoryPickerFailed;
        const actual_request_path_variant = c.g_variant_get_child_value(request_handle_value, 0);
        defer c.g_variant_unref(actual_request_path_variant);
        const actual_request_path = c.g_variant_get_string(actual_request_path_variant, null);
        const actual_request_path_str = std.mem.span(actual_request_path);

        if (!std.mem.eql(u8, actual_request_path_str, request_path)) {
            log.warn(
                "directory picker returned unexpected request path, resubscribing: expected={s} actual={s}",
                .{ request_path, actual_request_path_str },
            );
            c.g_dbus_connection_signal_unsubscribe(self.dbus, subscription_id);
            subscription_id = c.g_dbus_connection_signal_subscribe(
                self.dbus,
                null,
                REQUEST_INTERFACE.ptr,
                RESPONSE_SIGNAL.ptr,
                actual_request_path,
                null,
                c.G_DBUS_SIGNAL_FLAGS_NONE,
                open_directory_picker_response,
                &ctx,
                null,
            );
        }

        c.g_main_loop_run(loop);

        switch (ctx.response_code) {
            0 => {},
            1 => return FilePickerError.PickerCancelled,
            else => return error.OpenDirectoryPickerFailed,
        }

        const result = ctx.response_data orelse return error.OpenDirectoryPickerFailed;
        defer c.g_variant_unref(result);

        return selected_directory_from_result(allocator, result);
    }

    pub fn deinit(self: *Self) void {
        c.g_object_unref(self.dbus);
    }

    pub fn file_picker(self: *Self) FilePicker {
        return .{
            .ptr = self,
            .vtable = &.{
                .open_directory_picker = open_directory_picker,
            },
        };
    }
};
