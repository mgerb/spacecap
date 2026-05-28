const std = @import("std");
const Allocator = std.mem.Allocator;
const BufferedChan = @import("../channel.zig").BufferedChan;
const ChanError = @import("../channel.zig").ChanError;
const Mutex = @import("../mutex.zig").Mutex;
const CaptureStore = @import("./capture_store.zig").CaptureStore;
const AudioCapture = @import("../capture/audio/audio_capture.zig").AudioCapture;
const VideoCapture = @import("../capture/video/video_capture.zig").VideoCapture;
const UserSettingStore = @import("./user_settings_store.zig");
const FilePicker = @import("../file_picker/file_picker.zig").FilePicker;
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const GlobalShortcuts = @import("../global_shortcuts/global_shortcuts.zig").GlobalShortcuts;
const GlobalShortcutsStore = @import("./global_shortcuts_store.zig").GlobalShortcutsStore;

pub const Store = struct {
    const Self = @This();
    const log = std.log.scoped(.store);

    allocator: Allocator,
    io: std.Io,
    message_queue: BufferedChan(Message, 1024),
    state: Mutex(State),
    effect_io_group: std.Io.Group = .init,
    file_picker: FilePicker,
    capture_store: CaptureStore,
    global_shortcuts_store: *GlobalShortcutsStore,

    // ----- Adding a new store -----
    //
    // 1. Add to `ChildStores`.
    // 2. Add message to Message.
    // 3. Add state to State (add deinit if necessary).
    // 4. Add store to Store (if necessary - see capture_store for example).

    const ChildStores = .{
        CaptureStore,
        UserSettingStore,
        GlobalShortcutsStore,
    };

    pub const Message = union(enum) {
        show_demo,
        exit,
        capture: CaptureStore.Message,
        user_settings: UserSettingStore.Message,
        global_shortcuts: GlobalShortcutsStore.Message,

        pub const effects = .{};
    };

    pub const State = struct {
        show_demo: bool = false,

        capture: CaptureStore.State,
        user_settings: UserSettingStore.State,
        global_shortcuts: GlobalShortcutsStore.State = .{},

        pub fn init(allocator: Allocator, io: std.Io) !@This() {
            return .{
                // NOTE: User settings are preloaded and do not follow
                // standard message/effect procedure for startup.
                .user_settings = try .init(allocator, io),
                .capture = try .init(allocator),
            };
        }

        pub fn deinit(self: *State) void {
            self.user_settings.deinit();
            self.capture.deinit();
        }
    };

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        vulkan: *Vulkan,
        file_picker: FilePicker,
        audio_capture: AudioCapture,
        video_capture: VideoCapture,
        global_shortcuts: GlobalShortcuts,
    ) !*Self {
        const self = try allocator.create(Self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .message_queue = try .init(allocator, io),
            .state = .init(io, try .init(allocator, io)),
            .file_picker = file_picker,
            .capture_store = try .init(
                allocator,
                io,
                vulkan,
                self,
                audio_capture,
                video_capture,
            ),
            .global_shortcuts_store = try .init(
                allocator,
                self,
                global_shortcuts,
            ),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        defer self.allocator.destroy(self);
        self.effect_io_group.await(self.io) catch |err| {
            log.err("[deinit] await error: {}", .{err});
        };
        {
            const state_locked = self.state.lock();
            defer state_locked.unlock();
            var state = state_locked.unwrap_ptr();
            state.deinit();
        }
        self.capture_store.deinit();
        self.global_shortcuts_store.deinit();
        self.message_queue.deinit();
    }

    /// All app initialization message that need to be dispatched upon
    /// startup must go here.
    pub fn dispatch_application_startup_messages(self: *Self) void {
        self.dispatch(.{ .capture = .{
            .is_video_capture_supported = self.capture_store.vulkan.video_encode_queue != null,
        } });
        self.dispatch(.{ .capture = .load_system_audio_devices });
        self.dispatch(.{ .capture = .start_audio_capture_thread });

        {
            const state_locked = self.state.lock();
            defer state_locked.unlock();
            const state = state_locked.unwrap_ptr();
            if (state.user_settings.user_settings.restore_capture_source_on_startup) {
                self.dispatch(.{ .capture = .{ .select_video_source = .restore_session } });
            }
        }
    }

    /// Pull messages off the queue and call relevant update/effect functions.
    /// Update only modifies state, and effects run in the thread pool.
    /// This will block until the .exit message.
    pub fn run(
        self: *Self,
        /// These args are currently only used for testing. They allow the processing
        /// of messages one at a time while also enabling the ability to wait for any effects
        /// that it dispatches.
        comptime args: struct {
            /// Run until the message queue is empty and then exit.
            once: bool = false,
            /// Wait for the effects after dispatching them to the thread pool.
            wait_for_effects: bool = false,
        },
    ) void {
        defer {
            if (args.wait_for_effects) {
                self.effect_io_group.await(self.io) catch |err| {
                    log.err("[run] await effects error: {}", .{err});
                };
            }
        }
        while (true) {
            const msg = blk: {
                if (args.once) {
                    break :blk self.message_queue.try_recv() catch |err| {
                        if (err != ChanError.Closed) {
                            log.err("[run] message receive error: {}", .{err});
                        }
                        return;
                    } orelse return;
                } else {
                    break :blk self.message_queue.recv() catch |err| {
                        if (err != ChanError.Closed) {
                            log.err("[run] message receive error: {}", .{err});
                        }
                        return;
                    };
                }
            };

            // NOTE: Any child store cleanup logic must go here.
            if (msg == .exit) {
                log.info("[run] exiting", .{});
                self.capture_store.exit();
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
                        self.execute_registered_effects(Payload.effects, payload);
                        return;
                    }
                }

                self.execute_registered_effects(Message.effects, msg);
            },
        }
    }

    fn execute_registered_effects(self: *Self, comptime effects: anytype, msg: anytype) void {
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
                    self.effect_io_group.concurrent(self.io, struct {
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
                    }.run, .{ self, payload }) catch |err| {
                        log.err("[execute_registered_effects] self.effect_io_group.concurrent error: {}", .{err});
                    };
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

pub const TestStore = struct {
    const Test = @import("../test.zig");
    const VulkanImageBuffer = @import("../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;
    const AudioCaptureData = @import("../capture/audio/audio_capture_data.zig");
    const AudioDeviceList = @import("../capture/audio/audio_capture.zig").AudioDeviceList;
    const Arc = @import("../arc.zig").Arc;
    const types = @import("../types.zig");
    const VideoCaptureSelection = @import("../capture/video/video_capture.zig").VideoCaptureSelection;
    const SelectedAudioDevice = @import("../capture/audio/audio_capture.zig").SelectedAudioDevice;
    const AudioCaptureBufferedChan = @import("../capture/audio/audio_capture.zig").AudioCaptureBufferedChan;

    pub const TestGlobalShortcuts = struct {
        handler: ?GlobalShortcuts.ShortcutHandler = null,
        pub var did_register = false;

        fn run(_: *anyopaque) anyerror!void {}
        fn stop(_: *anyopaque) void {}
        fn open(_: *anyopaque) anyerror!void {}

        fn register_shortcut_handler(context: *anyopaque, handler: GlobalShortcuts.ShortcutHandler) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.handler = handler;
            did_register = true;
        }

        fn global_shortcuts(self: *@This()) GlobalShortcuts {
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

    const TestAudioCapture = struct {
        stopped: bool = false,
        selected_devices_updated: bool = false,
        data: AudioCaptureBufferedChan,

        pub fn init(allocator: Allocator) !@This() {
            return .{
                .data = try .init(allocator, std.testing.io),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.data.deinit();
        }

        fn receive_data(context: *anyopaque) ChanError!Arc(AudioCaptureData) {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.data.recv();
        }

        fn stop(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.stopped = true;
        }

        fn get_available_devices(_: *anyopaque, allocator: std.mem.Allocator, _: std.Io) anyerror!AudioDeviceList {
            var audio_device_list = try AudioDeviceList.init(allocator);
            try audio_device_list.append(.{
                .id = "test1",
                .name = "test_device_1",
                .device_type = .sink,
                .is_default = true,
            });
            try audio_device_list.append(.{
                .id = "test2",
                .name = "test_device_2",
                .device_type = .source,
                .is_default = false,
            });
            return audio_device_list;
        }

        fn update_selected_devices(context: *anyopaque, _: []const SelectedAudioDevice) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.selected_devices_updated = true;
        }

        fn audio_capture(self: *@This()) AudioCapture {
            return .{
                .ptr = self,
                .vtable = &.{
                    .receive_data = receive_data,
                    .stop = stop,
                    .get_available_devices = get_available_devices,
                    .update_selected_devices = update_selected_devices,
                },
            };
        }
    };

    const TestVideoCapture = struct {
        selected: bool = false,
        stopped: bool = false,
        closed_channels: bool = false,
        restore_session: bool = false,
        capture_size: ?types.Size = .{ .width = 1920, .height = 1080 },

        fn select_source(context: *anyopaque, _: VideoCaptureSelection, _: u32) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.selected = true;
        }

        fn update_fps(_: *anyopaque, _: u32) anyerror!void {}

        fn should_restore_capture_session(context: *anyopaque) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.restore_session;
        }

        fn next_frame(_: *anyopaque) ChanError!void {
            return error.Closed;
        }

        fn close_all_channels(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closed_channels = true;
        }

        fn wait_for_frame(_: *anyopaque) ChanError!Arc(VulkanImageBuffer) {
            return error.Closed;
        }

        fn size(context: *anyopaque) ?types.Size {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.capture_size;
        }

        fn stop(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.stopped = true;
        }

        fn video_capture(self: *@This()) VideoCapture {
            return .{
                .ptr = self,
                .vtable = &.{
                    .select_source = select_source,
                    .update_fps = update_fps,
                    .should_restore_capture_session = should_restore_capture_session,
                    .next_frame = next_frame,
                    .close_all_channels = close_all_channels,
                    .wait_for_frame = wait_for_frame,
                    .size = size,
                    .stop = stop,
                },
            };
        }
    };

    pub const TestFilePicker = struct {
        fn open_directory_picker(_: *anyopaque, allocator: Allocator, _: std.Io, _: ?[]const u8) anyerror![]u8 {
            return allocator.dupe(u8, "/tmp");
        }

        fn file_picker(self: *@This()) FilePicker {
            return .{
                .ptr = self,
                .vtable = &.{
                    .open_directory_picker = open_directory_picker,
                },
            };
        }
    };

    // ----------------------------------------------------------------------------
    // TestStore definition starts here.
    // ----------------------------------------------------------------------------
    allocator: Allocator,
    store: *Store,
    vulkan: Vulkan,

    test_file_picker: TestFilePicker,
    file_picker_interface: FilePicker,

    test_audio_capture: TestAudioCapture,
    audio_capture: AudioCapture,

    test_video_capture: TestVideoCapture,
    video_capture: VideoCapture,

    test_global_shortcuts: TestGlobalShortcuts,
    global_shortcuts: GlobalShortcuts,

    pub fn init(allocator: Allocator) !*@This() {
        try Test.init_temp_app_data_dir();

        const self = try allocator.create(@This());

        self.* = .{
            .allocator = allocator,
            .vulkan = undefined,
            .store = undefined,
            .test_file_picker = .{},
            .file_picker_interface = undefined,
            .test_audio_capture = try .init(allocator),
            .audio_capture = undefined,
            .test_video_capture = .{},
            .video_capture = undefined,
            .test_global_shortcuts = .{},
            .global_shortcuts = undefined,
        };

        self.audio_capture = self.test_audio_capture.audio_capture();
        self.video_capture = self.test_video_capture.video_capture();
        self.global_shortcuts = self.test_global_shortcuts.global_shortcuts();
        self.file_picker_interface = self.test_file_picker.file_picker();

        self.vulkan.video_encoder = null;
        self.vulkan.video_encode_queue = null;
        self.vulkan.window = null;
        self.vulkan.capture_preview_ring_buffer = .init(std.testing.io, null);
        self.vulkan.capture_ring_buffer = .init(std.testing.io, null);
        self.vulkan.capture_preview_textures = .init(allocator);

        self.store = try .init(
            allocator,
            std.testing.io,
            &self.vulkan,
            self.file_picker_interface,
            self.audio_capture,
            self.video_capture,
            self.global_shortcuts,
        );

        return self;
    }

    pub fn deinit(self: *@This()) void {
        defer self.allocator.destroy(self);
        self.test_audio_capture.deinit();
        self.store.deinit();
        Test.destroy_temp_app_data_dir();
    }
};
