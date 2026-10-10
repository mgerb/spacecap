const std = @import("std");
const vk = @import("vulkan");
const imguiz = @import("imguiz").imguiz;
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const VulkanImageBuffer = @import("./vulkan_image_buffer.zig").VulkanImageBuffer;
const Arc = @import("../arc.zig").Arc;

const BUFFER_SIZE = 3;

/// A fixed pool of reusable Vulkan images. Each image is ref counted with Arc.
/// When the consumer holds onto a ref, then the image will not be available in
/// the pool. The consumer is responsible for freeing images after they are taken
/// from the pool.
pub const VulkanImageBufferPool = struct {
    const Self = @This();
    const log = std.log.scoped(.vulkan_image_buffer_pool);

    /// A decoded video frame prepared for display by the UI.
    pub const DisplayFrame = struct {
        buffer: Arc(VulkanImageBuffer),
        texture: imguiz.ImTextureRef,
        width: u32,
        height: u32,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    buffers: [BUFFER_SIZE]Arc(VulkanImageBuffer) = undefined,
    vulkan: *Vulkan,
    mutex: std.Io.Mutex = .init,

    pub fn init(
        args: VulkanImageBuffer.InitArgs,
    ) !*Self {
        const self = try args.allocator.create(Self);
        errdefer args.allocator.destroy(self);

        self.* = .{
            .allocator = args.allocator,
            .io = args.io,
            .vulkan = args.vulkan,
        };

        self.buffers[0] = try VulkanImageBuffer.init(args);
        errdefer self.buffers[0].deinit();
        self.buffers[1] = try VulkanImageBuffer.init(args);
        errdefer self.buffers[1].deinit();
        self.buffers[2] = try VulkanImageBuffer.init(args);
        errdefer self.buffers[2].deinit();

        return self;
    }

    pub fn deinit(self: *Self) void {
        defer self.allocator.destroy(self);
        for (self.buffers) |buffer| {
            buffer.deinit();
        }
    }

    pub fn wait_for_fences(self: *Self) void {
        var wait_fences: [BUFFER_SIZE]vk.Fence = undefined;
        for (self.buffers, 0..) |buffer, i| {
            wait_fences[i] = buffer.as_ptr().fence;
        }

        const result = self.vulkan.device.waitForFences(
            wait_fences[0..],
            .true,
            std.math.maxInt(u64),
        ) catch |err| {
            log.err("[wait_for_fences] wait for capture image buffer pool fences error: {}", .{err});
            return;
        };
        if (result != .success) {
            log.err("[wait_for_fences] wait for capture image buffer pool fences result: {}", .{result});
        }
    }

    /// Copy an image into the buffer pool and then return the image buffer
    /// from the pool. The caller owns the buffer and is responsible for
    /// freeing it with `deinit`, where it will then it will be returned to the
    /// pool.
    ///
    /// If no buffer is available, then the returned image buffer will be null.
    pub fn copy_image_to_pool(self: *Self, args: struct {
        src_image: vk.Image,
        src_width: u32,
        src_height: u32,
        wait_semaphore: ?vk.Semaphore,
        use_signal_semaphore: bool,
        pts_ns: i128,
    }) !struct {
        vulkan_image_buffer: ?Arc(VulkanImageBuffer) = null,
        semaphore: ?vk.Semaphore = null,
        fence: ?vk.Fence = null,
    } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const index = self.get_available_buffer_index() orelse {
            return .{ .semaphore = args.wait_semaphore };
        };
        const vulkan_image_buffer = self.buffers[index];
        const buffer = vulkan_image_buffer.as_ptr();

        try buffer.copy_image_into(.{
            .src_image = args.src_image,
            .src_width = args.src_width,
            .src_height = args.src_height,
            .wait_semaphore = args.wait_semaphore,
            .use_signal_semaphore = args.use_signal_semaphore,
            .pts_ns = args.pts_ns,
        });

        buffer.updated_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;

        return .{
            .vulkan_image_buffer = vulkan_image_buffer.clone(),
            .semaphore = buffer.signal_semaphore,
            .fence = buffer.fence,
        };
    }

    /// Return an owned reference to the most recently published buffer.
    /// Returns null until a buffer has been set or copied into the pool.
    pub fn get_most_recent_buffer(self: *Self) ?Arc(VulkanImageBuffer) {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var output_index: ?usize = null;
        for (self.buffers, 0..) |buffer, index| {
            const updated_ns = buffer.as_ptr().updated_ns orelse continue;
            if (output_index == null or
                updated_ns > self.buffers[output_index.?].as_ptr().updated_ns.?)
            {
                output_index = index;
            }
        }

        const index = output_index orelse return null;
        return self.buffers[index].clone();
    }

    pub fn get_latest_display_frame(self: *Self) !?DisplayFrame {
        const buffer = self.get_most_recent_buffer() orelse return null;
        errdefer buffer.deinit();

        const texture = try buffer.as_ptr().get_imgui_texture();
        return .{
            .buffer = buffer,
            .texture = texture.im_texture_ref,
            .width = buffer.as_ptr().width,
            .height = buffer.as_ptr().height,
        };
    }

    /// Get the least recently used buffer, if available. Null if all are in use.
    /// Buffers are considered in use when their ref count > 1.
    pub fn get_available_buffer(self: *Self) ?Arc(VulkanImageBuffer) {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const index = self.get_available_buffer_index() orelse return null;
        return self.buffers[index].clone();
    }

    /// Get the least recently used buffer index. The caller must hold the mutex.
    fn get_available_buffer_index(self: *Self) ?usize {
        var output_index: ?usize = null;

        for (self.buffers, 0..) |buffer, index| {
            if (!buffer.is_unique()) {
                continue;
            }

            const updated_ns = buffer.as_ptr().updated_ns orelse return index;
            if (output_index == null or
                updated_ns < self.buffers[output_index.?].as_ptr().updated_ns.?)
            {
                output_index = index;
            }
        }

        return output_index;
    }

    /// Set a buffer. The image_buffer provided must have been grabbed from the pool.
    pub fn set_buffer(self: *Self, image_buffer: *VulkanImageBuffer) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.buffers) |buffer| {
            if (buffer.as_ptr() == image_buffer) {
                image_buffer.updated_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
                return;
            }
        }

        @panic("[set_buffer] buffer does not belong to this pool");
    }
};

const TestUtil = struct {
    fn init_image_buffer_pool(vulkan: *Vulkan) !*VulkanImageBufferPool {
        return VulkanImageBufferPool.init(.{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .vulkan = vulkan,
            .width = 1,
            .height = 1,
            .image_layout = .shader_read_only_optimal,
            .dst_stage_mask = .{ .fragment_shader = true },
            .dst_access_mask = .{ .shader_sampled_read = true },
            .usage = .{ .sampled = true, .storage = true },
            .image_component_mapping = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .src_queue_family_index = vulkan.graphics_queue.family,
        });
    }
};

test "VulkanImageBufferPool - selects buffers by update time" {
    const vulkan = try Vulkan.init(std.testing.allocator, std.testing.io, null);
    defer vulkan.deinit();
    const pool = try TestUtil.init_image_buffer_pool(vulkan);
    defer pool.deinit();

    try std.testing.expect(pool.get_most_recent_buffer() == null);
    pool.buffers[0].as_ptr().updated_ns = 30;
    pool.buffers[1].as_ptr().updated_ns = 10;
    pool.buffers[2].as_ptr().updated_ns = 20;

    const oldest = pool.get_available_buffer().?;
    defer oldest.deinit();
    try std.testing.expectEqual(pool.buffers[1].as_ptr(), oldest.as_ptr());

    const next = pool.get_available_buffer().?;
    defer next.deinit();
    try std.testing.expectEqual(pool.buffers[2].as_ptr(), next.as_ptr());

    {
        const next2 = pool.get_available_buffer().?;
        defer next2.deinit();
        try std.testing.expectEqual(pool.buffers[0].as_ptr(), next2.as_ptr());
    }

    const most_recent = pool.get_most_recent_buffer().?;
    defer most_recent.deinit();
    try std.testing.expectEqual(pool.buffers[0].as_ptr(), most_recent.as_ptr());
}
