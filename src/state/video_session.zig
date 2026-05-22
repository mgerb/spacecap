const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vk = @import("vulkan");
const VideoCapture = @import("../capture/video/video_capture.zig").VideoCapture;
const Mutex = @import("../mutex.zig").Mutex;
const VideoReplayBuffer = @import("../video/video_replay_buffer.zig").VideoReplayBuffer;
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const Util = @import("../util.zig");
const BufferedChan = @import("../channel.zig").BufferedChan;
const ChanError = @import("../channel.zig").ChanError;
const Store = @import(".//store.zig").Store;
const VideoCaptureSelection = @import("../capture/video/video_capture.zig").VideoCaptureSelection;
const VideoCaptureError = @import("../capture/video/video_capture.zig").VideoCaptureError;

const VideoRecordData = struct {
    allocator: Allocator,
    data: []const u8,
    timestamp_ns: i128,
    is_idr: bool,

    /// NOTE: Copies and manages data internally.
    pub fn init(
        allocator: Allocator,
        data: []const u8,
        timestamp_ns: i128,
        is_idr: bool,
    ) !@This() {
        return .{
            .allocator = allocator,
            .data = try allocator.dupe(u8, data),
            .timestamp_ns = timestamp_ns,
            .is_idr = is_idr,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.data);
    }
};

const VideoRecordQueuePayload = union(enum) {
    done,
    data: VideoRecordData,
};

pub const VideoSession = struct {
    const Self = @This();
    const log = std.log.scoped(.video_session);

    allocator: Allocator,
    vulkan: *Vulkan,
    store: *Store,
    video_capture: VideoCapture,
    capture_thread: ?std.Thread = null,
    record_to_disk_thread: ?std.Thread = null,

    // NOTE: This mutex could probably be refactored. It's not
    // very intuitve on where it is supposed to be used. Generally
    // the video encoder and the replay buffer should be locked together.
    // Init/deinit of record_data_queue must also be behind this lock.
    video_record_mutex: std.Thread.Mutex = .{},
    video_replay_buffer: Mutex(?*VideoReplayBuffer) = .init(null),
    // When recording to disk this channel will not be null. There is
    // a separate thread that pulls data off this queue and writes to disk.
    // We do this so that we don't slow the main capture thread by disk IO.
    record_data_queue: ?BufferedChan(VideoRecordQueuePayload, 1_000) = null,

    pub fn init(
        allocator: Allocator,
        vulkan: *Vulkan,
        store: *Store,
        video_capture: VideoCapture,
    ) !Self {
        return .{
            .allocator = allocator,
            .vulkan = vulkan,
            .store = store,
            .video_capture = video_capture,
        };
    }

    pub fn deinit(self: *Self) void {
        self.video_record_mutex.lock();
        defer self.video_record_mutex.unlock();

        if (self.record_data_queue) |*record_data_queue| {
            record_data_queue.send(.done) catch |err| {
                log.err("[deinit] record_data_queue.send error: {}", .{err});
            };
        }

        if (self.record_to_disk_thread) |record_to_disk_thread| {
            record_to_disk_thread.join();
            self.record_to_disk_thread = null;
        }

        // NOTE: Only deinit after the record to disk thread closes.
        if (self.record_data_queue) |*record_data_queue| {
            record_data_queue.deinit();
        }

        const video_replay_buffer_locked = self.video_replay_buffer.lock();
        defer video_replay_buffer_locked.unlock();
        if (video_replay_buffer_locked.unwrap()) |video_replay_buffer| {
            video_replay_buffer.deinit();
        }
    }

    pub fn select_video_source(self: *Self, selection: VideoCaptureSelection, fps: u32) !bool {
        self.video_capture.select_source(selection, fps) catch |err| {
            if (err != VideoCaptureError.SourcePickerCancelled) {
                log.err("selectSource error: {}\n", .{err});
                return err;
            } else {
                log.info("source_picker_cancelled\n", .{});
                return false;
            }
        };
        return true;
    }

    pub fn start_capture(self: *Self) !void {
        const size = self.video_capture.size() orelse {
            return error.VideoCaptureSizeNotFound;
        };

        try self.vulkan.init_capture_preview_ring_buffer(size.width, size.height);
        errdefer self.vulkan.destroy_capture_preview_ring_buffer();

        self.capture_thread = try std.Thread.spawn(.{}, video_capture_thread_handler, .{self});
    }

    pub fn stop_capture(self: *Self) !void {
        self.stop_recording_to_disk();
        try self.stop_replay_buffer();

        // Force the record loop to exit by closing all capture channels.
        self.video_capture.close_all_channels();

        // Wait for the video record thread loop to complete.
        if (self.capture_thread) |capture_thread| {
            capture_thread.join();
            self.capture_thread = null;
        }

        self.vulkan.destroy_capture_preview_ring_buffer();

        try self.video_capture.stop();
    }

    pub fn start_replay_buffer(self: *Self, fps: u32, capture_bit_rate: u64, replay_seconds: u32) !void {
        self.video_record_mutex.lock();
        defer self.video_record_mutex.unlock();

        try self.init_video_encoder(fps, capture_bit_rate);

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
    }

    pub fn stop_replay_buffer(self: *Self) !void {
        self.video_record_mutex.lock();
        defer self.video_record_mutex.unlock();
        var video_replay_buffer_locked = self.video_replay_buffer.lock();
        defer video_replay_buffer_locked.unlock();
        if (video_replay_buffer_locked.unwrap()) |video_replay_buffer| {
            video_replay_buffer.deinit();
            video_replay_buffer_locked.set(null);
        }
        const is_recording_to_disk = blk: {
            const muxer_locked = self.store.capture_store.muxer.lock();
            defer muxer_locked.unlock();
            const muxer_ptr = muxer_locked.unwrap_ptr();
            break :blk muxer_ptr.* != null;
        };

        if (!is_recording_to_disk) {
            self.vulkan.deinit_video_encoder();
        }
    }

    pub fn start_recording_to_disk(self: *Self, fps: u32, capture_bit_rate: u64) !void {
        self.video_record_mutex.lock();
        defer self.video_record_mutex.unlock();
        try self.init_video_encoder(fps, capture_bit_rate);
        if (self.record_data_queue == null) {
            self.record_data_queue = try .init(self.allocator);
        }
        self.record_to_disk_thread = try std.Thread.spawn(.{}, record_to_disk_thread_handler, .{self});
    }

    pub fn stop_recording_to_disk(self: *Self) void {
        self.video_record_mutex.lock();
        defer self.video_record_mutex.unlock();

        // Send the .done payload and wait for the record to disk thread to finish
        // pulling all data out of the queue.
        if (self.record_data_queue) |*record_data_queue| {
            record_data_queue.send(.done) catch |err| {
                log.err("[stop_recording_to_disk] record_data_queue.send error: {}", .{err});
            };
        }

        if (self.record_to_disk_thread) |record_to_disk_thread| {
            record_to_disk_thread.join();
            self.record_to_disk_thread = null;
        }

        // NOTE: We make sure to clean this up after the record to disk thread closes.
        if (self.record_data_queue) |*record_data_queue| {
            record_data_queue.deinit();
            self.record_data_queue = null;
        }

        var video_replay_buffer_locked = self.video_replay_buffer.lock();
        defer video_replay_buffer_locked.unlock();
        if (video_replay_buffer_locked.unwrap() == null) {
            self.vulkan.deinit_video_encoder();
        }
    }

    /// Idempotent. Init video encoder if not already initted.
    fn init_video_encoder(self: *Self, fps: u32, capture_bit_rate: u64) !void {
        const size = self.video_capture.size() orelse {
            return error.VideoCaptureSizeNotFound;
        };
        if (self.vulkan.video_encoder == null) {
            try self.vulkan.init_video_encoder(
                size.width,
                size.height,
                fps,
                capture_bit_rate,
            );
            errdefer self.vulkan.deinit_video_encoder();
        }
    }

    // TODO: Revise error code paths in here.
    fn video_capture_thread_handler(self: *Self) !void {
        var previous_frame_start_time: i128 = 0;

        while (true) {
            const fps = blk: {
                const state_locked = self.store.state.lock();
                defer state_locked.unlock();
                const state = state_locked.unwrap_ptr();
                break :blk state.user_settings.user_settings.capture_fps;
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
                vulkan_image_buffer.as_ptr().in_use.store(false, .release);
                vulkan_image_buffer.deinit();
            }

            var image_slc = [_]vk.Image{vulkan_image_buffer.as_ptr().image};
            var image_view_slc = [_]vk.ImageView{vulkan_image_buffer.as_ptr().image_view};

            const should_encode = blk: {
                const video_replay_buffer_locked = self.video_replay_buffer.lock();
                defer video_replay_buffer_locked.unlock();
                const video_replay_buffer = video_replay_buffer_locked.unwrap();
                const muxer_locked = self.store.capture_store.muxer.lock();
                defer muxer_locked.unlock();
                const muxer_ptr = muxer_locked.unwrap_ptr();
                break :blk video_replay_buffer != null or muxer_ptr.* != null;
            };

            const copy_data = blk: {
                const capture_preview_ring_buffer_locked = self.vulkan.capture_preview_ring_buffer.lock();
                defer capture_preview_ring_buffer_locked.unlock();
                const _copy_data = try capture_preview_ring_buffer_locked.unwrap().?.copy_image_to_ring_buffer(
                    .{
                        .src_image = image_slc[0],
                        .src_width = vulkan_image_buffer.as_ptr().width,
                        .src_height = vulkan_image_buffer.as_ptr().height,
                        .wait_semaphore = null,
                        // Only signal this semaphore when encode will wait on it.
                        .use_signal_semaphore = should_encode,
                        .timestamp_ns = vulkan_image_buffer.as_ptr().timestamp_ns,
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

            try video_encoder.prepare_encode(.{
                .image = &image_slc,
                .image_view = &image_view_slc,
                .input_size = .{
                    .width = vulkan_image_buffer.as_ptr().width,
                    .height = vulkan_image_buffer.as_ptr().height,
                },
                .external_wait_semaphore = copy_data.semaphore,
            });

            const encode_result = try video_encoder.encode(0);
            const encoded_packet = try video_encoder.finish_encode(
                encode_result,
                video_replay_buffer,
                vulkan_image_buffer.as_ptr().timestamp_ns,
            );

            if (self.record_data_queue) |*record_data_queue| {
                var video_record_data = try VideoRecordData.init(
                    self.allocator,
                    encoded_packet,
                    vulkan_image_buffer.as_ptr().timestamp_ns,
                    encode_result.idr,
                );

                record_data_queue.send(.{ .data = video_record_data }) catch |err| {
                    video_record_data.deinit();
                    if (err != ChanError.Closed) {
                        return err;
                    }
                };
            }

            if (video_replay_buffer) |_video_replay_buffer| {
                self.store.dispatch(.{
                    .capture = .{
                        .update_replay_buffer_size = .{
                            .video = .{ .size = _video_replay_buffer.size, .seconds = _video_replay_buffer.get_seconds() },
                        },
                    },
                });
            }
        }
    }

    fn record_to_disk_thread_handler(self: *Self) void {
        while (true) {
            if (self.record_data_queue) |*record_data_queue| {
                var payload = record_data_queue.recv() catch |err| {
                    if (err == ChanError.Closed) {
                        break;
                    }
                    log.err("[record_to_disk_thread_handler] record_data_queue.recv error: {}", .{err});
                    return;
                };

                switch (payload) {
                    .done => return,
                    .data => |*data| {
                        var muxer_locked = self.store.capture_store.muxer.lock();
                        defer muxer_locked.unlock();
                        const muxer_ptr = muxer_locked.unwrap_ptr();
                        if (muxer_ptr.*) |*muxer| {
                            muxer.write_video_packet(self.allocator, data.data, data.timestamp_ns, data.is_idr) catch |err| {
                                log.err("[record_to_disk_thread_handler] muxer.write_video_packet error: {}", .{err});
                            };
                        } else {
                            data.deinit();
                        }
                    },
                }
            } else {
                return;
            }
        }
    }

    pub fn take_and_swap_replay_buffer(self: *Self, replay_seconds: u32) !?*VideoReplayBuffer {
        self.video_record_mutex.lock();
        defer self.video_record_mutex.unlock();

        var video_replay_buffer_locked = self.video_replay_buffer.lock();
        defer video_replay_buffer_locked.unlock();
        const video_replay_buffer = video_replay_buffer_locked.unwrap();

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

        return video_replay_buffer;
    }

    pub fn set_replay_buffer_seconds(self: *Self, replay_seconds: u32) void {
        var replay_buffer_locked = self.video_replay_buffer.lock();
        defer replay_buffer_locked.unlock();
        if (replay_buffer_locked.unwrap()) |replay_buffer| {
            replay_buffer.set_replay_seconds(replay_seconds);
        }
    }
};
