const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("./store.zig").Store;
const VideoEditorStore = @import("./video_editor_store.zig").VideoEditorStore;
const String = @import("../string.zig").String;

pub const FileBrowserStore = struct {
    pub const FileEntry = struct {
        path: String,
        size_bytes: u64,

        pub fn deinit(self: *@This()) void {
            self.path.deinit();
        }
    };

    pub const FileList = struct {
        allocator: Allocator,
        entries: std.ArrayList(FileEntry) = .empty,

        pub fn init(allocator: Allocator) @This() {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *@This()) void {
            for (self.entries.items) |*entry| {
                entry.deinit();
            }
            self.entries.deinit(self.allocator);
        }
    };

    pub const Message = union(enum) {
        load_files,
        load_files_success: FileList,
        open_file_explorer: String,
        delete_file: String,
        select_file: String,
        /// Set a file path to new so that it is highlighted
        /// in the file browser.
        mark_file_new: String,
        mark_file_seen: String,

        pub const effects = .{
            .load_files = .{effect_load_files},
            .open_file_explorer = .{effect_open_file_explorer},
            .delete_file = .{effect_delete_file},
            .select_file = .{VideoEditorStore.effect_open_session},
        };

        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                .load_files_success => |*files| files.deinit(),
                .open_file_explorer => |*file_path| file_path.deinit(),
                .delete_file => |*file_path| file_path.deinit(),
                .select_file => |*file_path| file_path.deinit(),
                .mark_file_new => |*file_path| file_path.deinit(),
                .mark_file_seen => |*file_path| file_path.deinit(),
                inline else => |payload| {
                    if (@typeInfo(@TypeOf(payload)) == .@"struct" and
                        @hasDecl(@TypeOf(payload), "deinit"))
                    {
                        @compileError("Payload with 'deinit' must be explicitly handled.");
                    }
                },
            }
        }
    };

    pub const State = struct {
        allocator: Allocator,
        files: FileList,
        /// This is essentially a hash set. Files are highlighted when
        /// they are new. When mouse overing them they are removed here,
        /// making not highlighted.
        highlighted_paths: std.StringHashMap(void),

        pub fn init(allocator: Allocator) @This() {
            return .{
                .allocator = allocator,
                .files = .init(allocator),
                .highlighted_paths = std.StringHashMap(void).init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.files.deinit();
            var iterator = self.highlighted_paths.keyIterator();
            while (iterator.next()) |path| {
                self.allocator.free(@constCast(path.*));
            }
            self.highlighted_paths.deinit();
        }
    };

    pub fn update(_: Allocator, msg: Store.Message, state: *Store.State) !void {
        switch (msg) {
            .file_browser => |file_browser_msg| {
                switch (file_browser_msg) {
                    .load_files => {},
                    .load_files_success => |*files| {
                        state.file_browser.files.deinit();
                        state.file_browser.files = @constCast(files).*;
                    },
                    .mark_file_new => |file_path| {
                        defer @constCast(&file_path).deinit();
                        const highlighted_paths = &state.file_browser.highlighted_paths;
                        if (!highlighted_paths.contains(file_path.bytes)) {
                            const path = try state.file_browser.allocator.dupe(u8, file_path.bytes);
                            errdefer state.file_browser.allocator.free(path);
                            try highlighted_paths.put(path, {});
                        }
                    },
                    .mark_file_seen => |file_path| {
                        defer @constCast(&file_path).deinit();
                        if (state.file_browser.highlighted_paths.fetchRemove(file_path.bytes)) |removed| {
                            state.file_browser.allocator.free(@constCast(removed.key));
                        }
                    },
                    .open_file_explorer => {},
                    .delete_file => {},
                    .select_file => {},
                }
            },
            else => {},
        }
    }

    fn effect_load_files(store: *Store, _: void) !void {
        var file_browser_directory = blk: {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            const directory = state_locked.unwrap_ptr().user_settings.user_settings.file_browser_directory orelse return;
            break :blk try directory.clone(store.allocator);
        };
        defer file_browser_directory.deinit();

        var files: FileList = .init(store.allocator);
        errdefer files.deinit();

        var directory = if (std.fs.path.isAbsolute(file_browser_directory.bytes))
            try std.Io.Dir.openDirAbsolute(store.io, file_browser_directory.bytes, .{ .iterate = true })
        else
            try std.Io.Dir.cwd().openDir(store.io, file_browser_directory.bytes, .{ .iterate = true });
        defer directory.close(store.io);

        var iterator = directory.iterateAssumeFirstIteration();
        while (try iterator.next(store.io)) |entry| {
            const file_stat = directory.statFile(store.io, entry.name, .{}) catch continue;
            if (file_stat.kind != .file) continue;

            {
                const path = try std.fs.path.join(store.allocator, &.{ file_browser_directory.bytes, entry.name });
                var file_path = String.from(store.allocator, path) catch |err| {
                    store.allocator.free(path);
                    return err;
                };
                errdefer file_path.deinit();
                try files.entries.append(store.allocator, .{
                    .path = file_path,
                    .size_bytes = file_stat.size,
                });
            }
        }

        std.mem.sort(FileEntry, files.entries.items, {}, less_than_file_name);

        store.dispatch(.{ .file_browser = .{ .load_files_success = files } });
    }

    fn effect_open_file_explorer(store: *Store, file_path: String) !void {
        defer @constCast(&file_path).deinit();
        try store.file_picker.open_file_explorer(store.allocator, store.io, file_path.bytes);
    }

    fn effect_delete_file(store: *Store, file_path: String) !void {
        defer @constCast(&file_path).deinit();

        try std.Io.Dir.cwd().deleteFile(store.io, file_path.bytes);

        const session_id = blk: {
            const state_locked = store.state.lock();
            defer state_locked.unlock();
            break :blk state_locked.unwrap_ptr().video_editor.get_session_id_for_path(file_path.bytes);
        };
        if (session_id) |id| {
            store.dispatch(.{ .video_editor = .{ .close_session = id } });
        }
        store.dispatch(.{
            .file_browser = .{ .mark_file_seen = try String.init(store.allocator, file_path.bytes) },
        });
        store.dispatch(.{ .file_browser = .load_files });
    }

    fn less_than_file_name(_: void, lhs: FileEntry, rhs: FileEntry) bool {
        return std.mem.lessThan(u8, std.fs.path.basename(lhs.path.bytes), std.fs.path.basename(rhs.path.bytes));
    }
};
