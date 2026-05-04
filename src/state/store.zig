const std = @import("std");
const Allocator = std.mem.Allocator;
const BufferedChan = @import("../channel.zig").BufferedChan;
const ChanError = @import("../channel.zig").ChanError;
const Mutex = @import("../mutex.zig").Mutex;
const CaptureStore = @import("./capture_store.zig");
const UserSettingStore = @import("./user_settings_store.zig");
const FilePicker = @import("../file_picker/file_picker.zig").FilePicker;
const AudioStore = @import("./audio_store.zig").AudioStore;

// All stores have access to the Store. Runtime dependencies should
// live directly on the store.
pub const Store = struct {
    const Self = @This();
    const log = std.log.scoped(.store);

    allocator: Allocator,
    message_queue: BufferedChan(Message, 1024),
    state: Mutex(State),
    effect_thread_pool: std.Thread.Pool = undefined,
    file_picker: *FilePicker,
    audio_store: AudioStore,

    // ----- Adding a new store -----
    //
    // 1. Add to `ChildStores`.
    // 2. Add message to Message.
    // 3. Add state to State (add deinit if necessary).

    const ChildStores = .{
        CaptureStore,
        UserSettingStore,
        AudioStore,
    };

    pub const Message = union(enum) {
        show_demo,
        exit,
        capture: CaptureStore.Message,
        user_settings: UserSettingStore.Message,
        audio: AudioStore.Message,

        pub const effects = .{};
    };

    pub const State = struct {
        show_demo: bool = false,

        capture: CaptureStore.State = .{},
        user_settings: UserSettingStore.State,
        audio: AudioStore.State = .{},

        pub fn init(allocator: Allocator) !@This() {
            return .{
                .user_settings = try .init(allocator),
            };
        }

        pub fn deinit(self: *State) void {
            self.user_settings.deinit();
        }
    };

    pub fn init(allocator: Allocator, file_picker: *FilePicker) !*Self {
        const self = try allocator.create(Self);

        self.* = .{
            .allocator = allocator,
            .message_queue = try .init(allocator),
            .state = .init(try .init(allocator)),
            .file_picker = file_picker,
            .audio_store = .{},
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
        self.message_queue.deinit();
        self.effect_thread_pool.deinit();
        self.allocator.destroy(self);
    }

    /// Pull messages off the queue and call relevant update/effect functions.
    /// This should never block: update only modifies state, and effects run
    /// in the thread pool.
    pub fn run(self: *Self) void {
        while (true) {
            const msg = self.message_queue.recv() catch |err| {
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

            self.dispatch_effects(msg) catch |err| {
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

    /// Check if there are any registered effects for the message,
    /// and if so, then dispatch on the thread pool.
    fn dispatch_effects(self: *Self, msg: Message) !void {
        switch (msg) {
            inline else => |payload| {
                const Payload = @TypeOf(payload);

                if (comptime Payload != void) {
                    if (comptime @hasDecl(Payload, "effects")) {
                        try self.execute_registered_effects(Payload.effects, payload);
                        return;
                    }
                }

                try self.execute_registered_effects(Message.effects, msg);
            },
        }
    }

    fn execute_registered_effects(self: *Self, comptime effects: anytype, msg: anytype) !void {
        comptime validate_effect_keys(@TypeOf(msg), effects);
        switch (msg) {
            inline else => |payload, tag| {
                const effect_name = @tagName(tag);

                if (comptime !@hasField(@TypeOf(effects), effect_name)) {
                    return;
                }

                const effect_fns = @field(effects, effect_name);

                comptime {
                    if (@typeInfo(@TypeOf(effect_fns)) != .@"struct" or !@typeInfo(@TypeOf(effect_fns)).@"struct".is_tuple) {
                        @compileError("effect must be a tuple: " ++ effect_name);
                    }
                }

                inline for (effect_fns) |effect_fn| {
                    try self.effect_thread_pool.spawn(struct {
                        fn run(store: *Store, effect_payload: @TypeOf(payload)) void {

                            // NOTE: If compiler error here - payload in effect must match
                            // the payload in the message type.
                            switch (comptime @typeInfo(@TypeOf(effect_fn))) {
                                .@"fn" => |f| {
                                    if (f.return_type) |return_type| {
                                        switch (@typeInfo(return_type)) {
                                            .error_union, .error_set => {
                                                effect_fn(store, effect_payload) catch |err| {
                                                    log.err("[execute_registered_effects] error in effect (" ++ @typeName(@TypeOf(effect_fn)) ++ "): {}", .{err});
                                                };
                                            },
                                            else => {
                                                effect_fn(store, effect_payload);
                                            },
                                        }
                                        log.debug("[execute_registered_effects] effect: {s}", .{@typeName(@TypeOf(effect_fn))});
                                    } else {
                                        @compileError(@typeName(@TypeOf(effect_fn)) ++ " has no return type");
                                    }
                                },
                                else => {
                                    @compileError(@typeName(@TypeOf(effect_fn)) ++ " must be a function");
                                },
                            }
                        }
                    }.run, .{ self, payload });
                }
            },
        }
    }

    /// Comptime check to validate that registered effects match a message.
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

    /// Dispatch a message to the queue. Thread safe and non-blocking.
    pub fn dispatch(self: *Self, msg: Message) void {
        self.message_queue.send(msg) catch |err| {
            log.err("[dispatch] {}", .{err});
        };
    }
};
