const std = @import("std");
const Allocator = std.mem.Allocator;
const BufferedChan = @import("../channel.zig").BufferedChan;
const ChanError = @import("../channel.zig").ChanError;
const Mutex = @import("../mutex.zig").Mutex;
const CaptureStore = @import("./capture_store.zig");
const UserSettingStore = @import("./user_settings_store.zig");

const ChildStores = .{ CaptureStore, UserSettingStore };

pub const Message = union(enum) {
    show_demo,

    exit,
    capture: CaptureStore.CaptureMessage,
    user_settings: UserSettingStore.UserSettingsMessage,

    pub const effects = .{};
};

pub const State = struct {
    show_demo: bool = false,

    capture: CaptureStore.CaptureState = .{},
    user_settings: UserSettingStore.UserSettingsState,

    pub fn init(allocator: Allocator) !@This() {
        return .{
            .user_settings = try .init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.user_settings.deinit();
    }
};

pub const Store = struct {
    const Self = @This();
    const log = std.log.scoped(.store);

    allocator: Allocator,
    messages: BufferedChan(Message, 1024),
    state: Mutex(State),
    effect_thread_pool: std.Thread.Pool = undefined,

    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);

        self.* = .{
            .allocator = allocator,
            .messages = try .init(allocator),
            .state = .init(try .init(allocator)),
        };

        try self.effect_thread_pool.init(.{ .allocator = allocator, .n_jobs = 10 });

        return self;
    }

    pub fn deinit(self: *Self) void {
        {
            const state_locked = self.state.lock();
            defer state_locked.unlock();
            var state = state_locked.unwrap_ptr();
            state.deinit();
        }
        self.messages.deinit();
        self.effect_thread_pool.deinit();
        self.allocator.destroy(self);
    }

    pub fn run(self: *Self) void {
        while (true) {
            const msg = self.messages.recv() catch |err| {
                if (err != ChanError.Closed) {
                    log.err("[run] message receive error: {}", .{err});
                }
                return;
            };

            if (msg == .exit) {
                log.info("[run] exiting", .{});
                return;
            }

            {
                const locked = self.state.lock();
                defer locked.unlock();
                const state = locked.unwrap_ptr();
                update(self.allocator, msg, state);
            }

            self.effect(msg) catch |err| {
                log.err("[run] error executing effect: {}", .{err});
            };
        }
    }

    fn update(allocator: Allocator, msg: Message, state: *State) void {
        inline for (ChildStores) |child_store| {
            child_store.update(allocator, msg, state) catch |err| {
                log.err("[update] error: {}", .{err});
            };
        }
        switch (msg) {
            .show_demo => {
                state.show_demo = !state.show_demo;
            },
            else => {},
        }
    }

    fn effect(self: *Self, msg: Message) !void {
        switch (msg) {
            inline else => |payload| {
                const Payload = @TypeOf(payload);

                if (comptime Payload != void) {
                    if (comptime @hasDecl(Payload, "effects")) {
                        try self.run_registered_effect(Payload.effects, payload);
                        return;
                    }
                }

                try self.run_registered_effect(Message.effects, msg);
            },
        }
    }

    fn run_registered_effect(self: *Self, comptime effects: anytype, msg: anytype) !void {
        comptime validate_effect_keys(@TypeOf(msg), effects);
        switch (msg) {
            inline else => |payload, tag| {
                const effect_name = @tagName(tag);

                if (comptime !@hasField(@TypeOf(effects), effect_name)) {
                    return;
                }

                // TODO: Make effects arrays.
                const effect_fn = @field(effects, effect_name);

                try self.effect_thread_pool.spawn(struct {
                    fn run(store: *Store, effect_payload: @TypeOf(payload)) void {
                        // NOTE: If compiler error here - payload in effect must match
                        // the payload in the message type.
                        effect_fn(store, effect_payload);
                    }
                }.run, .{ self, payload });
            },
        }
    }

    fn validate_effect_keys(comptime MessageType: type, comptime effects: anytype) void {
        const msg_info = @typeInfo(MessageType);
        if (msg_info != .@"union") {
            @compileError("effects can only be registered on union(enum) message types");
        }

        const effects_info = @typeInfo(@TypeOf(effects));
        if (effects_info != .@"struct") {
            @compileError("effects must be a struct literal, e.g. .{ .start = effect_start }");
        }

        inline for (effects_info.@"struct".fields) |effect_field| {
            if (!comptime union_has_tag(MessageType, effect_field.name)) {
                @compileError("effect key '" ++ effect_field.name ++
                    "' does not match any tag in " ++ @typeName(MessageType));
            }
        }
    }

    fn union_has_tag(comptime UnionType: type, comptime name: []const u8) bool {
        inline for (@typeInfo(UnionType).@"union".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                return true;
            }
        }

        return false;
    }

    /// Thread safe and non-blocking.
    pub fn dispatch(self: *Self, msg: Message) void {
        self.messages.send(msg) catch |err| {
            log.err("[dispatch] {}", .{err});
        };
    }
};
