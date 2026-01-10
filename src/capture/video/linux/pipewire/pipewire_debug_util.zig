const c = @import("./pipewire_include.zig");
const std = @import("std");
const util = @import("../../../../util.zig");

fn saveFrameToBmp(
    allocator: std.mem.Allocator,
    fd: i64,
    width: usize,
    height: usize,
    size: usize,
    filename: []const u8,
) !void {
    const PROT_READ = 0x1;
    const MAP_SHARED = 0x01;

    const ptr = c.mmap(
        null,
        size,
        PROT_READ,
        MAP_SHARED,
        @intCast(fd),
        0,
    ) orelse return error.FailedToMmap;

    defer {
        _ = c.munmap(ptr, size);
    }

    const pixels: [*]const u8 = @ptrCast(ptr);
    const slc = pixels[0..size];
    try util.write_bmp_bgrx(allocator, filename, @intCast(width), @intCast(height), slc);
}

// These write garbage because the format is likely not rgb/bgr
fn saveFrameToPPM(fd: i64, width: u32, height: u32, size: u32, stride: i32, filename: []const u8) !void {
    const PROT_READ = 0x1;
    const MAP_SHARED = 0x01;

    const ptr = c.mmap(
        null,
        size,
        PROT_READ,
        MAP_SHARED,
        @intCast(fd),
        0,
    ) orelse return error.FailedToMmap;

    defer {
        _ = c.munmap(ptr, size);
    }

    var aa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer aa.deinit();
    const allocator = aa.allocator();

    const pixels = try allocator.alloc(u8, size);
    defer allocator.free(pixels);
    // _ = c.pread(@intCast(fd), pixels.ptr, size, 0);
    const ptr_p: [*c]u8 = @ptrCast(ptr);
    @memcpy(pixels, ptr_p[0..size]);

    var file = try std.fs.cwd().createFile(filename, .{ .read = false, .truncate = true });
    defer file.close();

    var writer = file.writer();

    // Write the PPM header
    try writer.print("P6\n{} {}\n255\n", .{ width, height });

    // const pixels: [*c]const u8 = @ptrCast(ptr);

    const bytes_per_pixel = 4; // This is KEY

    for (0..height) |y| {
        const row_start = y * @as(usize, @intCast(stride));

        for (0..width) |x| {
            const px = row_start + (x * bytes_per_pixel);

            // std.debug.print("px:{}\n", .{@as(u32, @intCast(px))});

            const b = pixels[px];
            const g = pixels[px + 1];
            const r = pixels[px + 2];
            // const a = pixels[px + 3]; // alpha, ignored

            try writer.writeAll(&.{ r, g, b }); // write RGB
        }
    }
}
