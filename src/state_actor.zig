const std = @import("std");
const assert = std.debug.assert;

const vk = @import("vulkan");

const Util = @import("./util.zig");
const VideoCapture = @import("./capture/video/video_capture.zig").VideoCapture;
const VideoCaptureError = @import("./capture/video/video_capture.zig").VideoCaptureError;
const VideoCaptureSourceType = @import("./capture/video/video_capture.zig").VideoCaptureSourceType;
const AudioCapture = @import("./capture/audio/audio_capture.zig").AudioCapture;
const SAMPLE_RATE = @import("./capture/audio/audio_capture.zig").SAMPLE_RATE;
const CHANNELS = @import("./capture/audio/audio_capture.zig").CHANNELS;
const GlobalShortcuts = @import("./global_shortcuts/global_shortcuts.zig").GlobalShortcuts;
const BufferedChan = @import("./channel.zig").BufferedChan;
const ChanError = @import("./channel.zig").ChanError;
const Mutex = @import("./mutex.zig").Mutex;
const State = @import("./state.zig");
const Vulkan = @import("./vulkan/vulkan.zig").Vulkan;
const VideoReplayBuffer = @import("./vulkan/video_replay_buffer.zig").VideoReplayBuffer;
const exporter = @import("./exporter.zig");
const AudioActions = @import("./state/audio_state.zig").AudioActions;
const UserSettingsActions = @import("./state/user_settings_state.zig").UserSettingsActions;

const log = std.log.scoped(.state_actor);

pub const Actions = union(enum) {
    start_record,
    stop_record,
    select_video_source: VideoCaptureSourceType,
    save_replay,
    show_demo,
    exit,
    open_global_shortcuts,
    user_settings: UserSettingsActions,
    audio: AudioActions,
};

const ActionChan = BufferedChan(Actions, 100);

const UpdateDeviceAction = ActionPayload(struct {
    device_id: []u8,

    pub fn init(
        arena: *std.heap.ArenaAllocator,
        args: struct { device_id: []u8 },
    ) !@This() {
        return .{
            .device_id = try arena.allocator().dupe(u8, args.device_id),
        };
    }
});

/// A helper type for actions that require heap allocations.
/// T must define an 'init' function with (arena, args) parameters.
/// All allocations in the underlying struct are cleaned up by the
/// arena in the ActionPayload parent struct.
///
/// e.g.
///
/// ```zig
/// const UpdateDeviceAction = *ActionPayload(struct {
///     device_id: []u8,
///
///    pub fn init(
///        arena: *std.heap.ArenaAllocator,
///        args: struct { device_id: []u8 },
///     ) !@This() {
///         return .{
///             .device_id = try arena.allocator().dupe(u8, args.device_id),
///         };
///     }
/// });
///
/// // Usage looks like this.
/// const action: *UpdateDeviceAction = try .init(allocator, .{ .device_id = &.{} });
/// defer action.deinit();
/// const id = action.payload.device_id;
/// ...
/// ```
pub fn ActionPayload(T: anytype) type {
    const init_fn_type_info = @typeInfo(@TypeOf(@field(T, "init")));
    const init_fn = init_fn_type_info.@"fn";

    const compiler_error = "ActionPayload requires T.init(arena: *std.heap.ArenaAllocator, args: <anystruct>) with exactly 2 parameters where args is of type struct.";

    if (!@hasDecl(T, "init") or init_fn_type_info != .@"fn") {
        @compileError(@typeName(T) ++ " must contain an 'init' function.");
    }

    if (init_fn.params.len != 2 or @typeInfo(init_fn.params[1].type.?) != .@"struct") {
        @compileError(compiler_error);
    }

    const first_param = @typeInfo(init_fn.params[0].type.?);
    if (first_param != .pointer or first_param.pointer.child != std.heap.ArenaAllocator) {
        @compileError(compiler_error);
    }

    const InitArgs = init_fn.params[1].type.?;

    return struct {
        arena: *std.heap.ArenaAllocator,
        payload: T,

        pub fn init(allocator: std.mem.Allocator, args: InitArgs) !*@This() {
            const arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = .init(allocator);

            const self = try arena.allocator().create(@This());
            self.* = .{
                .arena = arena,
                .payload = try T.init(arena, args),
            };

            return self;
        }

        pub fn deinit(self: *@This()) void {
            const arena = self.arena;
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(arena);
        }
    };
}

/// The main application state based on the actor model.
pub const StateActor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    vulkan: *Vulkan,
    // TODO: Create video_state and move video logic.
    video_capture: *VideoCapture,
    global_shortcuts: *GlobalShortcuts,
    video_replay_buffer: Mutex(?*VideoReplayBuffer) = .init(null),
    action_chan: ActionChan,
    thread_pool: std.Thread.Pool = undefined,
    /// WARNING: This locks the UI thread. This should only be locked
    /// when making updates to the UI state.
    ui_mutex: std.Thread.Mutex = .{},
    video_record_mutex: std.Thread.Mutex = .{},
    state: State,
    video_capture_thread: ?std.Thread = null,

    /// Caller owns the memory. Be sure to deinit.
    pub fn init(
        allocator: std.mem.Allocator,
        vulkan: *Vulkan,
        video_capture: *VideoCapture,
        audio_capture: *AudioCapture,
        global_shortcuts: *GlobalShortcuts,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = Self{
            .allocator = allocator,
            .vulkan = vulkan,
            .video_capture = video_capture,
            .global_shortcuts = global_shortcuts,
            .action_chan = try ActionChan.init(allocator),
            // TODO: The state is getting a bit unwiedly and coupled.
            // Need to spend some more time refactoring.
            .state = try .init(
                allocator,
                vulkan.video_encode_queue != null,
                audio_capture,
            ),
        };
        errdefer self.state.deinit();

        try self.thread_pool.init(.{ .allocator = allocator, .n_jobs = 10 });

        try self.dispatch(.{ .audio = .get_available_audio_devices });
        try self.dispatch(.{ .audio = .start_record_thread });

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.thread_pool.deinit();

        const video_locked = self.video_replay_buffer.lock();
        defer video_locked.unlock();
        if (video_locked.unwrap()) |video_replay_buffer| {
            video_replay_buffer.deinit();
        }

        self.state.deinit();
        self.action_chan.deinit();
        self.allocator.destroy(self);
    }

    /// Does not return an error because this should always run.
    /// Handle errors internally.
    /// TODO: Add errors to the state and present on UI.
    pub fn run(self: *Self) void {
        while (true) {
            const action = self.action_chan.recv() catch |err| {
                if (err == ChanError.Closed) {
                    break;
                } else {
                    log.info("actor loop terminating: {}\n", .{err});
                    break;
                }
            };

            if (action == .exit) {
                self.handleAction(action) catch |err| {
                    log.err("exit err: {}\n", .{err});
                };
                break;
            }

            const ActionThread = struct {
                fn run(_self: *Self, _action: Actions) void {
                    _self.handleAction(_action) catch |err| {
                        log.err("handleAction error: {}\n", .{err});
                    };
                }
            };

            self.thread_pool.spawn(ActionThread.run, .{ self, action }) catch |err| {
                log.err("thread_pool spawn error: {}\n", .{err});
            };
        }
    }

    fn handleAction(self: *Self, action: Actions) !void {
        switch (action) {
            .start_record => {
                try self.startRecord();
            },
            .stop_record => {
                try self.stopRecord();
            },
            .save_replay => {
                var fps: u32 = 0;
                var replay_seconds: u32 = 0;
                {
                    self.ui_mutex.lock();
                    defer self.ui_mutex.unlock();
                    if (!self.state.is_recording_video) {
                        log.debug("[handleAction] save_replay - not recording, skipping capture", .{});
                        return;
                    }
                    fps = self.state.fps;
                    replay_seconds = self.state.replay_seconds;
                }

                // We should always have a size if the state is recording.
                assert(self.video_capture.size() != null);
                const size = self.video_capture.size().?;

                const audio_replay_buffer = (try self.state.audio.swapReplayBuffer(
                    self.allocator,
                    replay_seconds,
                )).?;
                errdefer audio_replay_buffer.deinit();

                var video_replay_buffer: ?*VideoReplayBuffer = null;
                {
                    self.video_record_mutex.lock();
                    defer self.video_record_mutex.unlock();

                    const video_encoder = self.vulkan.video_encoder orelse return error.video_encoder_is_null;

                    var video_replay_buffer_locked = self.video_replay_buffer.lock();
                    defer video_replay_buffer_locked.unlock();
                    video_replay_buffer = video_replay_buffer_locked.unwrap();

                    // video_replay_buffer should never be null here. If the state is recording,
                    // it will always be valid.
                    assert(video_replay_buffer != null);

                    video_replay_buffer_locked.set(try .init(
                        self.allocator,
                        replay_seconds,
                        video_encoder.bit_stream_header.items,
                    ));
                }

                try exporter.exportReplayBuffers(
                    self.allocator,
                    size.width,
                    size.height,
                    fps,
                    video_replay_buffer.?,
                    audio_replay_buffer,
                    SAMPLE_RATE,
                    CHANNELS,
                );
            },
            .select_video_source => |source_type| {
                try self.stopCapture();

                self.video_capture.selectSource(source_type) catch |err| {
                    if (err != VideoCaptureError.source_picker_cancelled) {
                        log.err("selectSource error: {}\n", .{err});
                        return err;
                    } else {
                        log.info("source_picker_cancelled\n", .{});
                    }
                    return;
                };

                try self.startCapture();
            },
            .show_demo => {
                self.ui_mutex.lock();
                defer self.ui_mutex.unlock();
                self.state.show_demo = !self.state.show_demo;
            },
            .exit => {
                try self.stopCapture();
            },
            .open_global_shortcuts => {
                try self.global_shortcuts.open();
            },
            .user_settings => {
                try self.state.user_settings.handleActions(self, action.user_settings);
            },
            .audio => {
                try self.state.audio.handleActions(self, action.audio);
            },
        }
    }

    pub fn globalShortcutsHandler(context: *anyopaque, shortcut: GlobalShortcuts.Shortcut) void {
        const self: *Self = @ptrCast(@alignCast(context));
        switch (shortcut) {
            .save_replay => {
                self.dispatch(.save_replay) catch unreachable;
            },
        }
    }

    /// TODO: move most of this to capture?
    /// This is the main capture loop.
    fn videoCaptureThreadHandler(self: *Self) !void {
        self.ui_mutex.lock();
        const fps = self.state.fps;
        self.ui_mutex.unlock();

        var previous_frame_start_time: i128 = 0;

        while (true) {
            // Here we wait until the next projected frame time. This will happen if we are
            // capturing/encoding frames to quickly.
            const ns_per_frame = (1.0 / @as(f64, @floatFromInt(fps))) * std.time.ns_per_s;
            const now = std.time.nanoTimestamp();
            const next_projected_frame_start_time = previous_frame_start_time + @as(u64, @intFromFloat(ns_per_frame));

            if (previous_frame_start_time > 0 and next_projected_frame_start_time > now) {
                // TODO: add to state
                Util.printElapsed(previous_frame_start_time, "previous_frame_start_time");
                std.Thread.sleep(@intCast(next_projected_frame_start_time - now));
            }

            previous_frame_start_time = std.time.nanoTimestamp();

            self.video_capture.nextFrame() catch |err| {
                if (err == ChanError.Closed) {
                    log.info("self.capture.nextFrame: chan closed, exiting record thread\n", .{});
                    break;
                }
                return err;
            };

            // This thing is ref counted so release when we are done with it here.
            const vulkan_image_buffer = self.video_capture.waitForFrame() catch |err| {
                if (err == ChanError.Closed) {
                    log.info("self.capture.waitForFrame: chan closed, exiting record thread\n", .{});
                    break;
                }
                return err;
            };
            defer {
                vulkan_image_buffer.value.*.in_use.store(false, .release);
                if (vulkan_image_buffer.releaseUnwrap()) |val| {
                    val.deinit();
                }
            }

            var image_slc = [_]vk.Image{vulkan_image_buffer.value.*.image};
            var image_view_slc = [_]vk.ImageView{vulkan_image_buffer.value.*.image_view};

            const is_recording = blk: {
                self.ui_mutex.lock();
                defer self.ui_mutex.unlock();
                break :blk self.state.is_recording_video;
            };

            const copy_data = blk: {
                const capture_preview_ring_buffer_locked = self.vulkan.capture_preview_ring_buffer.lock();
                defer capture_preview_ring_buffer_locked.unlock();
                const _copy_data = try capture_preview_ring_buffer_locked.unwrap().?.copyImageToRingBuffer(
                    .{
                        .src_image = image_slc[0],
                        .src_width = vulkan_image_buffer.value.*.width,
                        .src_height = vulkan_image_buffer.value.*.height,
                        .wait_semaphore = null,
                        // Only signal this semaphore when encode will wait on it.
                        .use_signal_semaphore = is_recording,
                        .timestamp_ns = vulkan_image_buffer.value.*.timestamp_ns,
                    },
                );
                break :blk _copy_data;
            };

            if (!is_recording) {
                // In capture-only mode no downstream work waits on the preview copy.
                // Wait here so the capture-ring source image is not recycled while still in flight.
                if (copy_data.fence) |fence| {
                    _ = self.vulkan.device.waitForFences(1, @ptrCast(&fence), .true, std.math.maxInt(u64)) catch |err| {
                        log.err("[videoCaptureThreadHandler] preview copy wait error: {}", .{err});
                    };
                }
                continue;
            }

            self.video_record_mutex.lock();
            defer self.video_record_mutex.unlock();

            const video_encoder = self.vulkan.video_encoder orelse continue;
            const video_locked = self.video_replay_buffer.lock();
            defer video_locked.unlock();
            const video_replay_buffer = video_locked.unwrap() orelse continue;

            try video_encoder.prepareEncode(.{
                .image = &image_slc,
                .image_view = &image_view_slc,
                .input_size = .{
                    .width = vulkan_image_buffer.value.*.width,
                    .height = vulkan_image_buffer.value.*.height,
                },
                .external_wait_semaphore = copy_data.semaphore,
            });

            const encode_result = try video_encoder.encode(0);
            try video_encoder.finishEncode(
                encode_result,
                video_replay_buffer,
                vulkan_image_buffer.value.*.timestamp_ns,
            );
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            self.state.replay_buffer.size = video_replay_buffer.size;
            self.state.replay_buffer.seconds = video_replay_buffer.getSeconds();
        }
    }

    fn startCapture(self: *Self) !void {
        const size = self.video_capture.size() orelse {
            return error.video_capture_size_not_found;
        };

        try self.vulkan.initCapturePreviewRingBuffer(size.width, size.height);
        errdefer self.vulkan.destroyCapturePreviewRingBuffer();

        self.video_capture_thread = try std.Thread.spawn(.{}, videoCaptureThreadHandler, .{self});

        self.ui_mutex.lock();
        defer self.ui_mutex.unlock();
        assert(self.state.is_capturing_video == false);
        assert(self.state.is_recording_video == false);
        self.state.is_capturing_video = true;
    }

    fn stopCapture(self: *Self) !void {
        try self.stopRecord();

        {
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            self.state.is_capturing_video = false;
        }

        // Force the record loop to exit by closing all capture channels.
        self.video_capture.closeAllChannels();

        // Wait for the video record thread loop to complete.
        if (self.video_capture_thread) |video_capture_thread| {
            video_capture_thread.join();
            self.video_capture_thread = null;
        }

        self.vulkan.destroyCapturePreviewRingBuffer();

        try self.video_capture.stop();
    }

    fn startRecord(self: *Self) !void {
        self.video_record_mutex.lock();
        defer self.video_record_mutex.unlock();

        var fps: u32 = 0;
        var bit_rate: u64 = 0;
        var replay_seconds: u32 = 0;
        {
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            if (!self.state.is_capturing_video or self.state.is_recording_video) return;
            fps = self.state.fps;
            bit_rate = self.state.bit_rate;
            replay_seconds = self.state.replay_seconds;
        }

        const size = self.video_capture.size() orelse {
            return error.video_capture_size_not_found;
        };

        try self.vulkan.initVideoEncoder(
            size.width,
            size.height,
            fps,
            bit_rate,
        );
        errdefer self.vulkan.destroyVideoEncoder();

        {
            var video_locked = self.video_replay_buffer.lock();
            defer video_locked.unlock();
            if (video_locked.unwrap()) |video_replay_buffer| {
                video_replay_buffer.deinit();
            }

            video_locked.set(try VideoReplayBuffer.init(
                self.allocator,
                replay_seconds,
                self.vulkan.video_encoder.?.bit_stream_header.items,
            ));
        }

        self.ui_mutex.lock();
        defer self.ui_mutex.unlock();
        if (!self.state.is_recording_video) {
            self.state.is_recording_video = true;
        }
    }

    fn stopRecord(self: *Self) !void {
        self.video_record_mutex.lock();
        defer self.video_record_mutex.unlock();

        {
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            self.state.is_recording_video = false;
            self.state.replay_buffer = .{};
        }

        self.vulkan.destroyVideoEncoder();

        var video_locked = self.video_replay_buffer.lock();
        defer video_locked.unlock();
        const video_replay_buffer = video_locked.unwrap();
        if (video_replay_buffer) |vrb| {
            vrb.deinit();
            video_locked.set(null);
        }
    }

    /// Dispatch an action to the actor.
    ///
    /// WARN: The actor uses a buffered channel,
    /// and it will block the caller if it fills up.
    /// Be careful when using this from the UI thread.
    pub fn dispatch(self: *Self, action: Actions) !void {
        log.debug("[dispatch] dispatching action: {}", .{action});
        try self.action_chan.send(action);
    }
};
