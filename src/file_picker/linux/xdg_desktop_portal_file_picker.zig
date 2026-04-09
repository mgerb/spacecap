const std = @import("std");
const TokenManager = @import("../../common/linux/token_manager.zig");
const FilePicker = @import("../file_picker.zig").FilePicker;
const FilePickerError = @import("../file_picker.zig").FilePickerError;
const glib = @import("glib");
const gio = @import("gio");

const log = std.log.scoped(.xdg_desktop_portal_file_picker);

const DBUS_DESTINATION: [:0]const u8 = "org.freedesktop.portal.Desktop";
const DBUS_OBJECT_PATH: [:0]const u8 = "/org/freedesktop/portal/desktop";
const FILE_CHOOSER_INTERFACE: [:0]const u8 = "org.freedesktop.portal.FileChooser";
const REQUEST_INTERFACE: [:0]const u8 = "org.freedesktop.portal.Request";
const OPEN_FILE_METHOD: [:0]const u8 = "OpenFile";
const RESPONSE_SIGNAL: [:0]const u8 = "Response";

fn map_g_error(err: *glib.Error) ?(FilePickerError || anyerror) {
    if (err.f_domain == gio.DBusError.quark()) {
        if (err.f_code == @intFromEnum(gio.DBusError.service_unknown) or err.f_code == @intFromEnum(gio.DBusError.name_has_no_owner)) {
            return error.PortalServiceNotFound;
        }
    }
    if (err.f_domain == gio.ioErrorQuark() and err.f_code == @intFromEnum(gio.IOErrorEnum.cancelled)) {
        return FilePickerError.PickerCancelled;
    }
    return null;
}

const OpenDirectoryPickerContext = struct {
    loop: *glib.MainLoop,
    response_code: u32 = 2,
    response_data: ?*glib.Variant = null,
};

pub const XdgDesktopPortalFilePicker = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    dbus: *gio.DBusConnection,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        var err: ?*glib.Error = null;
        defer if (err) |e| e.free();

        const dbus = gio.busGetSync(.session, null, &err) orelse {
            if (err) |g_err| {
                if (map_g_error(g_err)) |picker_err| {
                    return picker_err;
                }
            }
            return error.Dbus;
        };

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .dbus = dbus,
        };
        return self;
    }

    fn open_directory_picker_response(
        _: *gio.DBusConnection,
        _: ?[*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        parameters: *glib.Variant,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const ctx: *OpenDirectoryPickerContext = @ptrCast(@alignCast(user_data));
        parameters.get("(u@a{sv})", &ctx.response_code, &ctx.response_data);
        ctx.loop.quit();
    }

    fn make_open_directory_picker_payload(request_token: [:0]const u8, initial_directory: ?[:0]const u8) *glib.Variant {
        var options: glib.VariantBuilder = undefined;
        glib.VariantBuilder.init(&options, glib.VariantType.checked("a{sv}"));
        options.add("{sv}", "handle_token", glib.Variant.newString(request_token.ptr));
        options.add("{sv}", "directory", glib.Variant.newBoolean(1));
        options.add("{sv}", "modal", glib.Variant.newBoolean(1));
        if (initial_directory) |directory| {
            options.add("{sv}", "current_folder", glib.Variant.newBytestring(directory.ptr));
        }

        return glib.Variant.new(
            "(ss@a{sv})",
            "",
            "Select Output Directory",
            options.end(),
        );
    }

    fn selected_directory_from_result(self: *Self, result: *glib.Variant) ![]u8 {
        var result_dict: glib.VariantDict = undefined;
        glib.VariantDict.init(&result_dict, result);
        defer result_dict.clear();

        const uris = result_dict.lookupValue("uris", glib.VariantType.checked("as")) orelse {
            return error.PickerResultMissingUris;
        };
        defer uris.unref();

        var uri_count: usize = 0;
        const uri_values = uris.getStrv(&uri_count);
        defer glib.free(@ptrCast(@constCast(uri_values)));

        if (uri_count == 0) {
            return error.PickerResultMissingUris;
        }

        const first_uri = uri_values[0] orelse return error.PickerResultMissingUris;
        const file_path = glib.filenameFromUri(first_uri, null, null) orelse return error.FileUriToPathFailed;
        defer glib.free(file_path);

        return self.allocator.dupe(u8, std.mem.span(file_path));
    }

    pub fn open_directory_picker(context: *anyopaque, initial_directory: ?[]const u8) ![]u8 {
        const self: *Self = @ptrCast(@alignCast(context));

        const request_token = try TokenManager.generate_token(self.allocator);
        defer self.allocator.free(request_token);

        const initial_directory_z = if (initial_directory) |directory|
            try self.allocator.dupeZ(u8, directory)
        else
            null;
        defer if (initial_directory_z) |directory| self.allocator.free(directory);

        const unique_name = std.mem.span(self.dbus.getUniqueName().?);
        const request_path = try TokenManager.get_request_path(self.allocator, unique_name[1..], request_token);
        defer self.allocator.free(request_path);

        const loop = glib.MainLoop.new(null, 0);
        defer loop.unref();

        var ctx = OpenDirectoryPickerContext{ .loop = loop };
        var subscription_id = self.dbus.signalSubscribe(
            null,
            REQUEST_INTERFACE.ptr,
            RESPONSE_SIGNAL.ptr,
            request_path.ptr,
            null,
            .{},
            open_directory_picker_response,
            &ctx,
            null,
        );
        defer {
            if (subscription_id != 0) {
                self.dbus.signalUnsubscribe(subscription_id);
            }
        }

        const payload = make_open_directory_picker_payload(request_token, initial_directory_z);
        var err: ?*glib.Error = null;
        const request_handle = self.dbus.callSync(
            DBUS_DESTINATION.ptr,
            DBUS_OBJECT_PATH.ptr,
            FILE_CHOOSER_INTERFACE.ptr,
            OPEN_FILE_METHOD.ptr,
            payload,
            null,
            .{},
            -1,
            null,
            &err,
        );
        defer {
            if (request_handle != null) {
                request_handle.?.unref();
            }
        }

        if (err) |g_err| {
            defer g_err.free();
            if (map_g_error(g_err)) |picker_err| {
                return picker_err;
            }
            log.err("directory picker request failed: {s}", .{g_err.f_message.?});
            return error.OpenDirectoryPickerFailed;
        }

        const request_handle_value = request_handle orelse return error.OpenDirectoryPickerFailed;
        const actual_request_path_variant = request_handle_value.getChildValue(0);
        defer actual_request_path_variant.unref();
        const actual_request_path = actual_request_path_variant.getString(null);
        const actual_request_path_str = std.mem.span(actual_request_path);

        if (!std.mem.eql(u8, actual_request_path_str, request_path)) {
            log.warn(
                "directory picker returned unexpected request path, resubscribing: expected={s} actual={s}",
                .{ request_path, actual_request_path_str },
            );
            self.dbus.signalUnsubscribe(subscription_id);
            subscription_id = self.dbus.signalSubscribe(
                null,
                REQUEST_INTERFACE.ptr,
                RESPONSE_SIGNAL.ptr,
                actual_request_path,
                null,
                .{},
                open_directory_picker_response,
                &ctx,
                null,
            );
        }

        loop.run();

        switch (ctx.response_code) {
            0 => {},
            1 => return FilePickerError.PickerCancelled,
            else => return error.OpenDirectoryPickerFailed,
        }

        const result = ctx.response_data orelse return error.OpenDirectoryPickerFailed;
        defer result.unref();

        return self.selected_directory_from_result(result);
    }

    pub fn deinit(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.dbus.unref();
        self.allocator.destroy(self);
    }

    pub fn file_picker(self: *Self) FilePicker {
        return .{
            .ptr = self,
            .vtable = &.{
                .open_directory_picker = open_directory_picker,
                .deinit = deinit,
            },
        };
    }
};
