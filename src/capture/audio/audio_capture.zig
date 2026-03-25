const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const BufferedChan = @import("../../channel.zig").BufferedChan;
const ChanError = @import("../../channel.zig").ChanError;
const AudioCaptureData = @import("./audio_capture_data.zig");

// TODO: Maybe make these configurable?
pub const SAMPLE_RATE: u32 = 48_000;
pub const CHANNELS: u32 = 2;

// TODO: Adjust chan size.
pub const AudioCaptureBufferedChan = BufferedChan(*AudioCaptureData, 1_000);

pub const AudioDeviceType = enum {
    source,
    sink,
};

pub const AudioDeviceList = struct {
    const Self = @This();
    pub const AudioDeviceInfo = struct {
        id: []const u8,
        name: []const u8,
        device_type: AudioDeviceType,
        is_default: bool,
    };

    arena: *ArenaAllocator,
    devices: std.ArrayList(AudioDeviceInfo),

    pub fn init(allocator: Allocator) !Self {
        const arena = try allocator.create(ArenaAllocator);
        arena.* = .init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }

        return .{
            .arena = arena,
            .devices = try .initCapacity(arena.allocator(), 0),
        };
    }

    /// Append to device list. Device info is copied.
    pub fn append(self: *Self, audio_device: AudioDeviceInfo) !void {
        const allocator = self.arena.allocator();
        var audio_device_copy = audio_device;
        audio_device_copy.id = try allocator.dupe(u8, audio_device.id);
        audio_device_copy.name = try allocator.dupe(u8, audio_device.name);
        try self.devices.append(allocator, audio_device_copy);
    }

    pub fn deinit(self: *Self) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

pub const SelectedAudioDevice = struct {
    id: []const u8,
    device_type: AudioDeviceType,
};

/// AudioCapture interface.
pub const AudioCapture = struct {
    const Self = @This();
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        receive_data: *const fn (*anyopaque) ChanError!*AudioCaptureData,
        stop: *const fn (*anyopaque) anyerror!void,
        get_available_devices: *const fn (*anyopaque, std.mem.Allocator) anyerror!AudioDeviceList,
        update_selected_devices: *const fn (*anyopaque, []const SelectedAudioDevice) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    /// Receive audio capture data. Caller owns the memory and must deinit.
    pub fn receive_data(self: *Self) ChanError!*AudioCaptureData {
        return self.vtable.receive_data(self.ptr);
    }

    pub fn stop(self: *Self) !void {
        return self.vtable.stop(self.ptr);
    }

    pub fn get_available_devices(self: *Self, allocator: std.mem.Allocator) !AudioDeviceList {
        return self.vtable.get_available_devices(self.ptr, allocator);
    }

    pub fn update_selected_devices(self: *Self, devices: []const SelectedAudioDevice) !void {
        return self.vtable.update_selected_devices(self.ptr, devices);
    }

    pub fn deinit(self: *Self) void {
        return self.vtable.deinit(self.ptr);
    }
};
