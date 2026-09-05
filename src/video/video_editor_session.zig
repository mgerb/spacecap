const std = @import("std");
const c = @import("ffmpeg_c");
const imguiz = @import("imguiz").imguiz;

const Demuxer = @import("../ffmpeg/demuxer.zig").Demuxer;
const VideoDecoder = @import("../ffmpeg/video_decoder.zig").VideoDecoder;
const ffmpeg_util = @import("../ffmpeg/util.zig");
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const VulkanImageBuffer = @import("../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;
const VulkanImageRingBuffer = @import("../vulkan/vulkan_image_ring_buffer.zig").VulkanImageRingBuffer;
const VideoEditorAudio = @import("video_editor_audio.zig").VideoEditorAudio;
const VulkanVideoFrameConverter = @import("vulkan_video_frame_converter.zig").VulkanVideoFrameConverter;
const Arc = @import("../arc.zig").Arc;
const String = @import("../string.zig").String;

pub const VideoEditorSession = struct {
    const Self = @This();
    const log = std.log.scoped(.video_editor_session);

    pub const SessionId = enum(u64) { _ };

    // Incremented whenever a new VideoEditorSession is created.
    var next_session_id: std.atomic.Value(u64) = .init(0);

    /// A decoded video frame prepared for display by the UI.
    pub const DisplayFrame = struct {
        buffer: Arc(VulkanImageBuffer),
        texture: imguiz.ImTextureRef,
        width: u32,
        height: u32,
    };

    id: SessionId,
    allocator: std.mem.Allocator,
    vulkan: *Vulkan,
    file_path: String,
    worker: *Worker,
    ring_buffer: *VulkanImageRingBuffer,
    width: u32,
    height: u32,
    duration_ns: i64,

    pub fn init(allocator: std.mem.Allocator, vulkan: *Vulkan, file_path: []const u8) !Self {
        var owned_file_path = try String.init(allocator, file_path);
        errdefer owned_file_path.deinit();

        var demuxer = try Demuxer.init(allocator, file_path);
        errdefer demuxer.deinit();

        const duration_ns = demuxer.duration_ns() orelse 0;
        const timeline_start_ns = demuxer.start_time_ns();

        const codec_parameters = demuxer.video_codec_parameters() orelse return error.MissingVideoStream;
        if (codec_parameters.*.width <= 0 or codec_parameters.*.height <= 0) return error.InvalidVideoSize;
        const video_width: u32 = @intCast(codec_parameters.*.width);
        const video_height: u32 = @intCast(codec_parameters.*.height);

        var decoder = try VideoDecoder.init(vulkan, codec_parameters);
        errdefer decoder.deinit();

        const ring_buffer = try VulkanImageRingBuffer.init(.{
            .allocator = allocator,
            .io = vulkan.io,
            .vulkan = vulkan,
            .width = video_width,
            .height = video_height,
            .image_layout = .shader_read_only_optimal,
            .dst_stage_mask = .{ .fragment_shader = true },
            .dst_access_mask = .{ .shader_sampled_read = true },
            .usage = .{ .sampled = true, .storage = true },
            .image_component_mapping = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .src_queue_family_index = vulkan.graphics_queue.family,
        });
        errdefer ring_buffer.deinit();

        var converter = try VulkanVideoFrameConverter.init(vulkan, video_width, video_height);
        errdefer converter.deinit();

        var audio = VideoEditorAudio.init(allocator, file_path) catch |err| blk: {
            log.warn("[init] audio playback unavailable: {}", .{err});
            break :blk null;
        };
        errdefer if (audio) |*audio_playback| audio_playback.deinit();

        const worker = try allocator.create(Worker);
        errdefer allocator.destroy(worker);
        worker.* = .init(.{
            .io = vulkan.io,
            .vulkan = vulkan,
            .demuxer = demuxer,
            .decoder = decoder,
            .converter = converter,
            .ring_buffer = ring_buffer,
            .time_base = demuxer.video_time_base() orelse return error.MissingVideoStream,
            .duration_ns = duration_ns,
            .timeline_start_ns = timeline_start_ns,
            .trim_end_ns = .init(if (duration_ns > 0) duration_ns else std.math.maxInt(i64)),
            .audio = audio,
        });
        try worker.start();

        return .{
            .id = @fromBackingInt(next_session_id.fetchAdd(1, .monotonic)),
            .allocator = allocator,
            .vulkan = vulkan,
            .file_path = owned_file_path,
            .worker = worker,
            .ring_buffer = ring_buffer,
            .width = video_width,
            .height = video_height,
            .duration_ns = duration_ns,
        };
    }

    pub fn deinit(self: *Self) void {
        self.worker.deinit();
        self.allocator.destroy(self.worker);

        self.vulkan.wait_for_ui_fences();
        self.ring_buffer.deinit();
        self.file_path.deinit();
    }

    pub fn get_latest_frame(self: *Self) !?DisplayFrame {
        const buffer = self.ring_buffer.get_most_recent_buffer() orelse return null;
        errdefer {
            buffer.as_ptr().in_use.store(false, .release);
            buffer.deinit();
        }

        const texture = try buffer.as_ptr().get_imgui_texture();
        return .{
            .buffer = buffer,
            .texture = texture.im_texture_ref,
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn playback_position_ns(self: *const Self) i64 {
        return self.worker.playback_position_ns.load(.acquire);
    }

    pub fn is_playing(self: *const Self) bool {
        return self.worker.playback_requested.load(.acquire);
    }

    pub fn trim_start_ns(self: *const Self) i64 {
        return self.worker.trim_start_ns.load(.acquire);
    }

    pub fn trim_end_ns(self: *const Self) i64 {
        return self.worker.trim_end_ns.load(.acquire);
    }

    pub fn scrub_to(self: *Self, position_ns: i64) void {
        self.worker.scrub_to(position_ns);
    }

    pub fn set_scrubbing(self: *Self, scrubbing: bool) void {
        self.worker.set_scrubbing(scrubbing);
    }

    pub fn set_playing(self: *Self, playing: bool) void {
        self.worker.set_playing(playing);
    }

    pub fn wake_worker(self: *Self) void {
        self.worker.wake_worker();
    }

    pub fn set_trim_start(self: *Self, position_ns: i64) void {
        self.worker.set_trim_start(position_ns);
    }

    pub fn set_trim_end(self: *Self, position_ns: i64) void {
        self.worker.set_trim_end(position_ns);
    }

    pub fn step_previous_frame(self: *Self) void {
        self.worker.set_step_previous_frame_request();
    }

    pub fn step_next_frame(self: *Self) void {
        self.worker.set_step_next_frame_request();
    }

    /// The worker has a run loop, which doesn't exit, but will wait on a
    /// condition when the player is paused for example. The consumer can
    /// interact with the worker by setting the atomic values, which the worker
    /// will check in its run loop to perform actions.
    const Worker = struct {
        const InitArgs = struct {
            io: std.Io,
            vulkan: *Vulkan,
            demuxer: Demuxer,
            decoder: VideoDecoder,
            converter: VulkanVideoFrameConverter,
            ring_buffer: *VulkanImageRingBuffer,
            time_base: c.AVRational,
            duration_ns: i64,
            timeline_start_ns: i64,
            audio: ?VideoEditorAudio,
            trim_end_ns: std.atomic.Value(i64),
        };
        const PlayResult = enum { ended, interrupted, trim_end };
        const RunResult = enum { inactive, ended, trim_end, failed };

        io: std.Io,
        vulkan: *Vulkan,
        demuxer: Demuxer,
        decoder: VideoDecoder,
        converter: VulkanVideoFrameConverter,
        ring_buffer: *VulkanImageRingBuffer,

        time_base: c.AVRational,
        duration_ns: i64,
        timeline_start_ns: i64,
        audio: ?VideoEditorAudio,

        io_group: std.Io.Group = .init,
        state_mutex: std.Io.Mutex = .init,
        /// Used to wait in the worker loop when idle.
        state_condition: std.Io.Condition = .init,

        // ----------------------------------------------------------------------------
        // These vars are atomic because they are used outside the worker thread.
        //
        // NOTE: These ns timestamps are relative to the timeline_start_ns,
        // whereas frame pts_ns is absolute.
        //
        // ----------------------------------------------------------------------------

        /// The timestamp of the active playing position (relative to timeline_start_ns).
        playback_position_ns: std.atomic.Value(i64) = .init(0),
        /// A > -1 value replaces any older request, so that only the latest is
        /// used when scrubbing rapidly. -1 means no pending seek.
        seek_request_ns: std.atomic.Value(i64) = .init(-1),
        /// Relative to the timeline_start_ns.
        trim_start_ns: std.atomic.Value(i64) = .init(0),
        /// Relative to the timeline_start_ns.
        trim_end_ns: std.atomic.Value(i64),

        stop: std.atomic.Value(bool) = .init(false),
        step_previous_frame_request: std.atomic.Value(bool) = .init(false),
        step_next_frame_request: std.atomic.Value(bool) = .init(false),
        /// Timestamp that stays in sync with the decoder. This can be compared
        /// with the playback_position_ns to see if seeking is required when
        /// scrubbing, or stepping next.
        last_decoded_frame_position_ns: ?i64 = null,
        /// When the user is scrubbing the video.
        scrubbing: std.atomic.Value(bool) = .init(false),
        /// True when the video is playing.
        playback_requested: std.atomic.Value(bool) = .init(false),

        fn init(args: InitArgs) Worker {
            return .{
                .io = args.io,
                .vulkan = args.vulkan,
                .demuxer = args.demuxer,
                .decoder = args.decoder,
                .converter = args.converter,
                .ring_buffer = args.ring_buffer,
                .time_base = args.time_base,
                .duration_ns = args.duration_ns,
                .timeline_start_ns = args.timeline_start_ns,
                .audio = args.audio,
                .trim_end_ns = args.trim_end_ns,
            };
        }

        fn deinit(self: *Worker) void {
            self.state_mutex.lockUncancelable(self.io);
            self.stop.store(true, .release);
            self.state_condition.broadcast(self.io);
            self.state_mutex.unlock(self.io);

            self.io_group.await(self.io) catch |err| {
                log.err("[deinit] failed to await worker task: {}", .{err});
            };
            if (self.audio) |*audio| {
                audio.deinit();
            }
            self.converter.deinit();
            self.decoder.deinit();
            self.demuxer.deinit();
        }

        /// Starts the worker task. Seek to 0 to present the first frame when
        /// paused.
        fn start(self: *Worker) !void {
            self.seek_request_ns.store(0, .release);
            try self.io_group.concurrent(self.io, task_main, .{self});
        }

        /// Sets a seek request.
        fn scrub_to(self: *Worker, position_ns: i64) void {
            self.seek_request_ns.store(
                std.math.clamp(position_ns, 0, self.duration_ns),
                .release,
            );
        }

        /// Scrubbing pauses continuous playback.
        fn set_scrubbing(self: *Worker, scrubbing: bool) void {
            self.scrubbing.store(scrubbing, .release);
        }

        fn set_playing(self: *Worker, playing: bool) void {
            var position_ns = self.playback_position_ns.load(.acquire);

            // Clamp the time between trim start/stop.
            if (playing and
                (position_ns < self.trim_start_ns.load(.acquire) or
                    position_ns >= self.trim_end_ns.load(.acquire)))
            {
                position_ns = self.trim_start_ns.load(.acquire);
                self.playback_position_ns.store(position_ns, .release);
            }
            self.playback_requested.store(playing, .release);
        }

        /// This must be called if any of the atomics have been updated, which
        /// should trigger the player to start.
        fn wake_worker(self: *Worker) void {
            self.state_mutex.lockUncancelable(self.io);
            defer self.state_mutex.unlock(self.io);
            self.state_condition.broadcast(self.io);
        }

        // Set the trim start and then scrub to the same point.
        fn set_trim_start(self: *Worker, position_ns: i64) void {
            const trim_start = std.math.clamp(position_ns, 0, self.trim_end_ns.load(.acquire));
            self.trim_start_ns.store(trim_start, .release);
            self.scrub_to(trim_start);
        }

        // Set the trim end and then scrub to the same point.
        fn set_trim_end(self: *Worker, position_ns: i64) void {
            const trim_end = std.math.clamp(
                position_ns,
                self.trim_start_ns.load(.acquire),
                self.duration_ns,
            );
            self.trim_end_ns.store(trim_end, .release);
            self.scrub_to(trim_end);
        }

        pub fn set_step_previous_frame_request(self: *Worker) void {
            self.playback_requested.store(false, .release);
            self.step_previous_frame_request.store(true, .release);
        }

        pub fn set_step_next_frame_request(self: *Worker) void {
            self.playback_requested.store(false, .release);
            self.step_next_frame_request.store(true, .release);
        }

        /// The concurrent task should process frames while playing or when a
        /// frame has been explicitly requested.
        fn should_run(self: *const Worker) bool {
            return (self.playback_requested.load(.acquire) and
                !self.scrubbing.load(.acquire)) or
                self.seek_request_ns.load(.acquire) >= 0 or
                self.step_previous_frame_request.load(.acquire) or
                self.step_next_frame_request.load(.acquire);
        }

        fn task_main(self: *Worker) void {
            while (true) {
                {
                    self.state_mutex.lockUncancelable(self.io);
                    defer self.state_mutex.unlock(self.io);
                    // Recheck after waking, because condition variables may wake spuriously.
                    while (!self.stop.load(.acquire) and !self.should_run()) {
                        self.state_condition.waitUncancelable(self.io, &self.state_mutex);
                    }
                    if (self.stop.load(.acquire)) {
                        return;
                    }
                }

                const result = self.run() catch |err| blk: {
                    log.err("[task_main] playback failed: {}", .{err});
                    break :blk RunResult.failed;
                };
                // Pause audio here, because when `run` returns, then video stops.
                self.pause_audio();

                {
                    self.state_mutex.lockUncancelable(self.io);
                    defer self.state_mutex.unlock(self.io);

                    switch (result) {
                        .inactive => {},
                        .ended => {
                            self.playback_position_ns.store(self.duration_ns, .release);
                            self.playback_requested.store(false, .release);
                        },
                        .trim_end => {
                            self.playback_position_ns.store(self.trim_end_ns.load(.acquire), .release);
                            self.playback_requested.store(false, .release);
                        },
                        .failed => {
                            self.playback_requested.store(false, .release);
                            self.scrubbing.store(false, .release);
                        },
                    }
                }
            }
        }

        /// This run loop will executed when playing or scrubbing.
        fn run(self: *Worker) !RunResult {
            while (!self.stop.load(.acquire)) {
                const should_play = self.playback_requested.load(.acquire) and
                    !self.scrubbing.load(.acquire);

                if (!should_play) {
                    self.pause_audio();
                }

                // ----------------------------------------------------------------------------
                // Stepping is handled here. When stepping next, we can assume the decoder
                // cursor is at the current position. There are some edge cases where this
                // could potentially not be the case, but let's not worry about it for now.
                // It likely won't be noticeable.
                // ----------------------------------------------------------------------------
                const should_step_to_previous_frame = self.step_previous_frame_request.swap(false, .acq_rel);
                if (should_step_to_previous_frame) {
                    const position_ns = self.playback_position_ns.load(.acquire);
                    const step_previous_position_ps = position_ns - 1;
                    if (step_previous_position_ps < self.trim_start_ns.load(.acquire)) {
                        continue;
                    }
                    // NOTE: The seek_before here is important.
                    try self.seek_to(.{ .position_ns = position_ns, .seek_before = true });
                    // We can just scrub to the current position - 1 because
                    // scrub_to_timestamp will not scrub to any frames after
                    // the timestamp.
                    try self.scrub_to_timestamp(step_previous_position_ps);
                    continue;
                }

                const should_step_to_next_frame = self.step_next_frame_request.swap(false, .acq_rel);
                if (should_step_to_next_frame) {
                    const position_ns = self.playback_position_ns.load(.acquire);
                    // If the decoder is in sync with the current position then we don't have to seek.
                    // This happens when stepping next repeatedly. We could seek every time, but this
                    // will be more performant.
                    const decoder_is_synced = self.last_decoded_frame_position_ns == position_ns;
                    if (!decoder_is_synced) {
                        try self.seek_to(.{ .position_ns = position_ns });
                    }
                    try self.step_to_next_frame();
                    continue;
                }

                const seek_position_ns = self.take_seek_request();

                // We only need to continue if seeking or the video is playing.
                if (seek_position_ns == null and !should_play) {
                    return .inactive;
                }

                const position_ns = seek_position_ns orelse
                    self.playback_position_ns.load(.acquire);

                try self.seek_to(.{ .position_ns = position_ns });

                if (should_play) {
                    switch (try self.play_audio_and_video(position_ns)) {
                        .interrupted => {},
                        .ended => return .ended,
                        .trim_end => return .trim_end,
                    }
                } else {
                    // A paused seek decodes only far enough to show the target.
                    try self.scrub_to_timestamp(position_ns);
                }
            }

            return .inactive;
        }

        fn step_to_next_frame(self: *Worker) !void {
            while (try self.decode_video_frame()) |frame| {
                const pts_ns = try ffmpeg_util.frame_pts_ns(frame, self.time_base);
                const relative_pts_ns = pts_ns - self.timeline_start_ns;
                if (relative_pts_ns >= self.trim_end_ns.load(.acquire)) {
                    break;
                }
                if (relative_pts_ns <= self.playback_position_ns.load(.acquire)) {
                    continue;
                }
                try self.submit_frame_to_ring_buffer(frame, pts_ns);
                break;
            }
        }

        /// Decode from a seek point and present the frame at or before the
        /// requested timestamp.
        fn scrub_to_timestamp(self: *Worker, position_ns: i64) !void {
            const target_pts_ns = self.timeline_start_ns + position_ns;
            var previous_frame: [*c]c.AVFrame = null;
            defer c.av_frame_free(&previous_frame);
            var previous_pts_ns: i64 = 0;

            while (try self.decode_video_frame()) |frame| {
                if (self.stop.load(.acquire) or
                    self.seek_request_ns.load(.acquire) >= 0)
                {
                    return;
                }
                const pts_ns = try ffmpeg_util.frame_pts_ns(frame, self.time_base);

                // If it is equal to the target, then present.
                if (pts_ns == target_pts_ns) {
                    try self.submit_frame_to_ring_buffer(frame, pts_ns);
                    return;
                }

                // If after, then we check for a previous frame, or just
                // present if there was no previous.
                if (pts_ns > target_pts_ns) {
                    if (previous_frame != null) {
                        try self.submit_frame_to_ring_buffer(previous_frame, previous_pts_ns);
                    } else {
                        try self.submit_frame_to_ring_buffer(frame, pts_ns);
                    }
                    return;
                }

                if (previous_frame == null) {
                    // Frame must be cloned because FFmpeg reuses it otherwise.
                    previous_frame = c.av_frame_clone(frame);
                } else {
                    c.av_frame_unref(previous_frame);
                    if (c.av_frame_ref(previous_frame, frame) < 0) {
                        return error.FFmpegError;
                    }
                }
                previous_pts_ns = pts_ns;
            }

            // We get to this point if there are no more frames to decode.
            // This will be the last frame.
            if (previous_frame != null) {
                try self.submit_frame_to_ring_buffer(previous_frame, previous_pts_ns);
            }
        }

        /// Play from a specific position. Decode frames until we get to that
        /// point. The seek current point could be a key frame before the
        /// position_ns. There are periodic checks in here for interruptions
        /// (e.g. scrubbing, pause, etc.), which will for it to return.
        ///
        /// NOTE: This does play the audio, however, it does not directly play
        /// the video. It populates a ring buffer, which is then used to
        /// present frames on the UI.
        fn play_audio_and_video(self: *Worker, position_ns: i64) !PlayResult {
            const target_pts_ns = self.timeline_start_ns + position_ns;

            // Decode until we get to the target position_ns.
            const first_frame = while (try self.decode_video_frame()) |frame| {
                if (self.playback_interrupted()) {
                    return .interrupted;
                }
                if (try ffmpeg_util.frame_pts_ns(frame, self.time_base) >= target_pts_ns) {
                    break frame;
                }
            } else return .ended;

            const first_video_frame_pts_ns = try ffmpeg_util.frame_pts_ns(first_frame, self.time_base);

            // Stop if the frame is after the trim_end position.
            if (first_video_frame_pts_ns - self.timeline_start_ns >= self.trim_end_ns.load(.acquire)) {
                return .trim_end;
            }

            // At this point it should play so we start audio.
            const timeline_origin_ns = self.fill_and_start_audio_if_stopped(first_video_frame_pts_ns) orelse first_video_frame_pts_ns;
            const started_at_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;

            // Wait until the frame is supposed to be presented.
            if (!try self.wait_until(started_at_ns + first_video_frame_pts_ns - timeline_origin_ns)) {
                return .interrupted;
            }

            if (self.playback_interrupted()) {
                return .interrupted;
            }

            try self.submit_frame_to_ring_buffer(first_frame, first_video_frame_pts_ns);

            while (!self.stop.load(.acquire)) {
                if (self.playback_interrupted()) {
                    return .interrupted;
                }

                _ = self.fill_and_start_audio_if_stopped(null);

                const frame = try self.decode_video_frame() orelse break;
                const pts_ns = try ffmpeg_util.frame_pts_ns(frame, self.time_base);

                if (pts_ns - self.timeline_start_ns >= self.trim_end_ns.load(.acquire)) {
                    return .trim_end;
                }

                if (!try self.wait_until(started_at_ns + pts_ns - timeline_origin_ns)) {
                    return .interrupted;
                }

                if (self.playback_interrupted()) {
                    return .interrupted;
                }

                try self.submit_frame_to_ring_buffer(frame, pts_ns);
            }

            if (!try self.finish_audio()) {
                return .interrupted;
            }

            return .ended;
        }

        fn take_seek_request(self: *Worker) ?i64 {
            const requested_position_ns = self.seek_request_ns.swap(-1, .acq_rel);
            return if (requested_position_ns >= 0) requested_position_ns else null;
        }

        fn playback_interrupted(self: *const Worker) bool {
            return self.stop.load(.acquire) or
                !self.playback_requested.load(.acquire) or
                self.scrubbing.load(.acquire) or
                self.seek_request_ns.load(.acquire) >= 0;
        }

        /// Seek to the desired timestamp.
        /// NOTE: The underlying demuxer seeks to the key frame just before the
        /// seek point, because it can't start decoding at arbitrary frames.
        fn seek_to(self: *Worker, args: struct {
            position_ns: i64,
            seek_before: bool = false,
        }) !void {
            const timestamp_ns = self.timeline_start_ns + args.position_ns;
            try self.demuxer.seek_video(.{
                .timestamp_ns = timestamp_ns,
                .seek_before = args.seek_before,
            });
            self.decoder.flush();
            self.last_decoded_frame_position_ns = null;
            if (self.audio) |*audio| {
                try audio.seek(.{
                    .timestamp_ns = timestamp_ns,
                    .seek_before = args.seek_before,
                });
            }
            self.playback_position_ns.store(args.position_ns, .release);
        }

        // Audio errors disable audio for this session while video continues.
        fn pause_audio(self: *Worker) void {
            if (self.audio) |*audio| {
                audio.pause() catch |err| {
                    log.warn("[pause_audio] audio playback disabled: {}", .{err});
                    audio.deinit();
                    self.audio = null;
                };
            }
        }

        /// See doc comments on the inner fill_and_start_if_stopped.
        fn fill_and_start_audio_if_stopped(self: *Worker, first_video_frame_pts_ns: ?i64) ?i64 {
            if (self.audio) |*audio| {
                return audio.fill_and_start_if_stopped(first_video_frame_pts_ns) catch |err| {
                    log.err("[fill_and_start_audio_if_stopped] error: {}", .{err});
                    audio.deinit();
                    self.audio = null;
                    return null;
                };
            }
            return null;
        }

        /// Waits until a frame's presentation time.
        fn wait_until(self: *Worker, target_ns: i128) !bool {
            while (!self.stop.load(.acquire)) {
                if (self.playback_interrupted()) {
                    return false;
                }
                _ = self.fill_and_start_audio_if_stopped(null);
                const now_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
                if (target_ns <= now_ns) {
                    return true;
                }
                const remaining_ns: u64 = @intCast(target_ns - now_ns);
                try std.Io.sleep(
                    self.io,
                    .fromNanoseconds(@min(remaining_ns, 10 * std.time.ns_per_ms)),
                    .awake,
                );
            }
            return true;
        }

        /// After the final video frame, keep feeding audio until its queued data
        /// drains or a consumer interrupts playback.
        fn finish_audio(self: *Worker) !bool {
            while (!self.stop.load(.acquire)) {
                if (self.playback_interrupted()) {
                    return false;
                }
                _ = self.fill_and_start_audio_if_stopped(null);
                const audio = if (self.audio) |*value| value else return true;
                if (audio.finished and try audio.queued_bytes() == 0) {
                    return true;
                }
                try std.Io.sleep(self.io, .fromMilliseconds(10), .awake);
            }
            return true;
        }

        /// Decode until a frame has been filled. Returns null when there are
        /// no frames left.
        fn decode_video_frame(self: *Worker) !?*const c.AVFrame {
            while (true) {
                const frame = self.decoder.decode_frame() catch |err| switch (err) {
                    error.NeedsPacket => {
                        const packet = try self.demuxer.next_video_packet();
                        try self.decoder.send_packet(if (packet) |value| value else null);
                        continue;
                    },
                    else => return err,
                };

                if (frame) |value| {
                    const pts_ns = try ffmpeg_util.frame_pts_ns(value, self.time_base);
                    self.last_decoded_frame_position_ns = pts_ns - self.timeline_start_ns;
                }
                return frame;
            }
        }

        /// Convert the decoded YUV image to RGB and then add it to the ring buffer.
        /// The UI then accesses the ring buffer to display the image.
        fn submit_frame_to_ring_buffer(self: *Worker, frame: *const c.AVFrame, pts_ns: i64) !void {
            var output_ref = self.ring_buffer.get_available_buffer() orelse return;
            defer output_ref.deinit();
            const output = output_ref.as_ptr();
            errdefer output.in_use.store(false, .release);

            try self.converter.convert(frame, output);
            self.ring_buffer.set_most_recent_buffer(output, pts_ns);
            self.playback_position_ns.store(
                std.math.clamp(pts_ns - self.timeline_start_ns, 0, self.duration_ns),
                .release,
            );
        }
    };
};
