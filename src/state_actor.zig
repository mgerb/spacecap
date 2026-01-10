const std = @import("std");
const assert = std.debug.assert;

const vk = @import("vulkan");

const Util = @import("./util.zig");
const VideoCapture = @import("./capture/video/video_capture.zig").VideoCapture;
const VideoCaptureError = @import("./capture/video/video_capture.zig").VideoCaptureError;
const VideoCaptureSourceType = @import("./capture/video/video_capture.zig").VideoCaptureSourceType;
const AudioCapture = @import("./capture/audio/audio_capture.zig").AudioCapture;
const SelectedAudioDevice = @import("./capture/audio/audio_capture.zig").SelectedAudioDevice;
const SAMPLE_RATE = @import("./capture/audio/audio_capture.zig").SAMPLE_RATE;
const CHANNELS = @import("./capture/audio/audio_capture.zig").CHANNELS;
const AudioReplayBuffer = @import("./capture/audio/audio_replay_buffer.zig");
const GlobalShortcuts = @import("./global_shortcuts/global_shortcuts.zig").GlobalShortcuts;
const BufferedChan = @import("./channel.zig").BufferedChan;
const ChanError = @import("./channel.zig").ChanError;
const Mutex = @import("./mutex.zig").Mutex;
const State = @import("./state.zig");
const Vulkan = @import("./vulkan/vulkan.zig").Vulkan;
const VideoReplayBuffer = @import("./vulkan/video_replay_buffer.zig").VideoReplayBuffer;
const exporter = @import("./exporter.zig");
const AudioActions = @import("./state/audio_state.zig").AudioActions;
const handleAudioActions = @import("./state/audio_state.zig").handleAudioActions;
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

/// The main application state based on the actor model.
pub const StateActor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    vulkan: *Vulkan,
    video_capture: *VideoCapture,
    audio_capture: *AudioCapture,
    global_shortcuts: *GlobalShortcuts,
    video_replay_buffer: Mutex(?*VideoReplayBuffer) = .init(null),
    audio_replay_buffer: Mutex(?*AudioReplayBuffer) = .init(null),
    action_chan: ActionChan,
    thread_pool: std.Thread.Pool = undefined,
    /// WARNING: This locks the UI thread. This should only be locked
    /// when making updates to the UI state.
    ui_mutex: std.Thread.Mutex = .{},
    // TODO: Put a mutex around State and then remove ui_mutex.
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
        errdefer allocator.destroy(self);

        self.* = Self{
            .allocator = allocator,
            .vulkan = vulkan,
            .video_capture = video_capture,
            .audio_capture = audio_capture,
            .global_shortcuts = global_shortcuts,
            .action_chan = try ActionChan.init(allocator),
            .state = try State.init(allocator, vulkan.video_encode_queue != null),
        };
        errdefer self.state.deinit();

        try self.thread_pool.init(.{ .allocator = allocator, .n_jobs = 10 });

        try self.dispatch(.{ .audio = .get_available_audio_devices });

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.thread_pool.deinit();

        const video_locked = self.video_replay_buffer.lock();
        defer video_locked.unlock();
        if (video_locked.unwrap()) |video_replay_buffer| {
            video_replay_buffer.deinit();
        }

        const audio_locked = self.audio_replay_buffer.lock();
        defer audio_locked.unlock();
        if (audio_locked.unwrap()) |audio_replay_buffer| {
            audio_replay_buffer.deinit();
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

    // fn updateSelectedAudioDevices(self: *Self) !void {
    //     var selected_devices = try std.ArrayList(SelectedAudioDevice).initCapacity(self.allocator, 0);
    //     defer selected_devices.deinit(self.allocator);
    //
    //     for (self.state.audio_devices.items) |device| {
    //         if (!device.selected) continue;
    //         try selected_devices.append(self.allocator, .{
    //             .id = device.id,
    //             .device_type = device.device_type,
    //         });
    //     }
    //
    //     try self.audio_capture.updateSelectedDevices(selected_devices.items);
    // }

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

                // NOTE: Both audio/video replay buffers must not be null here.

                var audio_replay_buffer: ?*AudioReplayBuffer = null;
                {
                    var audio_locked = self.audio_replay_buffer.lock();
                    defer audio_locked.unlock();
                    audio_replay_buffer = audio_locked.unwrap();
                    audio_locked.set(try .init(
                        self.allocator,
                        self.state.replay_seconds,
                    ));
                }

                assert(audio_replay_buffer != null);

                var video_replay_buffer: ?*VideoReplayBuffer = null;
                {
                    var video_locked = self.video_replay_buffer.lock();
                    defer video_locked.unlock();
                    video_replay_buffer = video_locked.unwrap();
                    video_locked.set(try .init(
                        self.allocator,
                        self.state.replay_seconds,
                        self.vulkan.video_encoder.?.bit_stream_header.items,
                    ));
                }

                assert(video_replay_buffer != null);

                const size = self.video_capture.size().?;
                var source_gains = try std.ArrayList(exporter.AudioSourceGain).initCapacity(self.allocator, 0);
                defer {
                    for (source_gains.items) |source_gain| {
                        self.allocator.free(source_gain.id);
                    }
                    source_gains.deinit(self.allocator);
                }

                const fps = blk: {
                    self.ui_mutex.lock();
                    defer self.ui_mutex.unlock();

                    for (self.state.audio.devices.items) |device| {
                        if (!device.selected) continue;
                        const id_copy = try self.allocator.dupe(u8, device.id);
                        errdefer self.allocator.free(id_copy);
                        try source_gains.append(self.allocator, .{
                            .id = id_copy,
                            .gain = device.gain,
                        });
                    }

                    break :blk self.state.fps;
                };

                try exporter.exportReplayBuffers(
                    self.allocator,
                    size.width,
                    size.height,
                    fps,
                    video_replay_buffer.?,
                    audio_replay_buffer.?,
                    SAMPLE_RATE,
                    CHANNELS,
                    source_gains.items,
                );
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
            },
            .show_demo => {
                self.ui_mutex.lock();
                defer self.ui_mutex.unlock();
                self.state.show_demo = !self.state.show_demo;
            },
            .exit => {
                try self.stopRecord();
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

    // TODO: Start here. Segfault here. Need to close this thread handler before state_actor is destroyed,
    // because the audio source closes the channel and destroys it immediately after.
    fn startAudioRecordThreadHandler(self: *Self) !void {
        // Initialize the audio replay buffer. It should already be null.
        {
            const audio_locked = self.audio_replay_buffer.lock();
            defer audio_locked.unlock();
            const ptr = audio_locked.unwrapPtr();
            // TODO: Got an assert here - figure out why this happened. It happened when
            // a window was recording, then stopped, then a new window was selected. This
            // happened when it was running for around 10 minutes.
            assert(ptr.* == null);
            ptr.* = try AudioReplayBuffer.init(self.allocator, self.state.replay_seconds);
        }

        while (true) {
            const data = self.audio_capture.receiveData() catch |err| {
                if (err == ChanError.Closed) {
                    log.debug("[startAudioRecordThreadHandler] chan closed", .{});
                    break;
                }
                log.err("[startAudioRecordThreadHandler] data_chan error: {}", .{err});
                return err;
            };
            log.debug("[startAudioRecordThreadHandler] got audio data: {s}", .{data.id});
            const audio_locked = self.audio_replay_buffer.lock();
            defer audio_locked.unlock();
            if (audio_locked.unwrap()) |buffer| {
                buffer.addData(data) catch |err| {
                    audio_locked.unlock();
                    data.deinit();
                    return err;
                };
            } else {
                data.deinit();
            }
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
            const video_locked = self.video_replay_buffer.lock();
            defer video_locked.unlock();
            const video_replay_buffer = video_locked.unwrapPtr();
            video_replay_buffer.* = try VideoReplayBuffer.init(
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
                    .timestamp_ns = vulkan_image_buffer.value.*.timestamp_ns,
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
            const video_locked = self.video_replay_buffer.lock();
            defer video_locked.unlock();
            const video_replay_buffer = video_locked.unwrap();
            try self.vulkan.video_encoder.?.finishEncode(
                encode_result,
                video_replay_buffer.?,
                vulkan_image_buffer.value.*.timestamp_ns,
            );
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            self.state.replay_buffer.size = video_replay_buffer.?.size;
            self.state.replay_buffer.seconds = video_replay_buffer.?.getSeconds();
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

        var video_locked = self.video_replay_buffer.lock();
        defer video_locked.unlock();
        const video_replay_buffer = video_locked.unwrap();
        if (video_replay_buffer) |vrb| {
            vrb.deinit();
            video_locked.set(null);
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
};
