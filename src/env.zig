const std = @import("std");
const Mutex = @import("./mutex.zig").Mutex;

pub var ENVIRON_MAP: Mutex(*std.process.Environ.Map) = undefined;

pub fn init(io: std.Io, environ_map: *std.process.Environ.Map) void {
    ENVIRON_MAP = .init(io, environ_map);
}

pub fn get_env_var_owned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const env_map_locked = ENVIRON_MAP.lock();
    defer env_map_locked.unlock();

    const value = env_map_locked.unwrap().get(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, value);
}
