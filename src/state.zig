const std = @import("std");
const Self = @This();
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const AudioCapture = @import("./capture/audio/audio_capture.zig").AudioCapture;
const UserSettingsState = @import("./state/user_settings_state.zig").UserSettingsState;
const AudioDeviceType = @import("./capture/audio/audio_capture.zig").AudioDeviceType;
const AudioState = @import("./state/audio_state.zig").AudioState;

// TODO: add audio size
const ReplayBufferViewModel = struct {
    size: u64 = 0,
    seconds: u64 = 0,

    pub fn sizeInMB(self: *const @This()) f64 {
        const mb = @as(f64, @floatFromInt(self.size)) / (1024.0 * 1024.0);
        return mb;
    }
};

// User settings
user_settings: UserSettingsState,
replay_seconds: u32 = 60,
fps: u32 = 60,
bit_rate: u64 = 20_000_000,

recording: bool = false,
has_source: bool = false,
show_demo: bool = false,
is_video_capture_supprted: bool,
audio: AudioState,

replay_buffer: ReplayBufferViewModel = .{},

pub fn init(
    allocator: Allocator,
    is_video_capture_supprted: bool,
    audio_capture: *AudioCapture,
) !Self {
    return .{
        .user_settings = try .init(allocator),
        .is_video_capture_supprted = is_video_capture_supprted,
        .audio = try .init(allocator, audio_capture),
    };
}

pub fn deinit(self: *Self) void {
    self.audio.deinit();
    self.user_settings.deinit();
}
