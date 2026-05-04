const std = @import("std");
const assert = std.debug.assert;

const vk = @import("vulkan");

const Util = @import("../util.zig");
const FilePicker = @import("../file_picker/file_picker.zig").FilePicker;
const VideoCapture = @import("../capture/video/video_capture.zig").VideoCapture;
const VideoCaptureError = @import("../capture/video/video_capture.zig").VideoCaptureError;
const VideoCaptureSelection = @import("../capture/video/video_capture.zig").VideoCaptureSelection;
const VideoCaptureSourceType = @import("../capture/video/video_capture.zig").VideoCaptureSourceType;
const AudioCapture = @import("../capture/audio/audio_capture.zig").AudioCapture;
const GlobalShortcuts = @import("../global_shortcuts/global_shortcuts.zig").GlobalShortcuts;
const BufferedChan = @import("../channel.zig").BufferedChan;
const ChanError = @import("../channel.zig").ChanError;
const Mutex = @import("../mutex.zig").Mutex;
const State = @import("./state.zig");
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const VideoReplayBuffer = @import("../video/video_replay_buffer.zig").VideoReplayBuffer;
const Muxer = @import("../video/muxer.zig").Muxer;
const exporter = @import("../exporter.zig");
const AudioActions = @import("./audio_state.zig").AudioActions;
const String = @import("../string.zig").String;
const VideoActions = @import("./video_state.zig").VideoActions;
const Store = @import("./store.zig").Store;

const log = std.log.scoped(.actor);

pub const Actions = union(enum) {
    start_record,
    stop_record,
    start_disk_recording,
    stop_disk_recording,
    select_video_source: VideoCaptureSourceType,
    /// Restore the capture session on startup.
    restore_capture_session,
    save_replay,
    exit,
    open_global_shortcuts,
    audio: AudioActions,
    video: VideoActions,
};

const ActionChan = BufferedChan(Actions, 100);

/// The main application state based on the actor model.
pub const Actor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    vulkan: *Vulkan,
    // TODO: Create video_state and move video logic.
    video_capture: *VideoCapture,
    file_picker: *FilePicker,
    global_shortcuts: *GlobalShortcuts,
    video_replay_buffer: Mutex(?*VideoReplayBuffer) = .init(null),
    recording_muxer: Mutex(?*Muxer) = .init(null),
    action_chan: ActionChan,
    thread_pool: std.Thread.Pool = undefined,
    /// WARNING: This locks the UI thread. This should only be locked
    /// when making updates to the UI state.
    ui_mutex: std.Thread.Mutex = .{},
    video_record_mutex: std.Thread.Mutex = .{},
    state: State,
    video_capture_thread: ?std.Thread = null,
    store: *Store,

    /// Caller owns the memory. Be sure to deinit.
    pub fn init(
        allocator: std.mem.Allocator,
        vulkan: *Vulkan,
        video_capture: *VideoCapture,
        file_picker: *FilePicker,
        audio_capture: *AudioCapture,
        global_shortcuts: *GlobalShortcuts,
        store: *Store,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = Self{
            .allocator = allocator,
            .vulkan = vulkan,
            .video_capture = video_capture,
            .file_picker = file_picker,
            .global_shortcuts = global_shortcuts,
            .action_chan = try ActionChan.init(allocator),
            // TODO: The state is getting a bit unwiedly and coupled.
            // Need to spend some more time refactoring.
            .state = try .init(
                allocator,
                vulkan.video_encode_queue != null,
                audio_capture,
            ),
            .store = store,
        };
        errdefer self.state.deinit();

        try self.thread_pool.init(.{ .allocator = allocator, .n_jobs = 10 });

        try self.capture_startup();

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.thread_pool.deinit();

        const video_locked = self.video_replay_buffer.lock();
        defer video_locked.unlock();
        if (video_locked.unwrap()) |video_replay_buffer| {
            video_replay_buffer.deinit();
        }

        const recording_locked = self.recording_muxer.lock();
        defer recording_locked.unlock();
        if (recording_locked.unwrap()) |recording_muxer| {
            recording_muxer.destroy();
        }

        self.state.deinit();
        self.action_chan.deinit();
        self.allocator.destroy(self);
    }

    /// The capture startup process is not very intuitive and requires an explanation. We
    /// aren't dispatching actions here because we rely on execution order (dispatched
    /// actions are handled in parallel).
    ///
    /// This is the flow:
    ///
    /// - Thread 1
    ///   - Start audio capture thread.
    ///   - Get available audio devices. This can be slow and that's why we run it in parallel.
    /// - Thread 2
    ///   - Restore the capture session. This must not be blocked by getting audio devices,
    ///     otherwise there will be a delay when the video shows up on the UI. Functionally
    ///     it's fine, but it feels bad.
    /// - Thread 3
    ///   - Wait for all threads 1 and 2 to complete, then start recording (if setting enables it).
    ///   - We don't wait for this thread, because it is important that this function does not block,
    ///     otherwise it blocked the UI from starting.
    fn capture_startup(self: *Self) !void {
        const thread_1 = try std.Thread.spawn(.{}, struct {
            fn run(_self: *Self) void {
                _self.handle_action(.{ .audio = .start_capture_thread }) catch |err| {
                    log.err("[capture_startup] audio.start_capture_thread error: {}\n", .{err});
                };
                _self.handle_action(.{ .audio = .get_available_audio_devices }) catch |err| {
                    log.err("[capture_startup] audio.get_available_audio_devices error: {}\n", .{err});
                };
            }
        }.run, .{self});
        errdefer thread_1.join();

        const thread_2 = try std.Thread.spawn(.{}, struct {
            fn run(_self: *Self) void {
                const restore_capture_source_on_startup = blk: {
                    const state_locked = _self.store.state.lock();
                    defer state_locked.unlock();
                    const state = state_locked.unwrap_ptr();
                    break :blk state.user_settings.user_settings.restore_capture_source_on_startup;
                };
                if (restore_capture_source_on_startup) {
                    _self.handle_action(.restore_capture_session) catch |err| {
                        log.err("[capture_startup] restore_capture_session error: {}\n", .{err});
                    };
                }
            }
        }.run, .{self});
        errdefer thread_2.join();

        // thread_3 - We can use the thread pool, because we don't have to wait for completion.
        try self.thread_pool.spawn(struct {
            fn run(_self: *Self, t1: std.Thread, t2: std.Thread) void {
                t1.join();
                t2.join();
                const should_handle_action: bool = blk: {
                    const state_locked = _self.store.state.lock();
                    defer state_locked.unlock();
                    const state = state_locked.unwrap_ptr();
                    const settings = state.user_settings.user_settings;
                    break :blk settings.restore_capture_source_on_startup and settings.start_replay_buffer_on_startup;
                };
                if (should_handle_action) {
                    _self.handle_action(.start_record) catch |err| {
                        log.err("[capture_startup] start_record error: {}", .{err});
                    };
                }
            }
        }.run, .{ self, thread_1, thread_2 });
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
                self.handle_action(action) catch |err| {
                    log.err("exit err: {}\n", .{err});
                };
                break;
            }

            // TODO: This should probably be changed to run synchronously. If any
            // actions require long running tasks (e.g. IO) then they should
            // handle threads themselves. If we handle every action in a thread,
            // then we could potentially run into out of order issues.
            //
            // Followup thought on this: maybe we just handle actions in the
            // thread pool by default, but allow an additional field on an action
            // to run an action synchronously. It may be necessary to handle
            // some actions synchronously in the future.
            const ActionThread = struct {
                fn run(_self: *Self, _action: Actions) void {
                    _self.handle_action(_action) catch |err| {
                        log.err("handleAction error: {}\n", .{err});
                    };
                }
            };

            self.thread_pool.spawn(ActionThread.run, .{ self, action }) catch |err| {
                log.err("thread_pool spawn error: {}\n", .{err});
            };
        }
    }

    fn handle_action(self: *Self, action: Actions) !void {
        try self.state.audio.handle_action(self, action);
        try self.state.video.handle_action(self, action);
        switch (action) {
            .start_record => {
                try self.start_record();
            },
            .stop_record => {
                try self.stop_record();
            },
            .start_disk_recording => {
                try self.start_disk_recording();
            },
            .stop_disk_recording => {
                try self.stop_disk_recording();
            },
            .save_replay => {
                var fps: u32 = 0;
                var replay_seconds: u32 = 0;
                var video_output_directory: ?String = null;
                defer {
                    if (video_output_directory) |*_video_output_directory| _video_output_directory.deinit();
                }
                {
                    self.ui_mutex.lock();
                    defer self.ui_mutex.unlock();
                    if (!self.state.is_recording_video) {
                        log.debug("[handle_action] save_replay - not recording, skipping capture", .{});
                        return;
                    }
                }

                {
                    const state_locked = self.store.state.lock();
                    defer state_locked.unlock();
                    const state = state_locked.unwrap_ptr();
                    const settings = state.user_settings.user_settings;
                    fps = settings.capture_fps;
                    replay_seconds = settings.replay_seconds;
                    // video_output_directory should never be null at this point. If so, there is
                    // something seriously wrong.
                    assert(settings.video_output_directory != null);
                    video_output_directory = try settings.video_output_directory.?.clone(self.allocator);
                }

                // We should always have a size if the state is recording.
                assert(self.video_capture.size() != null);
                const size = self.video_capture.size().?;

                const audio_replay_buffer = (try self.state.audio.take_and_swap_replay_buffer(
                    self.allocator,
                    replay_seconds,
                ));
                defer if (audio_replay_buffer) |_audio_replay_buffer| _audio_replay_buffer.deinit();

                // TODO: create swapReplayBuffer method when this is moved to video state.
                var video_replay_buffer: ?*VideoReplayBuffer = null;
                {
                    self.video_record_mutex.lock();
                    defer self.video_record_mutex.unlock();

                    var video_replay_buffer_locked = self.video_replay_buffer.lock();
                    defer video_replay_buffer_locked.unlock();
                    video_replay_buffer = video_replay_buffer_locked.unwrap();

                    // video_replay_buffer should never be null here. If the state is recording,
                    // it will always be valid.
                    assert(video_replay_buffer != null);

                    // The encoder should never be null if we have a video replay buffer.
                    assert(self.vulkan.video_encoder != null);
                    const video_encoder = self.vulkan.video_encoder.?;

                    video_replay_buffer_locked.set(try .init(
                        self.allocator,
                        replay_seconds,
                        video_encoder.bit_stream_header.items,
                    ));
                }
                defer if (video_replay_buffer) |_video_replay_buffer| _video_replay_buffer.deinit();

                try exporter.export_replay_buffers(
                    self.allocator,
                    size.width,
                    size.height,
                    fps,
                    video_replay_buffer.?,
                    audio_replay_buffer,
                    video_output_directory.?.bytes,
                );
            },
            .select_video_source => |source_type| {
                _ = try self.select_video_source(.{ .source_type = source_type });
            },
            .restore_capture_session => {
                if (!try self.video_capture.should_restore_capture_session()) {
                    return;
                }
                log.debug("Restoring capture session.", .{});
                _ = try self.select_video_source(.restore_session);
            },
            .exit => {
                try self.stop_capture();
            },
            .open_global_shortcuts => {
                try self.global_shortcuts.open();
            },
            // TODO:
            // .user_settings => |user_settings_action| {
            //     _ = user_settings_action;
            //     // switch (user_settings_action) {
            //     //     .set_replay_seconds => |replay_seconds| {
            //     //         self.video_record_mutex.lock();
            //     //         defer self.video_record_mutex.unlock();
            //     //
            //     //         var video_replay_buffer_locked = self.video_replay_buffer.lock();
            //     //         defer video_replay_buffer_locked.unlock();
            //     //         if (video_replay_buffer_locked.unwrap()) |video_replay_buffer| {
            //     //             video_replay_buffer.set_replay_seconds(replay_seconds);
            //     //         }
            //     //     },
            //     //     else => {},
            //     // }
            // },
            else => {},
        }
    }

    /// Returns true/false if a video source was successfully selected.
    fn select_video_source(self: *Self, selection: VideoCaptureSelection) !bool {
        try self.stop_capture();

        const fps = blk: {
            const state_locked = self.store.state.lock();
            defer state_locked.unlock();
            const state = state_locked.unwrap_ptr();
            const settings = state.user_settings.user_settings;
            break :blk settings.capture_fps;
        };

        self.video_capture.select_source(selection, fps) catch |err| {
            if (err != VideoCaptureError.SourcePickerCancelled) {
                log.err("selectSource error: {}\n", .{err});
                return err;
            } else {
                log.info("source_picker_cancelled\n", .{});
            }
            return false;
        };

        try self.start_capture();
        return true;
    }

    pub fn global_shortcuts_handler(context: *anyopaque, shortcut: GlobalShortcuts.Shortcut) void {
        const self: *Self = @ptrCast(@alignCast(context));
        switch (shortcut) {
            .save_replay => {
                self.dispatch(.save_replay) catch unreachable;
            },
        }
    }

    /// TODO: move most of this to capture?
    /// This is the main capture loop.
    fn video_capture_thread_handler(self: *Self) !void {
        var previous_frame_start_time: i128 = 0;

        while (true) {
            const fps = blk: {
                const state_locked = self.store.state.lock();
                defer state_locked.unlock();
                const state = state_locked.unwrap_ptr();
                const settings = state.user_settings.user_settings;
                break :blk settings.capture_fps;
            };

            // Here we wait until the next projected frame time. This will happen if we are
            // capturing/encoding frames too quickly.
            const ns_per_frame = (1.0 / @as(f64, @floatFromInt(fps))) * std.time.ns_per_s;
            const now = std.time.nanoTimestamp();
            const next_projected_frame_start_time = previous_frame_start_time + @as(u64, @intFromFloat(ns_per_frame));

            if (previous_frame_start_time > 0 and next_projected_frame_start_time > now) {
                // TODO: add to state
                Util.print_elapsed(previous_frame_start_time, "previous_frame_start_time");
                std.Thread.sleep(@intCast(next_projected_frame_start_time - now));
            }

            previous_frame_start_time = std.time.nanoTimestamp();

            self.video_capture.next_frame() catch |err| {
                if (err == ChanError.Closed) {
                    log.info("self.capture.nextFrame: chan closed, exiting record thread\n", .{});
                    break;
                }
                return err;
            };

            // This thing is ref counted so release when we are done with it here.
            const vulkan_image_buffer = self.video_capture.wait_for_frame() catch |err| {
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

            const should_encode = blk: {
                self.ui_mutex.lock();
                defer self.ui_mutex.unlock();
                break :blk self.state.is_recording_video or self.state.is_recording_to_disk;
            };

            const copy_data = blk: {
                const capture_preview_ring_buffer_locked = self.vulkan.capture_preview_ring_buffer.lock();
                defer capture_preview_ring_buffer_locked.unlock();
                const _copy_data = try capture_preview_ring_buffer_locked.unwrap().?.copy_image_to_ring_buffer(
                    .{
                        .src_image = image_slc[0],
                        .src_width = vulkan_image_buffer.value.*.width,
                        .src_height = vulkan_image_buffer.value.*.height,
                        .wait_semaphore = null,
                        // Only signal this semaphore when encode will wait on it.
                        .use_signal_semaphore = should_encode,
                        .timestamp_ns = vulkan_image_buffer.value.*.timestamp_ns,
                    },
                );
                break :blk _copy_data;
            };

            if (!should_encode) {
                // In capture-only mode no downstream work waits on the preview copy.
                // Wait here so the capture-ring source image is not recycled while still in flight.
                if (copy_data.fence) |fence| {
                    _ = self.vulkan.device.waitForFences(1, @ptrCast(&fence), .true, std.math.maxInt(u64)) catch |err| {
                        log.err("[video_capture_thread_handler] preview copy wait error: {}", .{err});
                    };
                }
                continue;
            }

            self.video_record_mutex.lock();
            defer self.video_record_mutex.unlock();

            const video_encoder = self.vulkan.video_encoder orelse continue;
            const video_locked = self.video_replay_buffer.lock();
            defer video_locked.unlock();
            const video_replay_buffer = video_locked.unwrap();
            const record_to_disk = self.is_recording_to_disk();
            if (video_replay_buffer == null and !record_to_disk) continue;

            try video_encoder.prepare_encode(.{
                .image = &image_slc,
                .image_view = &image_view_slc,
                .input_size = .{
                    .width = vulkan_image_buffer.value.*.width,
                    .height = vulkan_image_buffer.value.*.height,
                },
                .external_wait_semaphore = copy_data.semaphore,
            });

            const encode_result = try video_encoder.encode(0);
            const encoded_packet = try video_encoder.finish_encode(
                encode_result,
                video_replay_buffer,
                vulkan_image_buffer.value.*.timestamp_ns,
            );
            if (record_to_disk) {
                try self.write_recording_video_packet(
                    encoded_packet,
                    vulkan_image_buffer.value.*.timestamp_ns,
                    encode_result.idr,
                );
            }
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            if (video_replay_buffer) |_video_replay_buffer| {
                self.state.replay_buffer.video_size = _video_replay_buffer.size;
                self.state.replay_buffer.seconds = _video_replay_buffer.get_seconds();
            }
        }
    }

    fn start_capture(self: *Self) !void {
        const size = self.video_capture.size() orelse {
            return error.VideoCaptureSizeNotFound;
        };

        try self.vulkan.init_capture_preview_ring_buffer(size.width, size.height);
        errdefer self.vulkan.destroy_capture_preview_ring_buffer();

        self.video_capture_thread = try std.Thread.spawn(.{}, video_capture_thread_handler, .{self});

        self.ui_mutex.lock();
        defer self.ui_mutex.unlock();
        assert(self.state.is_capturing_video == false);
        assert(self.state.is_recording_video == false);
        self.state.is_capturing_video = true;
    }

    fn stop_capture(self: *Self) !void {
        try self.stop_disk_recording();
        try self.stop_record();

        {
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            self.state.is_capturing_video = false;
        }

        // Force the record loop to exit by closing all capture channels.
        self.video_capture.close_all_channels();

        // Wait for the video record thread loop to complete.
        if (self.video_capture_thread) |video_capture_thread| {
            video_capture_thread.join();
            self.video_capture_thread = null;
        }

        self.vulkan.destroy_capture_preview_ring_buffer();

        try self.video_capture.stop();
    }

    fn start_record(self: *Self) !void {
        self.video_record_mutex.lock();
        defer self.video_record_mutex.unlock();

        var fps: u32 = 0;
        var capture_bit_rate: u64 = 0;
        var replay_seconds: u32 = 0;
        {
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            if (!self.state.is_capturing_video or self.state.is_recording_video) {
                return;
            }
        }

        {
            const state_locked = self.store.state.lock();
            defer state_locked.unlock();
            const state = state_locked.unwrap_ptr();
            const settings = state.user_settings.user_settings;
            fps = settings.capture_fps;
            capture_bit_rate = settings.capture_bit_rate;
            replay_seconds = settings.replay_seconds;
        }

        const size = self.video_capture.size() orelse {
            return error.VideoCaptureSizeNotFound;
        };

        const initialized_encoder = self.vulkan.video_encoder == null;
        if (initialized_encoder) {
            try self.vulkan.init_video_encoder(
                size.width,
                size.height,
                fps,
                capture_bit_rate,
            );
            errdefer self.vulkan.destroy_video_encoder();
        }

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
        self.state.is_recording_video = true;
    }

    fn stop_record(self: *Self) !void {
        self.video_record_mutex.lock();
        defer self.video_record_mutex.unlock();

        {
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            self.state.is_recording_video = false;
            self.state.replay_buffer = .{};
        }

        if (!self.is_recording_to_disk()) {
            self.vulkan.destroy_video_encoder();
        }

        var video_locked = self.video_replay_buffer.lock();
        defer video_locked.unlock();
        const video_replay_buffer = video_locked.unwrap();
        if (video_replay_buffer) |vrb| {
            vrb.deinit();
            video_locked.set(null);
        }
    }

    fn start_disk_recording(self: *Self) !void {
        self.video_record_mutex.lock();
        defer self.video_record_mutex.unlock();

        var fps: u32 = 0;
        var capture_bit_rate: u64 = 0;
        var video_output_directory: ?String = null;
        defer if (video_output_directory) |*_video_output_directory| _video_output_directory.deinit();

        {
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            if (!self.state.is_capturing_video or self.state.is_recording_to_disk) {
                return;
            }
        }

        {
            const state_locked = self.store.state.lock();
            defer state_locked.unlock();
            const state = state_locked.unwrap_ptr();
            const settings = state.user_settings.user_settings;
            fps = settings.capture_fps;
            capture_bit_rate = settings.capture_bit_rate;
            assert(settings.video_output_directory != null);
            video_output_directory = try settings.video_output_directory.?.clone(self.allocator);
        }

        const size = self.video_capture.size() orelse {
            return error.VideoCaptureSizeNotFound;
        };

        const initialized_encoder = self.vulkan.video_encoder == null;
        if (initialized_encoder) {
            try self.vulkan.init_video_encoder(
                size.width,
                size.height,
                fps,
                capture_bit_rate,
            );
            errdefer self.vulkan.destroy_video_encoder();
        }

        const audio_codec_context = try self.state.audio.start_disk_recording();
        errdefer self.state.audio.stop_disk_recording(self) catch {};

        const muxer = blk: {
            const _muxer = try self.allocator.create(Muxer);
            errdefer self.allocator.destroy(_muxer);
            _muxer.* = try Muxer.init(
                self.allocator,
                "recording",
                self.vulkan.video_encoder.?.bit_stream_header.items,
                audio_codec_context,
                size.width,
                size.height,
                fps,
                video_output_directory.?.bytes,
            );
            break :blk _muxer;
        };
        errdefer muxer.destroy();

        {
            var locked = self.recording_muxer.lock();
            defer locked.unlock();
            if (locked.unwrap()) |old_muxer| {
                old_muxer.destroy();
            }
            locked.set(muxer);
        }

        self.ui_mutex.lock();
        defer self.ui_mutex.unlock();
        self.state.is_recording_to_disk = true;
    }

    fn stop_disk_recording(self: *Self) !void {
        {
            self.ui_mutex.lock();
            defer self.ui_mutex.unlock();
            if (!self.state.is_recording_to_disk) {
                return;
            }
            self.state.is_recording_to_disk = false;
        }

        self.video_record_mutex.lock();
        defer self.video_record_mutex.unlock();
        defer if (!self.is_replay_buffer_active()) self.vulkan.destroy_video_encoder();

        try self.state.audio.stop_disk_recording(self);

        var muxer: ?*Muxer = null;
        {
            var locked = self.recording_muxer.lock();
            defer locked.unlock();
            muxer = locked.unwrap();
            locked.set(null);
        }

        if (muxer) |_muxer| {
            defer _muxer.destroy();
            try _muxer.finish();
        }
    }

    pub fn is_recording_to_disk(self: *Self) bool {
        self.ui_mutex.lock();
        defer self.ui_mutex.unlock();
        return self.state.is_recording_to_disk;
    }

    fn is_replay_buffer_active(self: *Self) bool {
        self.ui_mutex.lock();
        defer self.ui_mutex.unlock();
        return self.state.is_recording_video;
    }

    fn write_recording_video_packet(self: *Self, data: []const u8, timestamp_ns: i128, is_idr: bool) !void {
        var locked = self.recording_muxer.lock();
        defer locked.unlock();
        if (locked.unwrap()) |muxer| {
            try muxer.write_video_packet(data, timestamp_ns, is_idr);
        }
    }

    /// Dispatch an action to the actor. This is thread safe.
    ///
    /// WARN: The actor uses a buffered channel,
    /// and it will block the caller if it fills up.
    /// Be careful when using this from the UI thread, although
    /// if the buffer fills up then something is seriously wrong.
    pub fn dispatch(self: *Self, action: Actions) !void {
        log.debug("[dispatch] dispatching action: {}", .{action});
        try self.action_chan.send(action);
    }
};
