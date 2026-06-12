const std = @import("std");
const Mutex = @import("./mutex.zig").Mutex;

// NOTE: All application env variables should be defined here.
pub const SPACECAP_LOG_LEVEL = "SPACECAP_LOG_LEVEL";

/// Thread safe global environment map.
pub var ENVIRON_MAP: Mutex(*std.process.Environ.Map) = undefined;

pub fn init(io: std.Io, environ_map: *std.process.Environ.Map) void {
    ENVIRON_MAP = .init(io, environ_map);
}

pub fn get_env_var_owned(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    const env_map_locked = ENVIRON_MAP.lock();
    defer env_map_locked.unlock();

    const value = env_map_locked.unwrap().get(key) orelse return null;
    return allocator.dupe(u8, value) catch null;
}
