//// Credits to Ghostty for the implementation reference: https://github.com/ghostty-org/ghostty/pull/7083

const std = @import("std");
const TokenManager = @import("../common/linux/token_manager.zig");
const TokenStorage = @import("../common/linux/token_storage.zig");
const GlobalShortcuts = @import("./global_shortcuts.zig").GlobalShortcuts;
const assert = std.debug.assert;

const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");

const log = std.log.scoped(.xdg_desktop_portal_global_shortcuts);

const Actions = std.StringArrayHashMapUnmanaged(struct {
    name: []const u8,
    trigger: ?[]const u8 = null,
});

pub const XdgDesktopPortalGlobalShortcuts = struct {
    const Self = @This();
    const Token = [16]u8;

    allocator: std.mem.Allocator,
    dbus: *gio.DBusConnection,
    main_loop: ?*glib.MainLoop = null,
    run_thread: ?std.Thread = null,
    ctx: ?*glib.MainContext = null,
    // actions: *Actions,
    actions: Actions,
    session_token: ?[:0]u8 = null,
    registeredShortcutHandler: ?GlobalShortcuts.ShortcutHandler = null,

    /// The handle of the current global shortcuts portal session,
    /// as a D-Bus object path.
    handle: ?[:0]const u8 = null,

    /// The D-Bus signal subscription for the response signal on requests.
    /// The ID is guaranteed to be non-zero, so we can use 0 to indicate null.
    response_subscription: c_uint = 0,

    /// The D-Bus signal subscription for the keybind activate signal.
    /// The ID is guaranteed to be non-zero, so we can use 0 to indicate null.
    activate_subscription: c_uint = 0,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);

        const g_error: ?*?*glib.Error = null;
        const dbus = gio.busGetSync(.session, null, g_error) orelse return error.dbus;

        if (g_error) |err| {
            log.err("{s}\n", .{err.*.?.f_message});
            return error.busGetSync;
        }

        self.* = .{
            .allocator = allocator,
            .dbus = dbus,
            .actions = try .init(
                allocator,
                // NOTE: Add default global shortcuts here.
                &.{"save_replay"},
                &.{.{ .name = "Save Replay" }},
            ),
        };

        return self;
    }

    pub fn deinit(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        stop(self);
        self.close();

        self.dbus.unref();

        if (self.handle) |handle| {
            self.allocator.free(handle);
        }

        // Quitting the main loop above should terminate the thread.
        // Let's wait for the thread to terminate here.
        if (self.run_thread) |run_thread| {
            run_thread.join();
        }

        if (self.session_token) |session_token| {
            self.allocator.free(session_token);
        }

        self.actions.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    fn close(self: *Self) void {
        if (self.response_subscription != 0) {
            self.dbus.signalUnsubscribe(self.response_subscription);
            self.response_subscription = 0;
        }

        if (self.activate_subscription != 0) {
            self.dbus.signalUnsubscribe(self.activate_subscription);
            self.activate_subscription = 0;
        }

        if (self.handle) |handle| {
            // Close existing session
            self.dbus.call(
                "org.freedesktop.portal.Desktop",
                handle,
                "org.freedesktop.portal.Session",
                "Close",
                null,
                null,
                .{},
                -1,
                null,
                null,
                null,
            );
            self.allocator.free(handle);
            self.handle = null;
        }
    }

    /// Create the session and run the loop. This is not blocking, it manages
    /// the thread internally.
    pub fn run(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        // Stop the main loop if is running
        stop(self);
        // Wait for the thread to complete
        if (self.run_thread) |run_thread| {
            run_thread.join();
        }
        // Close any existing sessions
        self.close();

        const RunThread = struct {
            pub fn run(_self: *Self) void {
                _self.ctx = glib.MainContext.new();
                defer {
                    _self.ctx.?.unref();
                    _self.ctx = null;
                }
                glib.MainContext.pushThreadDefault(_self.ctx.?);
                defer glib.MainContext.popThreadDefault(_self.ctx.?);

                _self.request(.{ .create_session = .{ .restore_session = true } }) catch |err| {
                    log.err("create session error: {}\n", .{err});
                };

                const main_loop = glib.MainLoop.new(_self.ctx.?, 0);
                _self.main_loop = main_loop;
                defer {
                    main_loop.unref();
                    _self.main_loop = null;
                }
                main_loop.run();
            }
        };

        self.run_thread = try std.Thread.spawn(.{}, RunThread.run, .{self});
    }

    /// Stop the main loop if it is running
    pub fn stop(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.main_loop) |main_loop| {
            if (main_loop.isRunning() != 0) {
                main_loop.quit();
            }
        }
    }

    pub fn open(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        // NOTE: Anything interacting with the portal must
        // be done in the context of the main loop, otherwise
        // nothing will happen.
        if (self.ctx) |ctx| {
            glib.MainContext.invoke(ctx, _openShortcuts, self);
        }
    }

    fn _openShortcuts(args: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(args));
        // NOTE: This is not implemented in most xdg desktop portal implementations yet.
        // We'll revisit this later.
        self.configureShortcuts() catch unreachable;
        return 0;
    }

    // NOTE: This is not implemented in most xdg desktop portal implementations yet.
    // It currently does not work in my KDE Plasma 6 desktop environment. Need to revisit
    // this later.
    // https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.impl.portal.GlobalShortcuts.html#org-freedesktop-impl-portal-globalshortcuts-configureshortcuts
    fn configureShortcuts(self: *Self) !void {
        const handle = self.handle orelse return error.NoSession;

        // TODO: Need to figure out how to get the activation token;
        const activation_token = "todo";

        const payload = glib.Variant.newParsed(
            "(%o, '', {'activation_token': <%s>})",
            handle.ptr,
            activation_token.ptr,
        );

        _ = self.dbus.callSync(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.GlobalShortcuts",
            "ConfigureShortcuts",
            payload,
            null,
            .{},
            -1,
            null,
            null,
        );
    }

    fn shortcutActivated(
        _: *gio.DBusConnection,
        _: ?[*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        params: *glib.Variant,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud));

        // 2nd value in the tuple is the activated shortcut ID
        // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html#org-freedesktop-portal-globalshortcuts-activated
        var shortcut_idZ: [*:0]const u8 = undefined;
        params.getChild(1, "&s", &shortcut_idZ);
        log.debug("activated={s}", .{shortcut_idZ});
        const shortcut_id = std.mem.span(shortcut_idZ);

        const action = self.actions.get(shortcut_id);
        assert(action != null);

        if (std.mem.eql(u8, "save_replay", shortcut_id)) {
            log.info("save_replay shortcut activated\n", .{});
            if (self.registeredShortcutHandler) |*handler| {
                handler.invoke(.save_replay);
            }
        }
    }

    const Method = union(enum) {
        create_session: struct {
            /// Whether or not to use the existing session token. We probably always want to do this.
            /// Keeping this functionality around for future changes.
            restore_session: bool,
        },
        bind_shortcuts,

        fn name(self: Method) [:0]const u8 {
            return switch (self) {
                .create_session => "CreateSession",
                .bind_shortcuts => "BindShortcuts",
            };
        }

        /// Construct the payload expected by the XDG portal call.
        fn makePayload(
            self: Method,
            shortcuts: *Self,
            request_token: [:0]const u8,
        ) ?*glib.Variant {
            switch (self) {
                // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html#org-freedesktop-portal-globalshortcuts-createsession
                .create_session => {
                    if (self.create_session.restore_session) {
                        shortcuts.session_token = TokenStorage.loadTokenZ(shortcuts.allocator, "session_token") catch unreachable;
                    }

                    if (shortcuts.session_token == null) {
                        shortcuts.session_token = @constCast(TokenManager.generateToken(shortcuts.allocator) catch unreachable);
                        TokenStorage.saveToken(shortcuts.allocator, "session_token", shortcuts.session_token.?) catch unreachable;
                    }

                    assert(shortcuts.session_token != null);

                    return glib.Variant.newParsed(
                        "({'handle_token': <%s>, 'session_handle_token': <%s>},)",
                        request_token.ptr,
                        shortcuts.session_token.?.ptr,
                    );
                },
                // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html#org-freedesktop-portal-globalshortcuts-bindshortcuts
                .bind_shortcuts => {
                    const handle = shortcuts.handle orelse return null;

                    const bind_type = glib.VariantType.new("a(sa{sv})");
                    defer glib.free(bind_type);

                    var binds: glib.VariantBuilder = undefined;
                    glib.VariantBuilder.init(&binds, bind_type);

                    var iter = shortcuts.actions.iterator();
                    while (iter.next()) |entry| {
                        const action = shortcuts.actions.get(entry.key_ptr.*).?;

                        if (entry.value_ptr.trigger) |trigger| {
                            binds.addParsed(
                                "(%s, {'description': <%s>, 'preferred_trigger': <%s>})",
                                entry.key_ptr.*.ptr,
                                action.name.ptr,
                                trigger.ptr,
                            );
                        } else {
                            binds.addParsed(
                                "(%s, {'description': <%s>})",
                                entry.key_ptr.*.ptr,
                                action.name.ptr,
                            );
                        }
                    }

                    return glib.Variant.newParsed(
                        "(%o, %*, '', {'handle_token': <%s>})",
                        handle.ptr,
                        binds.end(),
                        request_token.ptr,
                    );
                },
            }
        }

        fn onResponse(self: Method, shortcuts: *Self, vardict: *glib.Variant) void {
            switch (self) {
                .create_session => {
                    var handle: ?[*:0]u8 = null;
                    if (vardict.lookup("session_handle", "&s", &handle) == 0) {
                        log.err(
                            "session handle not found in response={s}",
                            .{vardict.print(@intFromBool(true))},
                        );
                        return;
                    }

                    shortcuts.handle = shortcuts.allocator.dupeZ(u8, std.mem.span(handle.?)) catch {
                        log.err("out of memory: failed to clone session handle", .{});
                        return;
                    };

                    log.debug("session_handle={?s}", .{handle});

                    // Subscribe to keybind activations
                    shortcuts.activate_subscription = shortcuts.dbus.signalSubscribe(
                        null,
                        "org.freedesktop.portal.GlobalShortcuts",
                        "Activated",
                        "/org/freedesktop/portal/desktop",
                        handle,
                        .{ .match_arg0_path = true },
                        shortcutActivated,
                        shortcuts,
                        null,
                    );

                    log.debug("bind_shortcuts\n", .{});
                    shortcuts.request(.bind_shortcuts) catch |err| {
                        log.err("failed to bind shortcuts={}", .{err});
                        return;
                    };
                },
                .bind_shortcuts => {
                    log.info("bind_shortcuts done\n", .{});
                    var sc: ?*glib.Variant = null;
                    assert(vardict.lookup("shortcuts", "@a(sa{sv})", &sc) == 1);
                    assert(sc != null);

                    defer sc.?.unref();

                    var iter = sc.?.iterNew();
                    defer iter.free();

                    var id: [*:0]const u8 = undefined;
                    var props: *glib.Variant = undefined;
                    while (iter.loop("(&s@a{sv})", &id, &props) != 0) {
                        var trigger: [*:0]const u8 = undefined;
                        assert(props.lookup("trigger_description", "&s", &trigger) == 1);

                        // NOTE: No longer used. See description of Actions.
                        // shortcuts.actions.updateTrigger(std.mem.span(id), std.mem.span(trigger)) catch unreachable;

                        log.info("User bound {s} → {s}\n", .{
                            std.mem.span(id),
                            std.mem.span(trigger),
                        });
                    }
                },
            }
        }
    };

    /// Submit a request to the global shortcuts portal.
    fn request(
        self: *Self,
        comptime method: Method,
    ) !void {
        // NOTE(pluiedev):
        // XDG Portals are really, really poorly-designed pieces of hot garbage.
        // How the protocol is _initially_ designed to work is as follows:
        //
        // 1. The client calls a method which returns the path of a Request object;
        // 2. The client waits for the Response signal under said object path;
        // 3. When the signal arrives, the actual return value and status code
        //    become available for the client for further processing.
        //
        // THIS DOES NOT WORK. Once the first two steps are complete, the client
        // needs to immediately start listening for the third step, but an overeager
        // server implementation could easily send the Response signal before the
        // client is even ready, causing communications to break down over a simple
        // race condition/two generals' problem that even _TCP_ had figured out
        // decades ago. Worse yet, you get exactly _one_ chance to listen for the
        // signal, or else your communication attempt so far has all been in vain.
        //
        // And they know this. Instead of fixing their freaking protocol, they just
        // ask clients to manually construct the expected object path and subscribe
        // to the request signal beforehand, making the whole response value of
        // the original call COMPLETELY MEANINGLESS.
        //
        // Furthermore, this is _entirely undocumented_ aside from one tiny
        // paragraph under the documentation for the Request interface, and
        // anyone would be forgiven for missing it without reading the libportal
        // source code.
        //
        // When in Rome, do as the Romans do, I guess...?

        const callbacks = struct {
            fn gotResponseHandle(
                source: ?*gobject.Object,
                res: *gio.AsyncResult,
                _: ?*anyopaque,
            ) callconv(.c) void {
                const dbus_ = gobject.ext.cast(gio.DBusConnection, source.?).?;

                var err: ?*glib.Error = null;
                defer if (err) |err_| err_.free();

                const params_ = dbus_.callFinish(res, &err) orelse {
                    if (err) |err_| log.err("request failed={s} ({})", .{
                        err_.f_message orelse "(unknown)",
                        err_.f_code,
                    });
                    return;
                };
                defer params_.unref();

                // TODO: XDG recommends updating the signal subscription if the actual
                // returned request path is not the same as the expected request
                // path, to retain compatibility with older versions of XDG portals.
                // Although it suffers from the race condition outlined above,
                // we should still implement this at some point.
            }

            // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html#org-freedesktop-portal-request-response
            fn responded(
                dbus: *gio.DBusConnection,
                _: ?[*:0]const u8,
                _: [*:0]const u8,
                _: [*:0]const u8,
                _: [*:0]const u8,
                params_: *glib.Variant,
                ud: ?*anyopaque,
            ) callconv(.c) void {
                const self_: *Self = @ptrCast(@alignCast(ud));

                // Unsubscribe from the response signal
                if (self_.response_subscription != 0) {
                    dbus.signalUnsubscribe(self_.response_subscription);
                    self_.response_subscription = 0;
                }

                var response: u32 = 0;
                var vardict: ?*glib.Variant = null;
                params_.get("(u@a{sv})", &response, &vardict);

                switch (response) {
                    0 => {
                        log.debug("request successful", .{});
                        method.onResponse(self_, vardict.?);
                    },
                    1 => log.debug("request was cancelled by user", .{}),
                    2 => log.warn("request ended unexpectedly", .{}),
                    else => log.err("unrecognized response code={}", .{response}),
                }
            }
        };

        const request_token = try TokenManager.generateToken(self.allocator);
        defer self.allocator.free(request_token);

        const payload = method.makePayload(self, request_token) orelse return;
        var unique_name = std.mem.span(self.dbus.getUniqueName().?);
        const request_path = try TokenManager.getRequestPath(self.allocator, unique_name[1..], request_token);
        defer self.allocator.free(request_path);

        self.response_subscription = self.dbus.signalSubscribe(
            null,
            "org.freedesktop.portal.Request",
            "Response",
            request_path,
            null,
            .{},
            callbacks.responded,
            self,
            null,
        );

        self.dbus.call(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.GlobalShortcuts",
            method.name(),
            payload,
            null,
            .{},
            -1,
            null,
            callbacks.gotResponseHandle,
            null,
        );
    }

    fn registerShortcutHandler(context: *anyopaque, handler: GlobalShortcuts.ShortcutHandler) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.registeredShortcutHandler = handler;
    }

    /// Return the GlobalShortcuts interface
    pub fn global_shortcuts(self: *Self) GlobalShortcuts {
        return .{
            .ptr = self,
            .vtable = &.{
                .run = run,
                .stop = stop,
                .open = open,
                .registerShortcutHandler = registerShortcutHandler,
                .deinit = deinit,
            },
        };
    }
};
