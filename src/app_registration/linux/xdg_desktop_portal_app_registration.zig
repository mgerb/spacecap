const std = @import("std");
const app_identity = @import("../../common/linux/app_identity.zig");
const XdgDesktopPortal = @import("../../common/linux/xdg_desktop_portal.zig");
const c = @import("libportal");

const log = std.log.scoped(.xdg_desktop_portal_app_registration);

fn variant_type(comptime signature: [:0]const u8) *const c.GVariantType {
    return @ptrCast(signature.ptr);
}

fn is_registry_unavailable(err: *c.GError) bool {
    if (err.domain != c.g_dbus_error_quark()) return false;

    return err.code == c.G_DBUS_ERROR_UNKNOWN_METHOD or
        err.code == c.G_DBUS_ERROR_UNKNOWN_INTERFACE or
        err.code == c.G_DBUS_ERROR_UNKNOWN_OBJECT or
        err.code == c.G_DBUS_ERROR_SERVICE_UNKNOWN or
        err.code == c.G_DBUS_ERROR_NAME_HAS_NO_OWNER;
}

/// Register the app ID before any other dbus connections start up.
/// The dbus connection remains open until the app closes.
pub const XdgDesktopPortalAppRegistration = struct {
    const Self = @This();

    dbus: *c.GDBusConnection,

    pub fn init() !Self {
        var g_error: ?*c.GError = null;
        defer if (g_error) |err| c.g_error_free(err);

        const dbus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &g_error) orelse {
            if (g_error) |err| {
                log.err("[init] failed to get session bus: {s}", .{err.message.?});
            }
            return error.Dbus;
        };
        errdefer c.g_object_unref(dbus);

        register(dbus);

        return .{ .dbus = dbus };
    }

    pub fn deinit(self: *Self) void {
        c.g_object_unref(self.dbus);
    }

    fn register(dbus: *c.GDBusConnection) void {
        var options: c.GVariantBuilder = undefined;
        c.g_variant_builder_init(&options, variant_type("a{sv}"));
        const payload = c.g_variant_new(
            "(s@a{sv})",
            app_identity.APP_ID.ptr,
            c.g_variant_builder_end(&options),
        ).?;

        var g_error: ?*c.GError = null;
        defer if (g_error) |err| c.g_error_free(err);

        const result = c.g_dbus_connection_call_sync(
            dbus,
            XdgDesktopPortal.DBUS_DESTINATION.ptr,
            XdgDesktopPortal.DBUS_OBJECT_PATH.ptr,
            XdgDesktopPortal.REGISTRY_INTERFACE.ptr,
            XdgDesktopPortal.REGISTER_METHOD.ptr,
            payload,
            variant_type("()"),
            c.G_DBUS_CALL_FLAGS_NONE,
            -1,
            null,
            &g_error,
        );
        defer if (result) |value| c.g_variant_unref(value);

        if (g_error) |err| {
            if (is_registry_unavailable(err)) {
                log.info("[register] host portal registry is unavailable: {s}", .{err.message.?});
            } else {
                log.err("[register] failed to register app id '{s}': {s}", .{ app_identity.APP_ID, err.message.? });
            }
            return;
        }

        log.info("[register] registered app id '{s}'", .{app_identity.APP_ID});
    }
};
