test {
    // NOTE: This fixes a linking error with tests. Probably won't be
    // needed once test coverage is expanded and starts testing things
    // that link pipewire.
    const pipewire = @import("pipewire");
    _ = pipewire;
    _ = @import("./channel.zig");
    _ = @import("./video/video_replay_buffer.zig");
    _ = @import("./capture/audio/audio_capture_data.zig");
    _ = @import("./audio/audio_mixer.zig");
    _ = @import("./audio/audio_replay_buffer.zig");
    _ = @import("./ffmpeg.zig");
    _ = @import("./audio/audio_encoder.zig");
    _ = @import("./video/muxer.zig");
    _ = @import("./common/linux/token_manager.zig");
    _ = @import("./mutex.zig");
    _ = @import("./string.zig");
}
