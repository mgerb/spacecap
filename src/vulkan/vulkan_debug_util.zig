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
) !void {
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
    const data = try vulkan.device.mapMemory(memory, 0, size, .{});

    const pixel_data: [*]u8 = @ptrCast(data);

    try util.write_bmp_bgrx(vulkan.allocator, file_name, width, height, pixel_data[0..size]);
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
) !void {
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
