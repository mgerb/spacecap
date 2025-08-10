const Self = @This();

const ReplayBufferState = struct {
    size: u64 = 0,
    seconds: u64 = 0,

    pub fn sizeInMB(self: *const @This()) f64 {
        const mb = @as(f64, @floatFromInt(self.size)) / (1024.0 * 1024.0);
        return mb;
    }
};

// User settings
replay_seconds: u32 = 60,
fps: u32 = 60,
bit_rate: u64 = 20_000_000,

recording: bool = false,
has_source: bool = false,
show_demo: bool = false,
selected_screen_cast_identifier: ?[]u8 = null,

replay_buffer_state: ReplayBufferState = .{},
