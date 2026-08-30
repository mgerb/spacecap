//! The main entrypoint to the FFmpeg module.

const std = @import("std");

pub const Png = @import("./png.zig").Png;
pub const Muxer = @import("./muxer.zig").Muxer;
pub const Demuxer = @import("./demuxer.zig").Demuxer;
pub const AudioEncoder = @import("./audio_encoder.zig").AudioEncoder;
pub const AudioDecoder = @import("./audio_decoder.zig").AudioDecoder;
pub const VideoDecoder = @import("./video_decoder.zig").VideoDecoder;

test {
    std.testing.refAllDecls(@This());
}
