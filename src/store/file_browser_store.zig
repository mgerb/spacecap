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
        select_file: String,

        pub const effects = .{
            .load_files = .{effect_load_files},
            .select_file = .{VideoEditorStore.effect_open_session},
        };

        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                .load_files_success => |*files| files.deinit(),
                .select_file => |*file_path| file_path.deinit(),
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
        files: FileList,

        pub fn init(allocator: Allocator) @This() {
            return .{ .files = .init(allocator) };
        }

        pub fn deinit(self: *@This()) void {
            self.files.deinit();
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

    fn less_than_file_name(_: void, lhs: FileEntry, rhs: FileEntry) bool {
        return std.mem.lessThan(u8, std.fs.path.basename(lhs.path.bytes), std.fs.path.basename(rhs.path.bytes));
    }
};
