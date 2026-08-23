//! The main entrypoint to the FFmpeg module.

const std = @import("std");

pub const Png = @import("./png.zig").Png;
pub const Muxer = @import("./muxer.zig").Muxer;
pub const AudioEncoder = @import("./audio_encoder.zig").AudioEncoder;

test {
    std.testing.refAllDecls(@This());
}
