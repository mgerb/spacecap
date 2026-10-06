//! The purpose of this test is to ensure that we know whenever any new dynamic
//! libraries are added. For example, glib pulls in optional runtime
//! dependencies and it's not always obvious when this is the case.
const std = @import("std");

/// Snapshot of current runtime dependencies
const allowed_libraries = [_][]const u8{
    "linux-vdso.so.1",
    "libvulkan.so.1",
    "libgio-2.0.so.0",
    "libgobject-2.0.so.0",
    "libglib-2.0.so.0",
    "libwayland-client.so.0",
    "libm.so.6",
    "libc.so.6",
    "ld-linux-x86-64.so.2",
    "libpthread.so.0",
    "libdl.so.2",
    "libgmodule-2.0.so.0",
    "libffi.so.8",
    "libpcre2-8.so.0",
};

test "LinkedLibraries - ensure dynamic libraries have not changed" {
    const allocator = std.testing.allocator;
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "ldd", "zig-out/linux/spacecap" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    var lines = std.mem.tokenizeAny(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0) {
            continue;
        }

        var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
        const name = std.fs.path.basename(tokens.next().?);

        for (allowed_libraries) |allowed| {
            if (std.mem.startsWith(u8, name, allowed)) {
                break;
            }
        } else {
            std.debug.print("Unexpected dependency: {s}\n", .{trimmed});
            return error.UnexpectedDynamicLibrary;
        }
    }
}
