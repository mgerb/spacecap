const std = @import("std");

const vk = @import("vulkan");

const types = @import("../../types.zig");
const util = @import("../../util.zig");
const Vulkan = @import("../../vulkan/vulkan.zig").Vulkan;
const CaptureSourceType = @import("../capture.zig").CaptureSourceType;
const Capture = @import("../capture.zig").Capture;

const DWORD = u32;

pub const WindowsCapture = struct {
    const Self = @This();
    const DWORD = u32;

    allocator: std.mem.Allocator,
    vulkan: *Vulkan,

    pub fn init(allocator: std.mem.Allocator, vulkan: *Vulkan) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .vulkan = vulkan,
        };
        return self;
    }

    pub fn selectSource(context: *anyopaque, source_type: CaptureSourceType) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        _ = source_type;
    }

    pub fn waitForReady(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
    }

    pub fn nextFrame(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
    }

    pub fn closeNextFrameChan(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
    }

    pub fn waitForFrame(context: *anyopaque) !types.VkImages {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        return .{
            .image = .null_handle,
            .image_view = .null_handle,
        };
    }

    pub fn size(context: *anyopaque) ?types.Size {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        return null;
    }

    pub fn externalWaitSemaphore(context: *anyopaque) ?vk.Semaphore {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        return null;
    }

    pub fn stop(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
    }

    // pub fn selectedScreenCastIdentifier(self: *anyopaque) ?[]const u8 {
    //     const self: *Self = @ptrCast(@alignCast(context));
    //     _ = self;
    //     return null;
    // }

    pub fn deinit(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.allocator.destroy(self);
    }

    pub fn capture(self: *Self) Capture {
        return .{
            .ptr = self,
            .vulkan = self.vulkan,
            .vtable = &.{
                .selectSource = selectSource,
                .nextFrame = nextFrame,
                .closeNextFrameChan = closeNextFrameChan,
                .waitForFrame = waitForFrame,
                .size = size,
                .externalWaitSemaphore = externalWaitSemaphore,
                .stop = stop,
                .deinit = deinit,
            },
        };
    }
};

/// Capture a screenshot in windows - the caller owns the returned memory
pub fn windowsCapture(allocator: std.mem.Allocator) ![]u8 {
    const win32 = @import("win32");
    const c = win32.everything;

    const width: i32 = c.GetSystemMetrics(c.SM_CXSCREEN);
    const height: i32 = c.GetSystemMetrics(c.SM_CYSCREEN);

    const hScreenDC: c.HDC = c.GetDC(null) orelse unreachable;
    defer _ = c.DeleteObject(@ptrCast(hScreenDC));
    const hMemoryDC: c.HDC = c.CreateCompatibleDC(hScreenDC);
    defer _ = c.DeleteObject(@ptrCast(hMemoryDC));
    const hBitmap: c.HBITMAP = c.CreateCompatibleBitmap(hScreenDC, width, height) orelse unreachable;
    defer _ = c.DeleteObject(hBitmap);

    _ = c.SelectObject(hMemoryDC, hBitmap);
    _ = c.BitBlt(hMemoryDC, 0, 0, width, height, hScreenDC, 0, 0, c.SRCCOPY);

    const bitMapInfoHeader = win32.everything.BITMAPINFOHEADER{
        .biSize = @sizeOf(win32.everything.BITMAPINFOHEADER),
        .biWidth = width,
        .biHeight = -height,
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = win32.everything.BI_RGB,
        .biSizeImage = 0,
        .biXPelsPerMeter = 0,
        .biYPelsPerMeter = 0,
        .biClrUsed = 0,
        .biClrImportant = 0,
    };

    const dwBmpSize: DWORD = @intCast(@divFloor((width * bitMapInfoHeader.biBitCount + 31), 32) * 4 * height);

    const lpbitmap = try allocator.alloc(u8, @intCast(dwBmpSize));

    _ = c.GetDIBits(
        hMemoryDC,
        hBitmap,
        0,
        @intCast(height),
        @ptrCast(lpbitmap),
        @ptrCast(@constCast(&bitMapInfoHeader)),
        c.DIB_RGB_COLORS,
    );

    // Write to file
    const bitMapFileHeader = win32.everything.BITMAPFILEHEADER{
        .bfOffBits = @sizeOf(c.BITMAPFILEHEADER) + @sizeOf(c.BITMAPINFOHEADER),
        .bfReserved1 = 0,
        .bfReserved2 = 0,
        .bfSize = dwBmpSize + @sizeOf(c.BITMAPFILEHEADER) + @sizeOf(c.BITMAPINFOHEADER),
        .bfType = 0x4D42, // 'BM'
    };

    var out = std.ArrayList(u8).init(allocator);
    try out.appendSlice(std.mem.asBytes(&bitMapFileHeader));
    try out.appendSlice(std.mem.asBytes(&bitMapInfoHeader));
    try out.appendSlice(lpbitmap);

    return try out.toOwnedSlice();
}
