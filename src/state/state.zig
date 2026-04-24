const std = @import("std");
const Self = @This();
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const AudioCapture = @import("../capture/audio/audio_capture.zig").AudioCapture;
const UserSettingsState = @import("./user_settings_state.zig").UserSettingsState;
const AudioDeviceType = @import("../capture/audio/audio_capture.zig").AudioDeviceType;
const AudioState = @import("./audio_state.zig").AudioState;

const ReplayBufferViewModel = struct {
    video_size: u64 = 0,
    audio_size: u64 = 0,
    seconds: u64 = 0,

    pub fn size_in_mb(self: *const @This(), size_type: enum { total, audio, video }) f64 {
        return switch (size_type) {
            .total => _size_in_mb(self.audio_size + self.video_size),
            .audio => _size_in_mb(self.audio_size),
            .video => _size_in_mb(self.video_size),
        };
    }

    fn _size_in_mb(size: u64) f64 {
        const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
        return mb;
    }
};

// TODO: Move any "global" state into its own object.
is_recording_video: bool = false,
is_recording_to_disk: bool = false,
is_capturing_video: bool = false,
show_demo: bool = false,
is_video_capture_supprted: bool,

audio: AudioState,
// User settings
user_settings: UserSettingsState,

replay_buffer: ReplayBufferViewModel = .{},

pub fn init(
    allocator: Allocator,
    is_video_capture_supprted: bool,
    audio_capture: *AudioCapture,
) !Self {
    return .{
        .user_settings = try UserSettingsState.init(allocator),
        .is_video_capture_supprted = is_video_capture_supprted,
        .audio = try .init(allocator, audio_capture),
    };
}

pub fn deinit(self: *Self) void {
    self.audio.deinit();
    self.user_settings.deinit();
}
