const std = @import("std");

const vk = @import("vulkan");

const Util = @import("./util.zig");
const VideoCapture = @import("./capture/video/video_capture.zig").VideoCapture;
const VideoCaptureError = @import("./capture/video/video_capture.zig").VideoCaptureError;
const VideoCaptureSourceType = @import("./capture/video/video_capture.zig").VideoCaptureSourceType;
const AudioCapture = @import("./capture/audio/audio_capture.zig").AudioCapture;
const GlobalShortcuts = @import("./global_shortcuts/global_shortcuts.zig").GlobalShortcuts;
const BufferedChan = @import("./channel.zig").BufferedChan;
const ChanError = @import("./channel.zig").ChanError;
const Chan = @import("./channel.zig").Chan;
const State = @import("./state.zig");
const Vulkan = @import("./vulkan/vulkan.zig").Vulkan;
const ReplayBuffer = @import("./vulkan/replay_buffer.zig").ReplayBuffer;
const ffmpeg = @import("./ffmpeg.zig");
const UserSettings = @import("./user_settings.zig").UserSettings;
const types = @import("./types.zig");

const log = std.log.scoped(.state_actor);

pub const Actions = union(enum) {
    start_record,
    stop_record,
    select_video_source: VideoCaptureSourceType,
    save_replay,
    show_demo,
    exit,
    set_gui_foreground_fps: u32,
    set_gui_background_fps: u32,
    open_global_shortcuts,
};

const ActionChan = BufferedChan(Actions, 100);

/// The main application state based on the actor model.
pub const StateActor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    vulkan: *Vulkan,
    video_capture: *VideoCapture,
    audio_capture: *AudioCapture,
    global_shortcuts: *GlobalShortcuts,
    replay_buffer: ?*ReplayBuffer = null,
    replay_buffer_mutex: std.Thread.Mutex = .{},
    action_chan: ActionChan,
    thread_pool: std.Thread.Pool = undefined,
    /// WARNING: This locks the UI thread. This should only be locked
    /// when making updates to the UI state.
    ui_mutex: std.Thread.Mutex = .{},
    state: State,
    video_record_thread: ?std.Thread = null,
    audio_record_thread: ?std.Thread = null,

    /// Caller owns the memory. Be sure to deinit.
    pub fn init(
        allocator: std.mem.Allocator,
        vulkan: *Vulkan,
        video_capture: *VideoCapture,
        audio_capture: *AudioCapture,
        global_shortcuts: *GlobalShortcuts,
    ) !*Self {
        const self = try allocator.create(Self);

        // Just log the error. We don't want the app to crash if settings can't be
        // loaded for some unexpected error such as permissions issues.
        const user_settings = UserSettings.load(allocator) catch |err| blk: {
            log.err("unable to load user settings: {}\n", .{err});
            break :blk UserSettings{};
        };

        self.* = Self{
            .allocator = allocator,
            .vulkan = vulkan,
            .video_capture = video_capture,
            .audio_capture = audio_capture,
            .global_shortcuts = global_shortcuts,
            .action_chan = try ActionChan.init(allocator),
            .state = State.init(user_settings, vulkan.video_encode_queue != null),
        };

        try self.thread_pool.init(.{ .allocator = allocator, .n_jobs = 10 });

        return self;
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
                log.info("[action] start_record\n", .{});
                try self.startRecord();
            },
            .stop_record => {
                log.info("[action] stop_record\n", .{});
                try self.stopRecord();
            },
            .save_replay => {
                log.info("[action] save_replay\n", .{});

                if (self.replay_buffer) |replay_buffer| {
                    self.replay_buffer_mutex.lock();
                    self.replay_buffer = try ReplayBuffer.init(
                        self.allocator,
                        self.state.replay_seconds,
                        self.vulkan.video_encoder.?.bit_stream_header.items,
                    );
                    self.replay_buffer_mutex.unlock();

                    self.ui_mutex.lock();
                    const size = self.video_capture.size().?;
                    const fps = self.state.fps;
                    self.ui_mutex.unlock();

                    try ffmpeg.writeToFile(
                        self.allocator,
                        size.width,
                        size.height,
                        fps,
                        replay_buffer,
                    );
                }
            },
            .select_video_source => |source_type| {
                log.info("[action] select_video_source\n", .{});
                if (self.state.recording) {
                    try self.stopRecord();
                }

                self.video_capture.selectSource(source_type) catch |err| {
                    if (err != VideoCaptureError.source_picker_cancelled) {
                        log.err("selectSource error: {}\n", .{err});
                        return err;
                    } else {
                        log.info("source_picker_cancelled\n", .{});
                    }
                    return;
                };

                self.ui_mutex.lock();
                defer self.ui_mutex.unlock();
                self.state.has_source = true;
                // TODO: pass allocator to state and copy this string into it
                if (self.state.selected_screen_cast_identifier) |old_name| {
                    self.allocator.free(old_name);
                    self.state.selected_screen_cast_identifier = null;
                }
                // TODO:
                // if (self.capture.selectedScreenCastIdentifier()) |name| {
                //     self.state.selected_screen_cast_identifier = try self.allocator.dupe(u8, name);
                // }
            },
            .show_demo => {
                self.ui_mutex.lock();
                defer self.ui_mutex.unlock();
                self.state.show_demo = !self.state.show_demo;
            },
            .exit => {
                try self.stopRecord();
            },
            .set_gui_foreground_fps => |fps| {
                self.ui_mutex.lock();
                self.state.user_settings.gui_foreground_fps = fps;
                const user_settings_copy = self.state.user_settings;
                self.ui_mutex.unlock();
                // Write the settings outside of the lock
                try user_settings_copy.save(self.allocator);
            },
            .set_gui_background_fps => |fps| {
                self.ui_mutex.lock();
                self.state.user_settings.gui_background_fps = fps;
                const user_settings_copy = self.state.user_settings;
                self.ui_mutex.unlock();
                // Write the settings outside of the lock
                try user_settings_copy.save(self.allocator);
            },

            .open_global_shortcuts => {
                try self.global_shortcuts.open();
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

    // TODO: Start here. Segfault here. Need to close this thread handler before state_actor is destroyed,
    // because the audio source closes the channel and destroys it immediately after.
    fn startAudioRecordThreadHandler(self: *Self) !void {
        while (true) {
            var data = self.audio_capture.receiveData() catch |err| {
                if (err == ChanError.Closed) {
                    log.debug("[startAudioRecordThreadHandler] chan closed", .{});
                    break;
                }
                log.err("[startAudioRecordThreadHandler] data_chan error: {}", .{err});
                return err;
            };
            defer data.deinit();

            log.debug("[startAudioRecordThreadHandler] got audio data: {s}", .{data.id});
        }
    }

    /// TODO: move most of this to capture?
    /// This is the main capture loop.
    fn startVideoRecordThreadHandler(self: *Self) !void {
        self.ui_mutex.lock();
        const fps = self.state.fps;
        const bit_rate = self.state.bit_rate;
        const width = self.video_capture.size().?.width;
        const height = self.video_capture.size().?.height;
        self.ui_mutex.unlock();
        // Initialize the video encoder here. It will be destroyed
        // when the record thread terminates.
        try self.vulkan.initVideoEncoder(
            width,
            height,
            fps,
            bit_rate,
        );
        defer self.vulkan.destroyVideoEncoder();

        // Initialize the replay buffer. This replay buffer
        // will be destroyed/recreated each time a replay is saved.
        {
            self.replay_buffer_mutex.lock();
            defer self.replay_buffer_mutex.unlock();

            self.replay_buffer = try ReplayBuffer.init(
                self.allocator,
                self.state.replay_seconds,
                self.vulkan.video_encoder.?.bit_stream_header.items,
            );
        }

        try self.vulkan.initCapturePreviewRingBuffer(width, height);

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

            const copy_data = try self.vulkan.capture_preview_ring_buffer.?.copyImageToRingBuffer(
                .{
                    .src_image = image_slc[0],
                    .src_width = vulkan_image_buffer.value.*.width,
                    .src_height = vulkan_image_buffer.value.*.height,
                    .wait_semaphore = null,
                    .use_signal_semaphore = true,
                },
            );

            try self.vulkan.video_encoder.?.prepareEncode(.{
                .image = &image_slc,
                .image_view = &image_view_slc,
                .input_size = .{
                    .width = vulkan_image_buffer.value.*.width,
                    .height = vulkan_image_buffer.value.*.height,
                },
                .external_wait_semaphore = copy_data.semaphore,
            });

            const encode_result = try self.vulkan.video_encoder.?.encode(0);
            self.replay_buffer_mutex.lock();
            defer self.replay_buffer_mutex.unlock();
            try self.vulkan.video_encoder.?.finishEncode(encode_result, self.replay_buffer.?, vulkan_image_buffer.value.*.copy_image_timestamp);
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            self.state.replay_buffer_state.size = self.replay_buffer.?.size;
            self.state.replay_buffer_state.seconds = self.replay_buffer.?.getSeconds();
        }
    }

    fn stopRecord(self: *Self) !void {
        {
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            self.state.recording = false;
            self.state.has_source = false;
        }

        // Force the record loop to exit by closing all capture channels.
        self.video_capture.closeAllChannels();

        // Wait for the video record thread loop to complete.
        if (self.video_record_thread) |video_record_thread| {
            video_record_thread.join();
            self.video_record_thread = null;
        }

        try self.vulkan.destroyCapturePreviewRingBuffer();

        try self.video_capture.stop();

        if (self.replay_buffer) |replay_buffer| {
            replay_buffer.deinit();
            self.replay_buffer = null;
        }
    }

    fn startRecord(self: *Self) !void {
        self.ui_mutex.lock();
        defer self.ui_mutex.unlock();

        if (self.state.has_source and !self.state.recording) {
            self.state.recording = true;
            self.video_record_thread = try std.Thread.spawn(.{}, startVideoRecordThreadHandler, .{self});
            self.audio_record_thread = try std.Thread.spawn(.{}, startAudioRecordThreadHandler, .{self});
        }
    }

    /// Dispatch an action to the actor.
    ///
    /// WARN: The actor uses a buffered channel,
    /// and it will block the caller if it fills up.
    /// Be careful when using this from the UI thread.
    pub fn dispatch(self: *Self, action: Actions) !void {
        try self.action_chan.send(action);
    }

    pub fn deinit(self: *Self) void {
        self.thread_pool.deinit();
        if (self.replay_buffer) |replay_buffer| {
            replay_buffer.deinit();
        }
        // TODO: move this to state
        if (self.state.selected_screen_cast_identifier) |selected_screen_name| {
            self.allocator.free(selected_screen_name);
        }
        self.action_chan.deinit();
        self.allocator.destroy(self);
    }
};
