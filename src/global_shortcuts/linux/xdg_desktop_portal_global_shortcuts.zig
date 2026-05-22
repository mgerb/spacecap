//// Credits to Ghostty for the implementation reference: https://github.com/ghostty-org/ghostty/pull/7083

const std = @import("std");
const TokenManager = @import("../../common/linux/token_manager.zig");
const TokenStorage = @import("../../common/linux/token_storage.zig");
const GlobalShortcuts = @import("../global_shortcuts.zig").GlobalShortcuts;
const assert = std.debug.assert;

const c = @import("../../common/linux/gio.zig").c;

const log = std.log.scoped(.xdg_desktop_portal_global_shortcuts);

const Action = struct {
    name: []const u8,
    trigger: ?[]const u8 = null,
};
const Actions = std.StringArrayHashMapUnmanaged(Action);

pub const XdgDesktopPortalGlobalShortcuts = struct {
    const Self = @This();
    const Token = [16]u8;

    allocator: std.mem.Allocator,
    dbus: *c.GDBusConnection,
    main_loop: ?*c.GMainLoop = null,
    run_thread: ?std.Thread = null,
    ctx: ?*c.GMainContext = null,
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
        errdefer allocator.destroy(self);

        var g_error: ?*c.GError = null;
        const dbus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &g_error) orelse return error.Dbus;
        defer if (g_error) |err| c.g_error_free(err);

        if (g_error) |err| {
            log.err("{s}\n", .{err.message.?});
            return error.BusGetSync;
        }

        self.* = .{
            .allocator = allocator,
            .dbus = dbus,
            .actions = try init_actions(allocator),
        };

        return self;
    }

    fn init_actions(allocator: std.mem.Allocator) !Actions {
        const shortcut_ids = comptime GlobalShortcuts.Shortcut.ids();
        const shortcut_actions = comptime blk: {
            var actions: [GlobalShortcuts.Shortcut.all.len]Action = undefined;
            for (GlobalShortcuts.Shortcut.all, 0..) |shortcut, index| {
                actions[index] = .{ .name = shortcut.display_name() };
            }
            break :blk actions;
        };

        return .init(allocator, &shortcut_ids, &shortcut_actions);
    }

    pub fn deinit(self: *Self) void {
        stop(self);
        self.close();

        c.g_object_unref(self.dbus);

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
            c.g_dbus_connection_signal_unsubscribe(self.dbus, self.response_subscription);
            self.response_subscription = 0;
        }

        if (self.activate_subscription != 0) {
            c.g_dbus_connection_signal_unsubscribe(self.dbus, self.activate_subscription);
            self.activate_subscription = 0;
        }

        if (self.handle) |handle| {
            // Close existing session
            c.g_dbus_connection_call(
                self.dbus,
                "org.freedesktop.portal.Desktop",
                handle.ptr,
                "org.freedesktop.portal.Session",
                "Close",
                null,
                null,
                c.G_DBUS_CALL_FLAGS_NONE,
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
                _self.ctx = c.g_main_context_new();
                defer {
                    c.g_main_context_unref(_self.ctx.?);
                    _self.ctx = null;
                }
                c.g_main_context_push_thread_default(_self.ctx.?);
                defer c.g_main_context_pop_thread_default(_self.ctx.?);

                _self.request(.{ .create_session = .{ .restore_session = true } }) catch |err| {
                    log.err("create session error: {}\n", .{err});
                };

                const main_loop = c.g_main_loop_new(_self.ctx.?, 0) orelse return;
                _self.main_loop = main_loop;
                defer {
                    c.g_main_loop_unref(main_loop);
                    _self.main_loop = null;
                }
                c.g_main_loop_run(main_loop);
            }
        };

        self.run_thread = try std.Thread.spawn(.{}, RunThread.run, .{self});
    }

    /// Stop the main loop if it is running
    pub fn stop(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.main_loop) |main_loop| {
            if (c.g_main_loop_is_running(main_loop) != 0) {
                c.g_main_loop_quit(main_loop);
            }
        }
    }

    pub fn open(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        // NOTE: Anything interacting with the portal must
        // be done in the context of the main loop, otherwise
        // nothing will happen.
        if (self.ctx) |ctx| {
            c.g_main_context_invoke(ctx, _open_shortcuts, self);
        }
    }

    fn _open_shortcuts(args: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(args));
        // NOTE: This is not implemented in most xdg desktop portal implementations yet.
        // We'll revisit this later.
        self.configure_shortcuts() catch unreachable;
        return 0;
    }

    // NOTE: This is not implemented in most xdg desktop portal implementations yet.
    // It currently does not work in my KDE Plasma 6 desktop environment. Need to revisit
    // this later.
    // https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.impl.portal.GlobalShortcuts.html#org-freedesktop-impl-portal-globalshortcuts-configureshortcuts
    fn configure_shortcuts(self: *Self) !void {
        const handle = self.handle orelse return error.NoSession;

        // TODO: Need to figure out how to get the activation token;
        const activation_token = "todo";

        const payload = c.g_variant_new_parsed(
            "(%o, '', {'activation_token': <%s>})",
            handle.ptr,
            activation_token.ptr,
        );

        const result = c.g_dbus_connection_call_sync(
            self.dbus,
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.GlobalShortcuts",
            "ConfigureShortcuts",
            payload,
            null,
            c.G_DBUS_CALL_FLAGS_NONE,
            -1,
            null,
            null,
        );
        if (result) |variant| {
            c.g_variant_unref(variant);
        }
    }

    fn shortcut_activated(
        _: ?*c.GDBusConnection,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        params: ?*c.GVariant,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud));

        // 2nd value in the tuple is the activated shortcut ID
        // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html#org-freedesktop-portal-globalshortcuts-activated
        var shortcut_idZ: [*:0]const u8 = undefined;
        c.g_variant_get_child(params.?, 1, "&s", &shortcut_idZ);
        log.debug("activated={s}", .{shortcut_idZ});
        const shortcut_id = std.mem.span(shortcut_idZ);

        const action = self.actions.get(shortcut_id);
        assert(action != null);

        const shortcut = std.meta.stringToEnum(GlobalShortcuts.Shortcut, shortcut_id) orelse {
            log.warn("unknown shortcut activated: {s}", .{shortcut_id});
            return;
        };

        log.info("{s} shortcut activated\n", .{shortcut_id});
        if (self.registeredShortcutHandler) |*handler| {
            handler.invoke(shortcut);
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
        fn make_payload(
            self: Method,
            shortcuts: *Self,
            request_token: [:0]const u8,
        ) ?*c.GVariant {
            switch (self) {
                // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html#org-freedesktop-portal-globalshortcuts-createsession
                .create_session => {
                    if (self.create_session.restore_session) {
                        shortcuts.session_token = TokenStorage.load_token_z(shortcuts.allocator, "session_token") catch unreachable;
                    }

                    if (shortcuts.session_token == null) {
                        shortcuts.session_token = @constCast(TokenManager.generate_token(shortcuts.allocator) catch unreachable);
                        TokenStorage.save_token(shortcuts.allocator, "session_token", shortcuts.session_token.?) catch unreachable;
                    }

                    assert(shortcuts.session_token != null);

                    return c.g_variant_new_parsed(
                        "({'handle_token': <%s>, 'session_handle_token': <%s>},)",
                        request_token.ptr,
                        shortcuts.session_token.?.ptr,
                    );
                },
                // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html#org-freedesktop-portal-globalshortcuts-bindshortcuts
                .bind_shortcuts => {
                    const handle = shortcuts.handle orelse return null;

                    const bind_type = c.g_variant_type_new("a(sa{sv})");
                    defer c.g_variant_type_free(bind_type);

                    var binds: c.GVariantBuilder = undefined;
                    c.g_variant_builder_init(&binds, bind_type);

                    var iter = shortcuts.actions.iterator();
                    while (iter.next()) |entry| {
                        const action = shortcuts.actions.get(entry.key_ptr.*).?;

                        if (entry.value_ptr.trigger) |trigger| {
                            c.g_variant_builder_add_parsed(
                                &binds,
                                "(%s, {'description': <%s>, 'preferred_trigger': <%s>})",
                                entry.key_ptr.*.ptr,
                                action.name.ptr,
                                trigger.ptr,
                            );
                        } else {
                            c.g_variant_builder_add_parsed(
                                &binds,
                                "(%s, {'description': <%s>})",
                                entry.key_ptr.*.ptr,
                                action.name.ptr,
                            );
                        }
                    }

                    return c.g_variant_new_parsed(
                        "(%o, %*, '', {'handle_token': <%s>})",
                        handle.ptr,
                        c.g_variant_builder_end(&binds),
                        request_token.ptr,
                    );
                },
            }
        }

        fn on_response(self: Method, shortcuts: *Self, vardict: *c.GVariant) void {
            switch (self) {
                .create_session => {
                    var handle: ?[*:0]u8 = null;
                    if (c.g_variant_lookup(vardict, "session_handle", "&s", &handle) == 0) {
                        const response = c.g_variant_print(vardict, 1);
                        defer c.g_free(response);
                        log.err(
                            "session handle not found in response={s}",
                            .{response},
                        );
                        return;
                    }

                    shortcuts.handle = shortcuts.allocator.dupeZ(u8, std.mem.span(handle.?)) catch {
                        log.err("out of memory: failed to clone session handle", .{});
                        return;
                    };

                    log.debug("session_handle={?s}", .{handle});

                    // Subscribe to keybind activations
                    shortcuts.activate_subscription = c.g_dbus_connection_signal_subscribe(
                        shortcuts.dbus,
                        null,
                        "org.freedesktop.portal.GlobalShortcuts",
                        "Activated",
                        "/org/freedesktop/portal/desktop",
                        handle,
                        c.G_DBUS_SIGNAL_FLAGS_MATCH_ARG0_PATH,
                        shortcut_activated,
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
                    var sc: ?*c.GVariant = null;
                    assert(c.g_variant_lookup(vardict, "shortcuts", "@a(sa{sv})", &sc) == 1);
                    assert(sc != null);

                    defer c.g_variant_unref(sc.?);

                    const iter = c.g_variant_iter_new(sc.?);
                    defer c.g_variant_iter_free(iter);

                    var id: [*:0]const u8 = undefined;
                    var props: *c.GVariant = undefined;
                    while (c.g_variant_iter_loop(iter, "(&s@a{sv})", &id, &props) != 0) {
                        var trigger: [*:0]const u8 = undefined;
                        assert(c.g_variant_lookup(props, "trigger_description", "&s", &trigger) == 1);

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
            fn got_response_handle(
                source: [*c]c.GObject,
                res: ?*c.GAsyncResult,
                _: ?*anyopaque,
            ) callconv(.c) void {
                const dbus_: *c.GDBusConnection = @ptrCast(@alignCast(source));

                var err: ?*c.GError = null;
                defer if (err) |err_| c.g_error_free(err_);

                const params_ = c.g_dbus_connection_call_finish(dbus_, res.?, &err) orelse {
                    if (err) |err_| {
                        const message: [*c]const u8 = if (err_.message != null) err_.message else @ptrCast("(unknown)".ptr);
                        log.err("request failed={s} ({})", .{ message, err_.code });
                    }
                    return;
                };
                defer c.g_variant_unref(params_);

                // TODO: XDG recommends updating the signal subscription if the actual
                // returned request path is not the same as the expected request
                // path, to retain compatibility with older versions of XDG portals.
                // Although it suffers from the race condition outlined above,
                // we should still implement this at some point.
            }

            // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html#org-freedesktop-portal-request-response
            fn responded(
                dbus: ?*c.GDBusConnection,
                _: [*c]const u8,
                _: [*c]const u8,
                _: [*c]const u8,
                _: [*c]const u8,
                params_: ?*c.GVariant,
                ud: ?*anyopaque,
            ) callconv(.c) void {
                const self_: *Self = @ptrCast(@alignCast(ud));

                // Unsubscribe from the response signal
                if (self_.response_subscription != 0) {
                    c.g_dbus_connection_signal_unsubscribe(dbus.?, self_.response_subscription);
                    self_.response_subscription = 0;
                }

                var response: u32 = 0;
                var vardict: ?*c.GVariant = null;
                c.g_variant_get(params_.?, "(u@a{sv})", &response, &vardict);
                defer if (vardict) |dict| c.g_variant_unref(dict);

                switch (response) {
                    0 => {
                        log.debug("request successful", .{});
                        method.on_response(self_, vardict.?);
                    },
                    1 => log.debug("request was cancelled by user", .{}),
                    2 => log.warn("request ended unexpectedly", .{}),
                    else => log.err("unrecognized response code={}", .{response}),
                }
            }
        };

        const request_token = try TokenManager.generate_token(self.allocator);
        defer self.allocator.free(request_token);

        const payload = method.make_payload(self, request_token) orelse return;
        const unique_name = std.mem.span(c.g_dbus_connection_get_unique_name(self.dbus).?);
        const request_path = try TokenManager.get_request_path(self.allocator, unique_name[1..], request_token);
        defer self.allocator.free(request_path);

        self.response_subscription = c.g_dbus_connection_signal_subscribe(
            self.dbus,
            null,
            "org.freedesktop.portal.Request",
            "Response",
            request_path,
            null,
            c.G_DBUS_SIGNAL_FLAGS_NONE,
            callbacks.responded,
            self,
            null,
        );

        c.g_dbus_connection_call(
            self.dbus,
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.GlobalShortcuts",
            method.name(),
            payload,
            null,
            c.G_DBUS_CALL_FLAGS_NONE,
            -1,
            null,
            callbacks.got_response_handle,
            null,
        );
    }

    fn register_shortcut_handler(context: *anyopaque, handler: GlobalShortcuts.ShortcutHandler) void {
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
                .register_shortcut_handler = register_shortcut_handler,
            },
        };
    }
};
