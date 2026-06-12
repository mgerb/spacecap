const std = @import("std");

const types = @import("../../../types.zig");
const Vulkan = @import("../../../vulkan/vulkan.zig").Vulkan;
const VideoCaptureSelection = @import("../video_capture.zig").VideoCaptureSelection;
const VideoCapture = @import("../video_capture.zig").VideoCapture;
const VulkanImageBuffer = @import("../../../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;
const ChanError = @import("../../../channel.zig").ChanError;
const Arc = @import("../../../arc.zig").Arc;

const DWORD = u32;

pub const WindowsVideoCapture = struct {
    const Self = @This();
    const DWORD = u32;

    allocator: std.mem.Allocator,
    io: std.Io,
    vulkan: *Vulkan,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, vulkan: *Vulkan) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .io = io,
            .vulkan = vulkan,
        };
        return self;
    }

    pub fn select_source(context: *anyopaque, selection: VideoCaptureSelection, fps: u32) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        _ = selection;
        _ = fps;
    }

    pub fn update_fps(context: *anyopaque, fps: u32) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        _ = fps;
    }

    pub fn should_restore_capture_session(context: *anyopaque) !bool {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        return false;
    }

    pub fn wait_for_ready(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
    }

    pub fn next_frame(context: *anyopaque) ChanError!void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
    }

    pub fn close_all_channels(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
    }

    pub fn wait_for_frame(context: *anyopaque) ChanError!Arc(VulkanImageBuffer) {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        return ChanError.Closed;
    }

    pub fn size(context: *anyopaque) ?types.Size {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
        return null;
    }

    pub fn stop(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn video_capture(self: *Self) VideoCapture {
        return .{
            .ptr = self,
            .vtable = &.{
                .select_source = select_source,
                .update_fps = update_fps,
                .should_restore_capture_session = should_restore_capture_session,
                .next_frame = next_frame,
                .close_all_channels = close_all_channels,
                .wait_for_frame = wait_for_frame,
                .size = size,
                .stop = stop,
            },
        };
    }
};

/// Capture a screenshot in windows - the caller owns the returned memory
pub fn windows_capture(allocator: std.mem.Allocator) ![]u8 {
    const win32 = @import("win32");
    const c = win32.everything;

    const width: i32 = c.GetSystemMetrics(c.SM_CXSCREEN);
    const height: i32 = c.GetSystemMetrics(c.SM_CYSCREEN);

    const hScreenDC: c.HDC = c.GetDC(null) orelse @panic("c.GetDC error");
    defer _ = c.DeleteObject(@ptrCast(hScreenDC));
    const hMemoryDC: c.HDC = c.CreateCompatibleDC(hScreenDC);
    defer _ = c.DeleteObject(@ptrCast(hMemoryDC));
    const hBitmap: c.HBITMAP = c.CreateCompatibleBitmap(hScreenDC, width, height) orelse @panic("c.CreateCompatibleBitmap error");
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
