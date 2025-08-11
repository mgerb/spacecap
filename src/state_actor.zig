const std = @import("std");

const vk = @import("vulkan");

const Util = @import("./util.zig");
const Capture = @import("./capture/capture.zig").Capture;
const CaptureError = @import("./capture/capture.zig").CaptureError;
const BufferedChan = @import("./channel.zig").BufferedChan;
const ChanError = @import("./channel.zig").ChanError;
const Chan = @import("./channel.zig").Chan;
const State = @import("./state.zig");
const Vulkan = @import("./vulkan/vulkan.zig").Vulkan;
const ReplayBuffer = @import("./vulkan/replay_buffer.zig").ReplayBuffer;
const ffmpeg = @import("./ffmpeg.zig");
const CaptureSourceType = @import("./capture/capture.zig").CaptureSourceType;

pub const Actions = union(enum) {
    start_record,
    stop_record,
    select_video_source: CaptureSourceType,
    save_replay,
    show_demo,
    exit,
};

const ActionChan = BufferedChan(Actions, 100);

/// The main application state based on the actor model.
pub const StateActor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    vulkan: *Vulkan,
    capture: *Capture,
    replay_buffer: ?*ReplayBuffer = null,
    replay_buffer_mutex: std.Thread.Mutex = std.Thread.Mutex{},
    action_chan: ActionChan,
    thread_pool: std.Thread.Pool = undefined,
    /// WARNING: This locks the UI thread. This should only be locked
    /// when making updates to the UI state.
    mutex: std.Thread.Mutex = std.Thread.Mutex{},
    state: State,
    record_thread: ?std.Thread = null,

    /// Caller owns the memory. Be sure to deinit.
    pub fn init(allocator: std.mem.Allocator, capture: *Capture, vulkan: *Vulkan) !*Self {
        const self = try allocator.create(Self);

        self.* = Self{
            .allocator = allocator,
            .capture = capture,
            .vulkan = vulkan,
            .action_chan = ActionChan.init(allocator),
            .state = .{},
        };

        try self.thread_pool.init(.{ .allocator = allocator, .n_jobs = 10 });

        return self;
    }

    /// Does not return an error because this should always run.
    /// Handle errors internally.
    /// TODO: add errors to the state and present on UI
    pub fn run(self: *Self) void {
        while (true) {
            const action = self.action_chan.recv() catch |err| {
                if (err == ChanError.Closed) {
                    break;
                } else {
                    std.debug.print("actor loop terminating: {}\n", .{err});
                    break;
                }
            };

            if (action == .exit) {
                self.handleAction(action) catch |err| {
                    std.log.err("exit err: {}\n", .{err});
                };
                break;
            }

            const ActionThread = struct {
                fn run(_self: *Self, _action: Actions) void {
                    _self.handleAction(_action) catch |err| {
                        std.log.err("handleAction error: {}\n", .{err});
                    };
                }
            };

            self.thread_pool.spawn(ActionThread.run, .{ self, action }) catch |err| {
                std.log.err("thread_pool spawn error: {}\n", .{err});
            };
        }
    }

    fn handleAction(self: *Self, action: Actions) !void {
        switch (action) {
            .start_record => {
                std.debug.print("[action] start_record\n", .{});
                try self.startRecord();
            },
            .stop_record => {
                // TODO: clear the replay buffer
                std.debug.print("[action] stop_record\n", .{});
                try self.stopRecord();
            },
            .save_replay => {
                std.debug.print("[action] save_replay\n", .{});

                if (self.replay_buffer) |replay_buffer| {
                    self.replay_buffer_mutex.lock();
                    self.replay_buffer = try ReplayBuffer.init(
                        self.allocator,
                        self.state.replay_seconds,
                        self.vulkan.encoder.?.bit_stream_header.items,
                    );
                    self.replay_buffer_mutex.unlock();

                    self.mutex.lock();
                    const size = self.capture.size().?;
                    const fps = self.state.fps;
                    self.mutex.unlock();

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
                std.debug.print("[action] select_video_source\n", .{});
                if (self.state.recording) {
                    try self.stopRecord();
                }

                self.capture.selectSource(source_type) catch |err| {
                    if (err != CaptureError.source_picker_cancelled) {
                        std.log.err("selectSource error: {}\n", .{err});
                        return err;
                    } else {
                        std.debug.print("source_picker_cancelled\n", .{});
                    }
                    return;
                };

                self.mutex.lock();
                defer self.mutex.unlock();
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
                self.mutex.lock();
                defer self.mutex.unlock();
                self.state.show_demo = !self.state.show_demo;
            },
            .exit => {
                try self.stopRecord();
            },
        }
    }

    /// This is the main capture loop.
    fn startRecordThreadHandler(self: *Self) !void {
        self.mutex.lock();
        const fps = self.state.fps;
        const bit_rate = self.state.bit_rate;
        // Initialize the video encoder here. It will be destroyed
        // when the record thread terminates.
        try self.vulkan.initVideoEncoder(
            self.capture.size().?.width,
            self.capture.size().?.height,
            fps,
            bit_rate,
        );
        defer self.vulkan.destroyVideoEncoder();

        // Initialize the replay buffer. This replay buffer
        // will create destroyed/recreated each time a replay is saved.
        self.replay_buffer_mutex.lock();
        self.replay_buffer = try ReplayBuffer.init(
            self.allocator,
            self.state.replay_seconds,
            self.vulkan.encoder.?.bit_stream_header.items,
        );
        self.replay_buffer_mutex.unlock();
        self.mutex.unlock();

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
                // TODO: this makes 60fps feel choppy. I wonder if we need to
                // not limit anything here and just modify FPS when outputting with
                // ffmpeg.
                std.Thread.sleep(@intCast(next_projected_frame_start_time - now));
            }

            previous_frame_start_time = std.time.nanoTimestamp();

            self.capture.nextFrame() catch |err| {
                if (err == ChanError.Closed) {
                    std.debug.print("self.capture.nextFrame: chan closed, exiting record thread\n", .{});
                    break;
                }
                return err;
            };
            const images = try self.capture.waitForFrame();

            var image_slc = [_]vk.Image{images.image};
            var image_view_slc = [_]vk.ImageView{images.image_view};
            try self.vulkan.encoder.?.prepareEncode(.{
                .image = &image_slc,
                .image_view = &image_view_slc,
                .external_wait_semaphore = self.capture.externalWaitSemaphore(),
            });

            const encode_result = try self.vulkan.encoder.?.encode(0);
            self.replay_buffer_mutex.lock();
            defer self.replay_buffer_mutex.unlock();
            try self.vulkan.encoder.?.finishEncode(encode_result, self.replay_buffer.?);
            self.mutex.lock();
            defer self.mutex.unlock();
            self.state.replay_buffer_state.size = self.replay_buffer.?.size;
            self.state.replay_buffer_state.seconds = self.replay_buffer.?.getSeconds();
        }
    }

    fn stopRecord(self: *Self) !void {
        // Force the record loop to exit by closing the next frame chan.
        try self.capture.closeNextFrameChan();

        // Wait for the thread loop to complete
        if (self.record_thread) |record_thread| {
            defer self.record_thread = null;
            record_thread.join();
        }

        try self.capture.stop();

        if (self.replay_buffer) |replay_buffer| {
            replay_buffer.deinit();
            self.replay_buffer = null;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        self.state.recording = false;
        self.state.has_source = false;
    }

    fn startRecord(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state.has_source and !self.state.recording) {
            self.state.recording = true;
            self.record_thread = try std.Thread.spawn(.{}, startRecordThreadHandler, .{self});
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
