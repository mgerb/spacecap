const std = @import("std");
const AudioReplayBuffer = @import("../audio/audio_replay_buffer.zig");
const Mutex = @import("../mutex.zig").Mutex;
const AudioTimeline = @import("../audio/audio_timeline.zig").AudioTimeline;
const AudioCapture = @import("../capture/audio/audio_capture.zig").AudioCapture;
const Store = @import("./store.zig").Store;

pub const AudioSession = struct {
    const Self = @This();
    store: *Store,
    audio_capture: *AudioCapture,
    audio_replay_buffer: Mutex(?*AudioReplayBuffer) = .init(null),
    audio_recording_timeline: Mutex(?*AudioTimeline) = .init(null),
    capture_thread: ?std.Thread = null,

    pub fn init(
        store: *Store,
        audio_capture: *AudioCapture,
    ) Self {
        return .{
            .store = store,
            .audio_capture = audio_capture,
        };
    }
};
