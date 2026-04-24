const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("./store.zig").Store;
const GlobalShortcuts = @import("../global_shortcuts/global_shortcuts.zig").GlobalShortcuts;

pub const GlobalShortcutsStore = struct {
    const Self = @This();
    const log = std.log.scoped(.global_shortcuts_store);
    pub const Message = union(enum) {};
    pub const State = struct {};

    allocator: Allocator,
    store: *Store,

    pub fn init(allocator: Allocator, store: *Store, global_shortcuts: *GlobalShortcuts) !*Self {
        const self = try allocator.create(Self);

        self.* = .{
            .allocator = allocator,
            .store = store,
        };

        global_shortcuts.register_shortcut_handler(.{
            .ptr = self,
            .handler = Self.global_shortcuts_handler,
        });

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn update(allocator: Allocator, msg: Store.Message, state: *Store.State) !void {
        _ = allocator;
        _ = msg;
        _ = state;
    }

    pub fn global_shortcuts_handler(context: *anyopaque, shortcut: GlobalShortcuts.Shortcut) void {
        const self: *Self = @ptrCast(@alignCast(context));
        switch (shortcut) {
            .save_replay => {
                self.store.dispatch(.{ .capture = .save_replay });
            },
            .start_replay_buffer => {
                self.store.dispatch(.{ .capture = .start_replay_buffer });
            },
            .stop_replay_buffer => {
                self.store.dispatch(.{ .capture = .stop_replay_buffer });
            },
            .toggle_replay_buffer => {
                const is_replay_buffer_active = blk: {
                    const state_locked = self.store.state.lock();
                    defer state_locked.unlock();
                    break :blk state_locked.unwrap_ptr().capture.replay_buffer_active;
                };
                self.store.dispatch(.{ .capture = if (is_replay_buffer_active) .stop_replay_buffer else .start_replay_buffer });
            },
            .start_recording => {
                self.store.dispatch(.{ .capture = .start_recording_to_disk });
            },
            .stop_recording => {
                self.store.dispatch(.{ .capture = .stop_recording_to_disk });
            },
            .toggle_recording => {
                const recording_to_disk = blk: {
                    const state_locked = self.store.state.lock();
                    defer state_locked.unlock();
                    break :blk state_locked.unwrap_ptr().capture.recording_to_disk;
                };
                self.store.dispatch(.{ .capture = if (recording_to_disk) .stop_recording_to_disk else .start_recording_to_disk });
            },
        }
    }
};
