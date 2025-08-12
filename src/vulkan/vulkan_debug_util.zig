/// Various functions used for debugging stuff in with Vulkan
const std = @import("std");
const vk = @import("vulkan");
const util = @import("../util.zig");
const Vulkan = @import("./vulkan.zig").Vulkan;

pub fn debugWriteImageToFile(
    vulkan: *Vulkan,
    image: vk.Image,
    fence: ?vk.Fence,
    width: u32,
    height: u32,
    file_name: []const u8,
    wait_semaphore: ?vk.Semaphore,
) !vk.Semaphore {
    std.debug.print("\n\ndebugWriteImageToFile\n\n", .{});
    if (fence != null) {
        const result = try vulkan.device.waitForFences(1, @ptrCast(&fence), vk.TRUE, std.math.maxInt(u64));
        if (result != .success) {
            return error.waitForFences;
        }
    }

    // create staging buffer
    const buffer_create_info = vk.BufferCreateInfo{
        .size = 4 * width * height,
        .usage = .{ .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
    };

    const buffer = try vulkan.device.createBuffer(&buffer_create_info, null);
    defer vulkan.device.destroyBuffer(buffer, null);

    const mem_reqs = vulkan.device.getBufferMemoryRequirements(buffer);

    const memory = try vulkan.allocate(
        mem_reqs,
        .{ .host_visible_bit = true, .host_coherent_bit = true },
        null,
    );
    defer vulkan.device.freeMemory(memory, null);

    try vulkan.device.bindBufferMemory(buffer, memory, 0);

    const copy_cmd_alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = vulkan.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };

    var command_buffer: vk.CommandBuffer = undefined;
    try vulkan.device.allocateCommandBuffers(&copy_cmd_alloc_info, @ptrCast(&command_buffer));
    defer vulkan.device.freeCommandBuffers(vulkan.command_pool, 1, @ptrCast(&command_buffer));

    try vulkan.device.beginCommandBuffer(command_buffer, &.{});

    const barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        // .src_stage_mask = .{ .top_of_pipe_bit = true },
        .src_access_mask = .{ .color_attachment_write_bit = true },
        .dst_stage_mask = .{ .all_transfer_bit = true },
        .dst_access_mask = .{ .transfer_read_bit = true },
        .old_layout = .undefined,
        .new_layout = .transfer_src_optimal,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };

    const dep_info = vk.DependencyInfoKHR{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&barrier),
    };

    vulkan.device.cmdPipelineBarrier2(command_buffer, &dep_info);

    const region = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{
            .width = width,
            .height = height,
            .depth = 1,
        },
    };

    vulkan.device.cmdCopyImageToBuffer(command_buffer, image, .transfer_src_optimal, buffer, 1, @ptrCast(&region));

    try vulkan.device.endCommandBuffer(command_buffer);

    const wait_stage_mask = vk.PipelineStageFlags{ .all_commands_bit = true };
    const signal_semaphore = try vulkan.device.createSemaphore(&.{}, null);
    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&command_buffer),
        .p_wait_semaphores = if (wait_semaphore != null) @ptrCast(&wait_semaphore) else null,
        .wait_semaphore_count = if (wait_semaphore != null) 1 else 0,
        .p_wait_dst_stage_mask = if (wait_semaphore != null) @ptrCast(&wait_stage_mask) else null,
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&signal_semaphore),
    };

    try vulkan.device.queueSubmit(vulkan.graphics_queue.handle, 1, @ptrCast(&submit_info), .null_handle);
    try vulkan.device.queueWaitIdle(vulkan.graphics_queue.handle);

    const size = width * height * 4;
    const data = try vulkan.device.mapMemory(memory, 0, size, .{});

    const pixel_data: [*]u8 = @ptrCast(data);

    try util.write_bmp_bgrx(vulkan.allocator, file_name, width, height, pixel_data[0..size]);

    return signal_semaphore;
}

pub fn debugCopyWriteImageToFile(
    vulkan: *Vulkan,
    image: vk.Image,
    format: vk.Format,
    fence: ?vk.Fence,
    width: u32,
    height: u32,
    file_name: []const u8,
    wait_semaphore: ?vk.Semaphore,
) !vk.Semaphore {
    std.debug.print("\n\ndebugCopyWriteImageToFile\n\n", .{});
    if (fence != null) {
        const result = try vulkan.device.waitForFences(1, @ptrCast(&fence), vk.TRUE, std.math.maxInt(u64));
        if (result != .success) {
            return error.waitForFences;
        }
    }
    const linear_image_create_info = vk.ImageCreateInfo{
        .image_type = .@"2d",
        .format = format, // pass in your format (same as imported image)
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .linear,
        .usage = .{ .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };

    const linear_image = try vulkan.device.createImage(&linear_image_create_info, null);
    defer vulkan.device.destroyImage(linear_image, null);

    // 2. Allocate memory for linear image (must be HOST_VISIBLE!)
    const linear_mem_reqs = vulkan.device.getImageMemoryRequirements(linear_image);
    const linear_memory = try vulkan.allocate(
        linear_mem_reqs,
        .{ .host_visible_bit = true, .host_coherent_bit = true },
        null,
    );
    defer vulkan.device.freeMemory(linear_memory, null);

    try vulkan.device.bindImageMemory(linear_image, linear_memory, 0);

    const copy_cmd_alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = vulkan.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    var command_buffer: vk.CommandBuffer = undefined;
    try vulkan.device.allocateCommandBuffers(&copy_cmd_alloc_info, @ptrCast(&command_buffer));
    defer vulkan.device.freeCommandBuffers(vulkan.command_pool, 1, @ptrCast(&command_buffer));

    try vulkan.device.beginCommandBuffer(command_buffer, &.{});
    // 3. Barrier: imported image → transfer_src_optimal
    //    and linear image → transfer_dst_optimal

    const barriers = [_]vk.ImageMemoryBarrier2{
        vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{ .color_attachment_write_bit = true },
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .dst_access_mask = .{ .transfer_read_bit = true },
            .old_layout = .general,
            .new_layout = .transfer_src_optimal,
            .image = image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = 0,
            .dst_queue_family_index = 0,
        },
        vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .top_of_pipe_bit = true },
            .src_access_mask = .{},
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .image = linear_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = 0,
            .dst_queue_family_index = 0,
        },
    };

    const dep_info = vk.DependencyInfoKHR{
        .image_memory_barrier_count = barriers.len,
        .p_image_memory_barriers = &barriers,
    };

    vulkan.device.cmdPipelineBarrier2(command_buffer, &dep_info);

    // 4. Copy imported image → linear image
    const copy_region = vk.ImageCopy{
        .src_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_offset = .{ .x = 0, .y = 0, .z = 0 },
        .dst_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
        .extent = .{ .width = width, .height = height, .depth = 1 },
    };

    vulkan.device.cmdCopyImage(
        command_buffer,
        image,
        .transfer_src_optimal,
        linear_image,
        .transfer_dst_optimal,
        1,
        @ptrCast(&copy_region),
    );

    // 5. Barrier: linear image → general (for CPU read)
    const read_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_transfer_bit = true },
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_stage_mask = .{ .host_bit = true },
        .dst_access_mask = .{ .host_read_bit = true },
        .old_layout = .transfer_dst_optimal,
        .new_layout = .general,
        .image = linear_image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };

    const read_dep_info = vk.DependencyInfoKHR{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&read_barrier),
    };

    vulkan.device.cmdPipelineBarrier2(command_buffer, &read_dep_info);

    try vulkan.device.endCommandBuffer(command_buffer);

    const wait_stage_mask = vk.PipelineStageFlags{ .all_commands_bit = true };
    const signal_semaphore = try vulkan.device.createSemaphore(&.{}, null);

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&command_buffer),
        .p_wait_semaphores = if (wait_semaphore != null) @ptrCast(&wait_semaphore) else null,
        .wait_semaphore_count = if (wait_semaphore != null) 1 else 0,
        .p_wait_dst_stage_mask = if (wait_semaphore != null) @ptrCast(&wait_stage_mask) else null,
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&signal_semaphore),
    };

    {
        vulkan.graphics_queue.mutex.lock();
        defer vulkan.graphics_queue.mutex.unlock();
        try vulkan.device.queueSubmit(vulkan.graphics_queue.handle, 1, @ptrCast(&submit_info), .null_handle);
        try vulkan.device.queueWaitIdle(vulkan.graphics_queue.handle);
    }

    const size = width * height * 4;
    const data = try vulkan.device.mapMemory(linear_memory, 0, size, .{});

    const pixel_data: [*]u8 = @ptrCast(data);

    std.debug.print("pixel data", .{});
    for (0..200) |i| {
        std.debug.print("{x}", .{pixel_data[i]});
    }
    try util.write_bmp_bgrx(vulkan.allocator, file_name, width, height, pixel_data[0..size]);

    return signal_semaphore;
}

pub fn debugBlitWriteImageToFile(
    vulkan: *Vulkan,
    image: vk.Image,
    format: vk.Format,
    fence: ?vk.Fence,
    width: u32,
    height: u32,
    file_name: []const u8,
    wait_semaphore: ?vk.Semaphore,
) !void {
    std.debug.print("\n\ndebugBlitWriteImageToFile\n\n", .{});
    if (fence != null) {
        const result = try vulkan.device.waitForFences(1, @ptrCast(&fence), vk.TRUE, std.math.maxInt(u64));
        if (result != .success) {
            return error.waitForFences;
        }
    }

    const linear_image_create_info = vk.ImageCreateInfo{
        .image_type = .@"2d",
        .format = format, // pass in your format (same as imported image)
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .linear,
        .usage = .{ .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };

    const linear_image = try vulkan.device.createImage(&linear_image_create_info, null);
    defer vulkan.device.destroyImage(linear_image, null);

    // 2. Allocate memory for linear image (must be HOST_VISIBLE!)
    const linear_mem_reqs = vulkan.device.getImageMemoryRequirements(linear_image);
    const linear_memory = try vulkan.allocate(
        linear_mem_reqs,
        .{ .host_visible_bit = true, .host_coherent_bit = true },
        null,
    );
    defer vulkan.device.freeMemory(linear_memory, null);

    try vulkan.device.bindImageMemory(linear_image, linear_memory, 0);

    const copy_cmd_alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = vulkan.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    var command_buffer: vk.CommandBuffer = undefined;
    try vulkan.device.allocateCommandBuffers(&copy_cmd_alloc_info, @ptrCast(&command_buffer));
    defer vulkan.device.freeCommandBuffers(vulkan.command_pool, 1, @ptrCast(&command_buffer));

    try vulkan.device.beginCommandBuffer(command_buffer, &.{});
    // 3. Barrier: imported image → transfer_src_optimal
    //    and linear image → transfer_dst_optimal

    const barriers = [_]vk.ImageMemoryBarrier2{
        vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{ .color_attachment_write_bit = true },
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .dst_access_mask = .{ .transfer_read_bit = true },
            .old_layout = .undefined,
            .new_layout = .transfer_src_optimal,
            .image = image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = 0,
            .dst_queue_family_index = 0,
        },
        vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .top_of_pipe_bit = true },
            .src_access_mask = .{},
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .image = linear_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = 0,
            .dst_queue_family_index = 0,
        },
    };

    const dep_info = vk.DependencyInfoKHR{
        .image_memory_barrier_count = barriers.len,
        .p_image_memory_barriers = &barriers,
    };

    vulkan.device.cmdPipelineBarrier2(command_buffer, &dep_info);

    const blit_region = vk.ImageBlit{
        .src_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_offsets = [2]vk.Offset3D{
            .{ .x = 0, .y = 0, .z = 0 },
            .{ .x = @intCast(width), .y = @intCast(height), .z = 1 },
        },
        .dst_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .dst_offsets = [2]vk.Offset3D{
            .{ .x = 0, .y = 0, .z = 0 },
            .{ .x = @intCast(width), .y = @intCast(height), .z = 1 },
        },
    };

    vulkan.device.cmdBlitImage(
        command_buffer,
        image,
        .transfer_src_optimal,
        linear_image,
        .transfer_dst_optimal,
        1,
        @ptrCast(&blit_region),
        .nearest,
    );

    // 5. Barrier: linear image → general (for CPU read)
    const read_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_transfer_bit = true },
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_stage_mask = .{ .host_bit = true },
        .dst_access_mask = .{ .host_read_bit = true },
        .old_layout = .transfer_dst_optimal,
        .new_layout = .general,
        .image = linear_image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };

    const read_dep_info = vk.DependencyInfoKHR{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&read_barrier),
    };

    vulkan.device.cmdPipelineBarrier2(command_buffer, &read_dep_info);

    try vulkan.device.endCommandBuffer(command_buffer);

    const wait_stage_mask = vk.PipelineStageFlags{ .all_commands_bit = true };
    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&command_buffer),
        .p_wait_semaphores = if (wait_semaphore != null) @ptrCast(&wait_semaphore) else null,
        .wait_semaphore_count = if (wait_semaphore != null) 1 else 0,
        .p_wait_dst_stage_mask = if (wait_semaphore != null) @ptrCast(&wait_stage_mask) else null,
    };

    try vulkan.device.queueSubmit(vulkan.graphics_queue.handle, 1, @ptrCast(&submit_info), .null_handle);
    try vulkan.device.queueWaitIdle(vulkan.graphics_queue.handle);

    const size = width * height * 4;
    const data = try vulkan.device.mapMemory(linear_memory, 0, size, .{});

    const pixel_data: [*]u8 = @ptrCast(data);

    std.debug.print("pixel data", .{});
    for (0..200) |i| {
        std.debug.print("{x}", .{pixel_data[i]});
    }
    try util.write_bmp_bgrx(vulkan.allocator, file_name, width, height, pixel_data[0..size]);
}

// Copy
// pub fn copyVulkanImage2(
//     self: *Self,
//     src_image: vk.Image,
//     width: u32,
//     height: u32,
//     wait_semaphore: vk.Semaphore,
// ) !struct {
//     semaphore: vk.Semaphore,
//     fence: vk.Fence,
//     image_view: vk.ImageView,
// } {
//     try self.vulkan.device.queueWaitIdle(self.vulkan.graphics_queue.handle);
//
//     if (self.fence == null) {
//         self.fence = try self.vulkan.device.createFence(&.{}, null);
//     }
//
//     self.destroyImage();
//     self.image = null;
//     if (self.image == null) {
//         try self.createImage(width, height);
//     }
//
//     try self.vulkan.device.resetFences(1, @ptrCast(&self.fence));
//
//     if (self.signal_semaphore) |signal_semaphore| {
//         self.vulkan.device.destroySemaphore(signal_semaphore, null);
//     }
//     self.signal_semaphore = try self.vulkan.device.createSemaphore(&.{}, null);
//
//     // Copy to your existing image
//     const cmd_alloc_info = vk.CommandBufferAllocateInfo{
//         .command_pool = self.vulkan.command_pool,
//         .level = .primary,
//         .command_buffer_count = 1,
//     };
//
//     var cmd_buffer: vk.CommandBuffer = undefined;
//     try self.vulkan.device.allocateCommandBuffers(&cmd_alloc_info, @ptrCast(&cmd_buffer));
//     defer self.vulkan.device.freeCommandBuffers(self.vulkan.command_pool, 1, @ptrCast(&cmd_buffer));
//
//     try self.vulkan.device.beginCommandBuffer(cmd_buffer, &.{});
//
//     // Alternative: Use GENERAL layout if you can't add TRANSFER_SRC_BIT
//     const external_acquire_barrier = vk.ImageMemoryBarrier{
//         .src_access_mask = .{}, // No prior access in this queue
//         .dst_access_mask = .{ .transfer_read_bit = true },
//         .old_layout = .undefined,
//         .new_layout = .general, // GENERAL layout works with any usage flags
//         .src_queue_family_index = vk.QUEUE_FAMILY_EXTERNAL,
//         .dst_queue_family_index = self.vulkan.graphics_queue.family, // Your graphics queue family index
//         .image = src_image,
//         .subresource_range = .{
//             .aspect_mask = .{ .color_bit = true },
//             .base_mip_level = 0,
//             .level_count = 1,
//             .base_array_layer = 0,
//             .layer_count = 1,
//         },
//     };
//
//     // Transition destination image to transfer destination layout
//     const dst_barrier = vk.ImageMemoryBarrier{
//         .src_access_mask = .{},
//         .dst_access_mask = .{ .transfer_write_bit = true },
//         .old_layout = .undefined,
//         .new_layout = .transfer_dst_optimal,
//         .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
//         .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
//         .image = self.image.?,
//         .subresource_range = .{
//             .aspect_mask = .{ .color_bit = true },
//             .base_mip_level = 0,
//             .level_count = 1,
//             .base_array_layer = 0,
//             .layer_count = 1,
//         },
//     };
//
//     const barriers = [_]vk.ImageMemoryBarrier{ external_acquire_barrier, dst_barrier };
//
//     // Use HOST_BIT because external memory operations might still be in flight
//     self.vulkan.device.cmdPipelineBarrier(
//         cmd_buffer,
//         .{ .host_bit = true }, // Wait for any external (CPU/other GPU) operations
//         .{ .transfer_bit = true },
//         .{}, // dependency_flags
//         0,
//         null, // memory barriers
//         0,
//         null, // buffer memory barriers
//         barriers.len,
//         &barriers, // image memory barriers
//     );
//
//     // Define the blit region (1:1 copy, no scaling)
//     const blit_region = vk.ImageBlit{
//         .src_subresource = .{
//             .aspect_mask = .{ .color_bit = true },
//             .mip_level = 0,
//             .base_array_layer = 0,
//             .layer_count = 1,
//         },
//         .src_offsets = [_]vk.Offset3D{
//             .{ .x = 0, .y = 0, .z = 0 },
//             .{ .x = @intCast(width), .y = @intCast(height), .z = 1 },
//         },
//         .dst_subresource = .{
//             .aspect_mask = .{ .color_bit = true },
//             .mip_level = 0,
//             .base_array_layer = 0,
//             .layer_count = 1,
//         },
//         .dst_offsets = [_]vk.Offset3D{
//             .{ .x = 0, .y = 0, .z = 0 },
//             .{ .x = @intCast(width), .y = @intCast(height), .z = 1 },
//         },
//     };
//
//     // Perform the blit (1:1 copy with no scaling)
//     self.vulkan.device.cmdBlitImage(cmd_buffer, src_image, .general, // Source can be in GENERAL layout
//         self.image.?, .transfer_dst_optimal, 1, @ptrCast(&blit_region), .nearest // Filter doesn't matter for 1:1 copy
//     );
//
//     // Transition destination image to shader read layout for ImGui
//     const final_barrier = vk.ImageMemoryBarrier{
//         .src_access_mask = .{ .transfer_write_bit = true },
//         .dst_access_mask = .{ .shader_read_bit = true },
//         .old_layout = .transfer_dst_optimal,
//         .new_layout = .shader_read_only_optimal,
//         .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
//         .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
//         .image = self.image.?,
//         .subresource_range = .{
//             .aspect_mask = .{ .color_bit = true },
//             .base_mip_level = 0,
//             .level_count = 1,
//             .base_array_layer = 0,
//             .layer_count = 1,
//         },
//     };
//
//     self.vulkan.device.cmdPipelineBarrier(
//         cmd_buffer,
//         .{ .transfer_bit = true },
//         .{ .fragment_shader_bit = true },
//         .{},
//         0,
//         null,
//         0,
//         null,
//         1,
//         @ptrCast(&final_barrier),
//     );
//
//     try self.vulkan.device.endCommandBuffer(cmd_buffer);
//
//     const dst_stage_mask = vk.PipelineStageFlags{
//         .transfer_bit = true,
//     };
//     const submit_info = vk.SubmitInfo{
//         .command_buffer_count = 1,
//         .p_command_buffers = @ptrCast(&cmd_buffer),
//         .p_wait_dst_stage_mask = @ptrCast(&dst_stage_mask),
//         .wait_semaphore_count = 1,
//         .p_wait_semaphores = @ptrCast(&wait_semaphore),
//         .signal_semaphore_count = 1,
//         .p_signal_semaphores = @ptrCast(&self.signal_semaphore.?),
//     };
//     self.vulkan.graphics_queue.mutex.lock();
//     defer self.vulkan.graphics_queue.mutex.unlock();
//     try self.vulkan.device.queueSubmit(
//         self.vulkan.graphics_queue.handle,
//         1,
//         @ptrCast(&submit_info),
//         self.fence.?,
//     );
//
//     try self.vulkan.device.queueWaitIdle(self.vulkan.graphics_queue.handle);
//
//     // self.signal_semaphore = if (write_i % 500 == 0) blk: {
//     //     const file_name = try std.fmt.allocPrint(std.heap.page_allocator, "tmp_{}.bmp", .{write_i});
//     //     defer std.heap.page_allocator.free(file_name);
//     //     const new_semaphore = try vkDebug.debugWriteImageToFile(
//     //         self.vulkan,
//     //         self.image.?,
//     //         self.fence.?,
//     //         width,
//     //         height,
//     //         file_name,
//     //         self.signal_semaphore.?,
//     //     );
//     //     break :blk new_semaphore;
//     // } else blk: {
//     //     break :blk self.signal_semaphore.?;
//     // };
//     // write_i += 1;
//
//     return .{
//         .semaphore = self.signal_semaphore.?,
//         .fence = self.fence.?,
//         .image_view = self.image_view.?,
//     };
// }
//
// pub fn createTestPattern(self: *Self, width: u32, height: u32) !struct {
//     semaphore: vk.Semaphore,
//     fence: vk.Fence,
//     image_view: vk.ImageView,
// } {
//     try self.vulkan.device.queueWaitIdle(self.vulkan.graphics_queue.handle);
//
//     // Initialize fence and semaphore if needed
//     if (self.fence == null) {
//         self.fence = try self.vulkan.device.createFence(&.{}, null);
//     }
//
//     self.destroyImage();
//     self.image = null;
//     if (self.image == null) {
//         try self.createImage(width, height);
//     }
//
//     try self.vulkan.device.resetFences(1, @ptrCast(&self.fence));
//
//     if (self.signal_semaphore) |signal_semaphore| {
//         self.vulkan.device.destroySemaphore(signal_semaphore, null);
//     }
//     self.signal_semaphore = try self.vulkan.device.createSemaphore(&.{}, null);
//
//     // Create staging buffer
//     const buffer_size = width * height * 4;
//     const buffer_create_info = vk.BufferCreateInfo{
//         .size = buffer_size,
//         .usage = .{ .transfer_src_bit = true },
//         .sharing_mode = .exclusive,
//     };
//
//     const staging_buffer = try self.vulkan.device.createBuffer(&buffer_create_info, null);
//     defer self.vulkan.device.destroyBuffer(staging_buffer, null);
//
//     const mem_reqs = self.vulkan.device.getBufferMemoryRequirements(staging_buffer);
//     const staging_memory = try self.vulkan.allocate(
//         mem_reqs,
//         .{ .host_visible_bit = true, .host_coherent_bit = true },
//         null,
//     );
//     defer self.vulkan.device.freeMemory(staging_memory, null);
//
//     try self.vulkan.device.bindBufferMemory(staging_buffer, staging_memory, 0);
//
//     // Create a simple test pattern - solid red
//     const data = try self.vulkan.device.mapMemory(staging_memory, 0, buffer_size, .{});
//     const pixels: [*]u8 = @ptrCast(data);
//
//     var prng = std.Random.DefaultPrng.init(blk: {
//         var seed: u64 = undefined;
//         try std.posix.getrandom(std.mem.asBytes(&seed));
//         break :blk seed;
//     });
//     const rand = prng.random();
//
//     // Fill with solid red (RGBA format)
//     for (0..width * height) |i| {
//         pixels[i * 4 + 0] = @intFromFloat(255 * rand.float(f32)); // R
//         pixels[i * 4 + 1] = @intFromFloat(255 * rand.float(f32)); // G
//         pixels[i * 4 + 2] = @intFromFloat(255 * rand.float(f32)); // B
//         pixels[i * 4 + 3] = 255; // A
//     }
//
//     self.vulkan.device.unmapMemory(staging_memory);
//
//     // Copy to your existing image
//     const cmd_alloc_info = vk.CommandBufferAllocateInfo{
//         .command_pool = self.vulkan.command_pool,
//         .level = .primary,
//         .command_buffer_count = 1,
//     };
//
//     var cmd_buffer: vk.CommandBuffer = undefined;
//     try self.vulkan.device.allocateCommandBuffers(&cmd_alloc_info, @ptrCast(&cmd_buffer));
//     defer self.vulkan.device.freeCommandBuffers(self.vulkan.command_pool, 1, @ptrCast(&cmd_buffer));
//
//     try self.vulkan.device.beginCommandBuffer(cmd_buffer, &.{});
//
//     // Transition image to transfer dst
//     const dst_barrier = vk.ImageMemoryBarrier2{
//         .src_stage_mask = .{ .top_of_pipe_bit = true },
//         .src_access_mask = .{},
//         .dst_stage_mask = .{ .all_transfer_bit = true },
//         .dst_access_mask = .{ .transfer_write_bit = true },
//         .old_layout = .undefined,
//         .new_layout = .transfer_dst_optimal,
//         .src_queue_family_index = self.vulkan.graphics_queue.family,
//         .dst_queue_family_index = self.vulkan.graphics_queue.family,
//         .image = self.image.?,
//         .subresource_range = .{
//             .aspect_mask = .{ .color_bit = true },
//             .base_mip_level = 0,
//             .level_count = 1,
//             .base_array_layer = 0,
//             .layer_count = 1,
//         },
//     };
//
//     const dst_dep_info = vk.DependencyInfoKHR{
//         .image_memory_barrier_count = 1,
//         .p_image_memory_barriers = @ptrCast(&dst_barrier),
//     };
//
//     self.vulkan.device.cmdPipelineBarrier2(cmd_buffer, &dst_dep_info);
//
//     // Copy buffer to image
//     const copy_region = vk.BufferImageCopy{
//         .buffer_offset = 0,
//         .buffer_row_length = 0,
//         .buffer_image_height = 0,
//         .image_subresource = .{
//             .aspect_mask = .{ .color_bit = true },
//             .mip_level = 0,
//             .base_array_layer = 0,
//             .layer_count = 1,
//         },
//         .image_offset = .{ .x = 0, .y = 0, .z = 0 },
//         .image_extent = .{ .width = width, .height = height, .depth = 1 },
//     };
//
//     self.vulkan.device.cmdCopyBufferToImage(
//         cmd_buffer,
//         staging_buffer,
//         self.image.?,
//         .transfer_dst_optimal,
//         1,
//         @ptrCast(&copy_region),
//     );
//
//     // Transition to shader read only
//     const shader_barrier = vk.ImageMemoryBarrier2{
//         .src_stage_mask = .{ .all_transfer_bit = true },
//         .src_access_mask = .{ .transfer_write_bit = true },
//         .dst_stage_mask = .{ .fragment_shader_bit = true },
//         .dst_access_mask = .{ .shader_read_bit = true },
//         .old_layout = .transfer_dst_optimal,
//         .new_layout = .shader_read_only_optimal,
//         .src_queue_family_index = self.vulkan.graphics_queue.family,
//         .dst_queue_family_index = self.vulkan.graphics_queue.family,
//         .image = self.image.?,
//         .subresource_range = dst_barrier.subresource_range,
//     };
//
//     const shader_dep_info = vk.DependencyInfoKHR{
//         .image_memory_barrier_count = 1,
//         .p_image_memory_barriers = @ptrCast(&shader_barrier),
//     };
//
//     self.vulkan.device.cmdPipelineBarrier2(cmd_buffer, &shader_dep_info);
//
//     try self.vulkan.device.endCommandBuffer(cmd_buffer);
//
//     // Submit with fence and semaphore for consistency
//     const submit_info = vk.SubmitInfo{
//         .command_buffer_count = 1,
//         .p_command_buffers = @ptrCast(&cmd_buffer),
//         .signal_semaphore_count = 1,
//         .p_signal_semaphores = @ptrCast(&self.signal_semaphore.?),
//     };
//
//     self.vulkan.graphics_queue.mutex.lock();
//     defer self.vulkan.graphics_queue.mutex.unlock();
//     try self.vulkan.device.queueSubmit(self.vulkan.graphics_queue.handle, 1, @ptrCast(&submit_info), self.fence.?);
//     try self.vulkan.device.queueWaitIdle(self.vulkan.graphics_queue.handle);
//
//     return .{
//         .semaphore = self.signal_semaphore.?,
//         .fence = self.fence.?,
//         .image_view = self.image_view.?,
//     };
// }
