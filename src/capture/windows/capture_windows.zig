const std = @import("std");

const vk = @import("vulkan");

const types = @import("../../types.zig");
const util = @import("../../util.zig");
const Vulkan = @import("../../vulkan/vulkan.zig").Vulkan;
const CaptureError = @import("../capture_error.zig").CaptureError;
const CaptureSourceType = @import("../capture.zig").CaptureSourceType;

const DWORD = u32;

pub const Capture = struct {
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

    pub fn selectSource(self: *Self, source_type: CaptureSourceType) !void {
        _ = self;
        _ = source_type;
    }

    pub fn waitForReady(self: *const Self) !void {
        _ = self;
    }

    pub fn nextFrame(self: *Self) !void {
        _ = self;
    }

    pub fn closeNextFrameChan(self: *Self) !void {
        _ = self;
    }

    pub fn waitForFrame(self: *const Self) !types.VkImages {
        _ = self;
        return .{
            .image = .null_handle,
            .image_view = .null_handle,
        };
    }

    pub fn size(self: *const Self) ?types.Size {
        _ = self;
        return null;
    }

    pub fn vkImage(self: *const Self) ?vk.Image {
        _ = self;
        return null;
    }

    pub fn vkImageView(self: *const Self) ?vk.ImageView {
        _ = self;
        return null;
    }

    pub fn externalWaitSemaphore(self: *const Self) ?vk.Semaphore {
        _ = self;
        return null;
    }

    pub fn stop(self: *Self) !void {
        _ = self;
    }

    pub fn selectedScreenCastIdentifier(self: *Self) ?[]const u8 {
        _ = self;
        return null;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }
};

/// Capture a screenshot in windows - the caller owns the returned memory
pub fn windowsCapture(allocator: std.mem.Allocator) CaptureError![]u8 {
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
