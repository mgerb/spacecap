const std = @import("std");
const Allocator = std.mem.Allocator;
const Arc = @import("../arc.zig").Arc;
const Store = @import("./store.zig").Store;
const String = @import("../string.zig").String;
const VideoEditorSession = @import("../video/video_editor_session.zig").VideoEditorSession;
const SessionId = VideoEditorSession.SessionId;
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const exporter = @import("../exporter.zig");

pub const VideoEditorStore = struct {
    const Self = @This();
    const log = std.log.scoped(.video_editor_store);

    pub const ExportTrimPayload = struct {
        session_id: SessionId,
        trim_start_ns: i64,
        trim_end_ns: i64,
    };

    allocator: Allocator,
    vulkan: *Vulkan,

    pub const Message = union(enum) {
        open_session_success: Arc(VideoEditorSession),
        set_active_session: SessionId,
        clear_active_session,
        close_session: SessionId,
        close_all_sessions,
        scrub: struct {
            session_id: SessionId,
            position_ns: i64,
        },
        set_scrubbing: struct {
            session_id: SessionId,
            scrubbing: bool,
        },
        set_playing: struct {
            session_id: SessionId,
            playing: bool,
        },
        set_trim_start: struct {
            session_id: SessionId,
            position_ns: i64,
        },
        set_trim_end: struct {
            session_id: SessionId,
            position_ns: i64,
        },
        step_previous_frame: struct { session_id: SessionId },
        step_next_frame: struct { session_id: SessionId },
        export_trim: ExportTrimPayload,

        pub const effects = .{
            .scrub = .{effect_wake_worker},
            .set_scrubbing = .{effect_wake_worker},
            .set_playing = .{effect_wake_worker},
            .set_trim_start = .{effect_wake_worker},
            .set_trim_end = .{effect_wake_worker},
            .step_previous_frame = .{effect_wake_worker},
            .step_next_frame = .{effect_wake_worker},
            .export_trim = .{effect_export_trim},
        };

        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                .open_session_success => |*session| session.deinit(),
                inline else => |payload| {
                    if (@typeInfo(@TypeOf(payload)) == .@"struct" and
                        @hasDecl(@TypeOf(payload), "deinit"))
                    {
                        @compileError("Payload with 'deinit' must be explicitly handled.");
                    }
                },
            }
        }
    };

    pub const State = struct {
        allocator: Allocator,
        /// This type of hash map is used to preserve order. The
        /// VideoEditorSession is ref counted because it's accessed in effects,
        /// which may outlive the main store update thread cycle.
        sessions: std.array_hash_map.Auto(SessionId, Arc(VideoEditorSession)),
        active_session_id: ?SessionId = null,

        pub fn init(allocator: Allocator) !@This() {
            return .{
                .allocator = allocator,
                .sessions = .empty,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.close_all_sessions();
            self.sessions.deinit(self.allocator);
        }

        fn get_active_session(self: *@This()) ?*VideoEditorSession {
            const session_id = self.active_session_id orelse return null;
            const session = self.sessions.get(session_id) orelse return null;
            return session.as_ptr();
        }

        /// Get the latest frame from the active session.
        /// WARNING: The underlying buffer is ref counted and must be freed.
        pub fn get_latest_frame(self: *@This()) !?VideoEditorSession.DisplayFrame {
            if (self.get_active_session()) |session| {
                return session.get_latest_frame();
            }
            return null;
        }

        /// Check if a session already exists for a file path.
        fn has_session_path(self: *@This(), file_path: []const u8) bool {
            for (self.sessions.values()) |session_ref| {
                const session = session_ref.as_ptr();
                if (std.mem.eql(u8, session.file_path.bytes, file_path)) {
                    return true;
                }
            }
            return false;
        }

        fn set_active_session(self: *@This(), session_id: ?SessionId) void {
            self.active_session_id = if (session_id) |id|
                if (self.sessions.contains(id)) id else null
            else
                null;
            self.sync_session_activity();
        }

        fn close_session(self: *@This(), session_id: SessionId) void {
            const removed = self.sessions.fetchOrderedRemove(session_id) orelse return;
            if (self.active_session_id == session_id) {
                self.active_session_id = null;
            }
            var session = removed.value;
            session.deinit();
            self.sync_session_activity();
        }

        fn close_all_sessions(self: *@This()) void {
            self.active_session_id = null;
            for (self.sessions.values()) |session| {
                session.deinit();
            }
            self.sessions.clearRetainingCapacity();
        }

        fn sync_session_activity(self: *@This()) void {
            var iterator = self.sessions.iterator();
            while (iterator.next()) |entry| {
                const is_active = self.active_session_id == entry.key_ptr.*;
                if (!is_active) {
                    entry.value_ptr.as_ptr().set_playing(false);
                }
            }
        }
    };

    pub fn init(allocator: Allocator, vulkan: *Vulkan) Self {
        return .{
            .allocator = allocator,
            .vulkan = vulkan,
        };
    }

    pub fn deinit(_: *Self) void {}

    pub fn exit(_: *Self) void {}

    // WARNING: Make sure we don't lock the VideoEditorSession lock in this update method.
    pub fn update(_: Allocator, msg: Store.Message, state: *Store.State) !void {
        switch (msg) {
            .video_editor => |video_editor_msg| {
                switch (video_editor_msg) {
                    .open_session_success => |session| {
                        var owned_session = session;
                        if (state.video_editor.has_session_path(owned_session.as_ptr().file_path.bytes)) {
                            owned_session.deinit();
                            return;
                        }
                        errdefer owned_session.deinit();
                        const session_id = owned_session.as_ptr().id;
                        try state.video_editor.sessions.put(state.video_editor.allocator, session_id, owned_session);
                        errdefer {
                            state.video_editor.active_session_id = null;
                            _ = state.video_editor.sessions.swapRemove(session_id);
                        }
                        state.video_editor.set_active_session(session_id);
                    },
                    .set_active_session => |session_id| state.video_editor.set_active_session(session_id),
                    .clear_active_session => state.video_editor.set_active_session(null),
                    .close_session => |session_id| state.video_editor.close_session(session_id),
                    .close_all_sessions => state.video_editor.close_all_sessions(),
                    .scrub => |payload| {
                        if (state.video_editor.sessions.get(payload.session_id)) |session| {
                            session.as_ptr().scrub_to(payload.position_ns);
                        }
                    },
                    .set_scrubbing => |payload| {
                        if (state.video_editor.sessions.get(payload.session_id)) |session| {
                            session.as_ptr().set_scrubbing(payload.scrubbing);
                        }
                    },
                    .set_playing => |payload| {
                        if (state.video_editor.sessions.get(payload.session_id)) |session| {
                            session.as_ptr().set_playing(payload.playing);
                        }
                    },
                    .set_trim_start => |payload| {
                        if (state.video_editor.sessions.get(payload.session_id)) |session| {
                            session.as_ptr().set_trim_start(payload.position_ns);
                        }
                    },
                    .set_trim_end => |payload| {
                        if (state.video_editor.sessions.get(payload.session_id)) |session| {
                            session.as_ptr().set_trim_end(payload.position_ns);
                        }
                    },
                    .step_previous_frame => |payload| {
                        if (state.video_editor.sessions.get(payload.session_id)) |session| {
                            session.as_ptr().step_previous_frame();
                        }
                    },
                    .step_next_frame => |payload| {
                        if (state.video_editor.sessions.get(payload.session_id)) |session| {
                            session.as_ptr().step_next_frame();
                        }
                    },
                    .export_trim => {},
                }
            },
            else => {},
        }
    }

    /// Dispatched from the select_file message in FileBrowserStore.
    pub fn effect_open_session(store: *Store, file_path: String) !void {
        const self = &store.video_editor_store;
        var owned_file_path = file_path;
        defer owned_file_path.deinit();

        {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            if (state_locked.unwrap_ptr().video_editor.has_session_path(owned_file_path.bytes)) {
                log.debug("[effect_open_session] session alrady open: {s}", .{file_path.bytes});
                return;
            }
        }

        var session = try VideoEditorSession.init(
            self.allocator,
            self.vulkan,
            owned_file_path.bytes,
        );
        errdefer session.deinit();

        store.dispatch(.{ .video_editor = .{
            .open_session_success = try Arc(VideoEditorSession).init(self.allocator, session),
        } });
    }

    /// This is in an effect, because wake_worker locks its mutex. We don't
    /// want to call any other locks while holding the state mutex lock,
    /// because that could cause the UI to hang.
    fn effect_wake_worker(store: *Store, payload: anytype) void {
        var session = blk: {
            const state_locked = store.state.lock();
            defer state_locked.unlock();

            const session = state_locked.unwrap_ptr().video_editor.sessions.get(payload.session_id) orelse return;
            break :blk session.clone();
        };
        defer session.deinit();

        session.as_ptr().wake_worker();
    }

    fn effect_export_trim(store: *Store, payload: ExportTrimPayload) !void {
        var input_path: String = undefined;
        var output_directory: String = undefined;
        {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            const state = state_locked.unwrap_ptr();
            const session = state.video_editor.sessions.get(payload.session_id) orelse {
                return error.VideoEditorSessionNotFound;
            };
            input_path = try session.as_ptr().file_path.clone(store.allocator);
            errdefer input_path.deinit();
            const configured_output_directory =
                state.user_settings.user_settings.video_output_directory orelse
                return error.MissingVideoOutputDirectory;
            output_directory = try configured_output_directory.clone(store.allocator);
        }
        defer input_path.deinit();
        defer output_directory.deinit();

        const output_path = exporter.export_trimmed_video(
            store.allocator,
            store.io,
            input_path.bytes,
            payload.trim_start_ns,
            payload.trim_end_ns,
            output_directory.bytes,
        ) catch |err| {
            log.err("[effect_export_trim] failed to export {s}: {}", .{ input_path.bytes, err });
            return err;
        };
        defer store.allocator.free(output_path);

        log.info("[effect_export_trim] exported {s}", .{output_path});
        store.dispatch(.{ .file_browser = .load_files });
    }
};

const TestUtil = struct {
    const VulkanImageBuffer = @import("../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;
    const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;
    const Fixture = struct {
        file_path: []const u8,
        /// Hash of the raw decoded frame data that we are testing for.
        expected_hash: Digest,
    };
    const fixtures = [_]Fixture{
        .{
            .file_path = "./test/sample_video_1_h264.mp4",
            .expected_hash = .{
                0x74, 0xc2, 0xe2, 0x11, 0x58, 0x9f, 0x36, 0x9a,
                0x5f, 0x40, 0x47, 0x50, 0xc2, 0xae, 0xda, 0x03,
                0x74, 0x6a, 0x41, 0x30, 0x2e, 0x9d, 0xa3, 0x12,
                0x81, 0xcc, 0x40, 0xbb, 0xdd, 0xc2, 0x0c, 0x85,
            },
        },
        .{
            .file_path = "./test/sample_video_1_h265.mkv",
            .expected_hash = .{
                0x18, 0xa2, 0x6d, 0x40, 0x05, 0xb7, 0x7a, 0xc3,
                0xa3, 0xc3, 0xdc, 0x7d, 0x4f, 0xdb, 0x3f, 0xbb,
                0x8a, 0x6a, 0x4d, 0x5f, 0x3a, 0x88, 0x21, 0x9d,
                0x95, 0x1c, 0xb8, 0x37, 0xaf, 0x81, 0xc8, 0x72,
            },
        },
        .{
            .file_path = "./test/sample_video_1_vp9.webm",
            .expected_hash = .{
                0xc3, 0x1e, 0x4c, 0x86, 0x35, 0x2d, 0x93, 0x14,
                0x42, 0x1b, 0x18, 0x9a, 0x0b, 0xc5, 0x1c, 0xf4,
                0xe0, 0x5d, 0x82, 0x07, 0xaa, 0x94, 0xe4, 0x7d,
                0x3f, 0x20, 0xba, 0x12, 0x68, 0x38, 0xa2, 0x5b,
            },
        },
    };

    fn step_to_frame(
        store: *Store,
        session: *VideoEditorSession,
        step: enum { next, previous },
        expected_frame_pts_ns: i128,
    ) !void {
        switch (step) {
            .next => store.dispatch(.{ .video_editor = .{
                .step_next_frame = .{ .session_id = session.id },
            } }),
            .previous => store.dispatch(.{ .video_editor = .{
                .step_previous_frame = .{ .session_id = session.id },
            } }),
        }
        store.run(.{ .once = true, .wait_for_effects = true });

        const image_buffer = try wait_for_frame(session, expected_frame_pts_ns);
        defer deinit_frame(&image_buffer);
    }

    /// There's currently not a reliable way to wait for a frame to be
    /// submitted to the ring buffer, so we can just poll it and use a timeout
    /// for now.
    fn wait_for_frame(
        session: *VideoEditorSession,
        expected_frame_pts_ns: i128,
    ) !Arc(VulkanImageBuffer) {
        const timeout_ns = 5 * std.time.ns_per_s;
        const started_at = std.Io.Timestamp.now(std.testing.io, .awake);

        while (true) {
            if (session.ring_buffer.get_most_recent_buffer()) |buffer| {
                if (buffer.as_ptr().timestamp_ns == expected_frame_pts_ns) {
                    return buffer;
                }
                deinit_frame(&buffer);
            }

            const now = std.Io.Timestamp.now(std.testing.io, .awake);
            if (started_at.durationTo(now).toNanoseconds() >= timeout_ns) {
                return error.VideoEditorFrameTimeout;
            }
            try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
        }
    }

    fn deinit_frame(buffer: *const Arc(VulkanImageBuffer)) void {
        buffer.as_ptr().in_use.store(false, .release);
        buffer.deinit();
    }
};

// This is essentially an e2e test, because it covers lots of things. Opens a
// video, demuxes, decodes, and copies back to CPU buffer to compare a
// snapshot. It's not useful to tell what exactly changed, however, if the
// snapshot fails, then something may be broken in one of these places.
test "VideoEditorStore - init, scrub, and close all sessions" {
    const TestStore = @import("./store.zig").TestStore;
    const allocator = std.testing.allocator;
    const test_store = try TestStore.init(allocator);
    defer test_store.deinit();
    const store = test_store.store;
    const state = &store.state.private.value;

    const scrub_position_ns = 10_050 * std.time.ns_per_ms;
    const expected_frame_pts_ns = 10 * std.time.ns_per_s;

    // Test each video with a hash of the frame that we seek to.
    for (TestUtil.fixtures, 1..) |fixture, expected_session_count| {
        store.dispatch(.{ .file_browser = .{
            .select_file = try .init(allocator, fixture.file_path),
        } });
        store.run(.{ .once = true, .wait_for_effects = true });
        store.run(.{ .once = true, .wait_for_effects = true });

        try std.testing.expectEqual(expected_session_count, state.video_editor.sessions.count());
        const session = state.video_editor.get_active_session().?;

        store.dispatch(.{ .video_editor = .{ .scrub = .{
            .session_id = session.id,
            .position_ns = scrub_position_ns,
        } } });
        store.run(.{ .once = true, .wait_for_effects = true });

        {
            const image_buffer = try TestUtil.wait_for_frame(session, expected_frame_pts_ns);
            defer TestUtil.deinit_frame(&image_buffer);

            try std.testing.expectEqual(320, image_buffer.as_ptr().width);
            try std.testing.expectEqual(224, image_buffer.as_ptr().height);
            try std.testing.expectEqual(expected_frame_pts_ns, image_buffer.as_ptr().timestamp_ns);
            try std.testing.expectEqual(expected_frame_pts_ns, session.playback_position_ns());

            const rgba = try image_buffer.as_ptr().copy_image_to_cpu_buffer(allocator);
            defer allocator.free(rgba);
            try std.testing.expectEqual(320 * 224 * 4, rgba.len);

            var actual_hash: TestUtil.Digest = undefined;
            std.crypto.hash.sha2.Sha256.hash(rgba, &actual_hash, .{});
            try std.testing.expectEqual(fixture.expected_hash, actual_hash);
        }
    }

    store.dispatch(.{ .video_editor = .close_all_sessions });
    store.run(.{ .once = true, .wait_for_effects = true });
    try std.testing.expectEqual(0, state.video_editor.sessions.count());
}

test "VideoEditorStore - step next, previous, then close session" {
    const TestStore = @import("./store.zig").TestStore;
    const allocator = std.testing.allocator;
    const test_store = try TestStore.init(allocator);
    defer test_store.deinit();
    const store = test_store.store;
    const state = &store.state.private.value;

    const scrub_position_ns = 10_050 * std.time.ns_per_ms;
    const scrubbed_frame_pts_ns: i128 = 10 * std.time.ns_per_s;
    const frame_duration_ns = 100 * std.time.ns_per_ms;

    for (TestUtil.fixtures) |fixture| {
        store.dispatch(.{ .file_browser = .{
            .select_file = try .init(allocator, fixture.file_path),
        } });
        store.run(.{ .once = true, .wait_for_effects = true });
        store.run(.{ .once = true, .wait_for_effects = true });

        try std.testing.expectEqual(1, state.video_editor.sessions.count());
        const session = state.video_editor.get_active_session().?;

        store.dispatch(.{ .video_editor = .{ .scrub = .{
            .session_id = session.id,
            .position_ns = scrub_position_ns,
        } } });
        store.run(.{ .once = true, .wait_for_effects = true });

        {
            const image_buffer = try TestUtil.wait_for_frame(session, scrubbed_frame_pts_ns);
            defer TestUtil.deinit_frame(&image_buffer);
        }

        // Step 2 frames forward, 4 back, then 2 forward again. We should end
        // up on the frame we are targetting.
        var expected_frame_pts_ns = scrubbed_frame_pts_ns;
        for (0..2) |_| {
            expected_frame_pts_ns += frame_duration_ns;
            try TestUtil.step_to_frame(store, session, .next, expected_frame_pts_ns);
        }

        for (0..4) |_| {
            expected_frame_pts_ns -= frame_duration_ns;
            try TestUtil.step_to_frame(store, session, .previous, expected_frame_pts_ns);
        }

        for (0..2) |_| {
            expected_frame_pts_ns += frame_duration_ns;
            try TestUtil.step_to_frame(store, session, .next, expected_frame_pts_ns);
        }

        {
            const image_buffer = try TestUtil.wait_for_frame(session, scrubbed_frame_pts_ns);
            defer TestUtil.deinit_frame(&image_buffer);

            const rgba = try image_buffer.as_ptr().copy_image_to_cpu_buffer(allocator);
            defer allocator.free(rgba);

            var actual_hash: TestUtil.Digest = undefined;
            std.crypto.hash.sha2.Sha256.hash(rgba, &actual_hash, .{});
            try std.testing.expectEqual(fixture.expected_hash, actual_hash);
        }

        store.dispatch(.{ .video_editor = .{ .close_session = session.id } });
        store.run(.{ .once = true, .wait_for_effects = true });
        try std.testing.expectEqual(0, state.video_editor.sessions.count());
    }
}
