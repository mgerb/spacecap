const std = @import("std");
const assert = std.debug.assert;

const imguiz = @import("imguiz").imguiz;
const vk = @import("vulkan");
const util = @import("../util.zig");
const Encoder = @import("./video_encoder.zig").VideoEncoder;
const EncodeResult = @import("./video_encoder.zig").EncodeResult;
const VulkanImageRingBuffer = @import("./vulkan_image_ring_buffer.zig").VulkanImageRingBuffer;
const VulkanImageBuffer = @import("./vulkan_image_buffer.zig").VulkanImageBuffer;
const CapturePreviewTexture = @import("./capture_preview_texture.zig").CapturePreviewTexture;
const rc = @import("zigrc");
const Mutex = @import("../mutex.zig").Mutex;

const BaseDispatch = vk.BaseWrapper;
const InstanceDispatch = vk.InstanceWrapper;
const DeviceDispatch = vk.DeviceWrapper;
pub const Instance = vk.InstanceProxy;
pub const Device = vk.DeviceProxy;
pub const CommandBuffer = vk.CommandBufferProxy;
pub const API_VERSION = vk.API_VERSION_1_4;

const DEBUG = @import("builtin").mode == .Debug;

const INSTANCE_EXTENSIONS = [_][*:0]const u8{
    vk.extensions.khr_get_physical_device_properties_2.name,
};

const DEVICE_EXTENSIONS = [_][*:0]const u8{
    vk.extensions.khr_dynamic_rendering.name,
    vk.extensions.khr_synchronization_2.name,
    vk.extensions.khr_swapchain.name,
};

const DEVICE_VIDEO_EXTENSIONS = blk: {
    const base_device_extensions = [_][*:0]const u8{
        vk.extensions.khr_video_queue.name,
        vk.extensions.khr_video_encode_queue.name,
        vk.extensions.khr_video_encode_h_264.name,
    };

    // linux specific device extensions
    if (util.isLinux()) {
        break :blk base_device_extensions ++ .{
            vk.extensions.ext_image_drm_format_modifier.name,
            vk.extensions.khr_external_memory.name,
            vk.extensions.khr_external_memory_fd.name,
            vk.extensions.ext_external_memory_dma_buf.name,
            vk.extensions.khr_external_semaphore_fd.name,
            vk.extensions.khr_sampler_ycbcr_conversion.name,
        };
    }

    // windows specific device extensions
    if (util.isWindows()) {
        break :blk base_device_extensions ++ .{};
    }

    break :blk base_device_extensions;
};

// C vulkan libs
pub extern fn vkGetInstanceProcAddr(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;

const QueueAllocation = struct {
    graphics_family: u32,
    /// Could be null on machines that don't support Vulkan video.
    video_encode_family: ?u32,
};

pub const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
    video_extensions_supported: bool,
};

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,
    mutex: std.Thread.Mutex = .{},

    pub fn init(device: Device, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

pub const Vulkan = struct {
    const log = std.log.scoped(.Vulkan);
    const Self = @This();
    allocator: std.mem.Allocator,
    vkb: BaseDispatch,
    instance: Instance,
    device: Device,
    debug_messenger: ?vk.DebugUtilsMessengerEXT,
    graphics_queue: Queue,
    video_encode_queue: ?Queue,
    physical_device: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    video_encoder: ?*Encoder = null,
    /// Ring buffer that holds the preview images that are rendered on the UI.
    capture_preview_ring_buffer: ?*VulkanImageRingBuffer = null,
    /// We need to create textures to render the capture preview.
    /// They will be stored here so that we don't couple the UI
    /// to the vulkan image ring buffer.
    capture_preview_textures: std.AutoHashMap(*VulkanImageBuffer, CapturePreviewTexture),
    /// Ring buffer that can be used in the capture method to hold frames
    /// in which the encoded can grab from.
    capture_ring_buffer: Mutex(?*VulkanImageRingBuffer) = .init(null),

    /// The window used to render the UI with imgui
    window: ?imguiz.ImGui_ImplVulkanH_Window = null,

    pub fn init(
        allocator: std.mem.Allocator,
        extra_instance_extensions: ?[][*:0]const u8,
    ) !*Self {
        if (extra_instance_extensions) |e| {
            for (e) |ee| {
                log.debug("[init] extra_instance_extension: {s}", .{ee});
            }
        }
        const vkbd = BaseDispatch.load(vkGetInstanceProcAddr);

        const app_info: vk.ApplicationInfo = .{
            .p_application_name = "Spacecap",
            .application_version = @bitCast(API_VERSION),
            .p_engine_name = "Spacecap",
            .engine_version = @bitCast(API_VERSION),
            .api_version = @bitCast(API_VERSION),
        };

        var extension_names = try std.ArrayList([*:0]const u8).initCapacity(allocator, 0);
        defer extension_names.deinit(allocator);

        try extension_names.appendSlice(allocator, &INSTANCE_EXTENSIONS);

        if (extra_instance_extensions) |extensions| {
            for (extensions) |extension| {
                try extension_names.append(allocator, std.mem.span(extension));
            }
        }

        // TODO: might want to check for more extensions to
        // enable with vkEnumerateInstanceExtensionProperties.
        // See imgui example_sdl3_vulkan for reference.

        if (DEBUG) {
            try extension_names.append(allocator, vk.extensions.ext_debug_utils.name);
            // TODO: check if this extension is enabled
            //try extension_names.append(vk.extensions.ext_device_address_binding_report.name);
            // try extension_names.append(vk.extensions.ext_debug_report.name);
        }

        const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
        const enabled_layers: []const [*:0]const u8 = if (DEBUG) &validation_layers else &.{};

        const instance_def = try vkbd.createInstance(&.{
            .p_application_info = &app_info,

            .enabled_extension_count = @intCast(extension_names.items.len),
            .pp_enabled_extension_names = extension_names.items.ptr,

            .enabled_layer_count = @intCast(enabled_layers.len),
            .pp_enabled_layer_names = enabled_layers.ptr,
        }, null);

        const vki = try allocator.create(InstanceDispatch);
        errdefer allocator.destroy(vki);
        vki.* = InstanceDispatch.load(instance_def, vkbd.dispatch.vkGetInstanceProcAddr.?);
        const instance = Instance.init(instance_def, vki);
        errdefer instance.destroyInstance(null);

        var debug_messenger: ?vk.DebugUtilsMessengerEXT = null;

        if (DEBUG) {
            debug_messenger = try instance.createDebugUtilsMessengerEXT(&.{
                .message_severity = .{
                    .error_bit_ext = true,
                    .warning_bit_ext = true,
                },
                .message_type = .{
                    .general_bit_ext = true,
                    .validation_bit_ext = true,
                    .performance_bit_ext = true,
                    .device_address_binding_bit_ext = false,
                },
                .pfn_user_callback = debugCallback,
            }, null);
        }
        errdefer {
            if (debug_messenger) |dm| {
                instance.destroyDebugUtilsMessengerEXT(dm, null);
            }
        }

        const candidate = try pickPhysicalDevice(instance, allocator);

        const pdev = candidate.pdev;
        const props = candidate.props;
        const mem_props = instance.getPhysicalDeviceMemoryProperties(pdev);

        const device_candidate = try initializeCandidate(allocator, instance, candidate);
        const vkd = try allocator.create(DeviceDispatch);
        errdefer allocator.destroy(vkd);
        vkd.* = DeviceDispatch.load(device_candidate, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
        const device = Device.init(device_candidate, vkd);
        errdefer device.destroyDevice(null);

        const graphics_queue = Queue.init(device, candidate.queues.graphics_family);
        const video_encode_queue = if (candidate.queues.video_encode_family != null)
            Queue.init(device, candidate.queues.video_encode_family.?)
        else
            null;

        // We use an allocator here because we don't want the
        // reference to change when we return this object.
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = Self{
            .allocator = allocator,
            .vkb = vkbd,
            .instance = instance,
            .debug_messenger = debug_messenger,
            .device = device,
            .graphics_queue = graphics_queue,
            .video_encode_queue = video_encode_queue,
            .physical_device = pdev,
            .props = props,
            .mem_props = mem_props,
            .capture_preview_textures = .init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.destroyVideoEncoder();
        self.destroyCapturePreviewRingBuffer() catch |err| {
            log.err("[deinit] failed to destroy capture preview ring buffer: {}", .{err});
        };
        self.destroyCaptureRingBuffer();
        self.capture_preview_textures.deinit();

        if (self.debug_messenger) |debug_messenger| {
            self.instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);
        }

        self.device.destroyDevice(null);
        self.instance.destroyInstance(null);

        self.allocator.destroy(self.device.wrapper);
        self.allocator.destroy(self.instance.wrapper);
        self.allocator.destroy(self);
    }

    pub fn initVideoEncoder(
        self: *Self,
        width: u32,
        height: u32,
        fps: u32,
        bit_rate: u64,
    ) !void {
        if (self.video_encode_queue == null) {
            return error.video_not_supported;
        }

        self.video_encoder = try Encoder.init(
            self.allocator,
            self,
            width,
            height,
            fps,
            bit_rate,
        );
    }

    pub fn destroyVideoEncoder(self: *Self) void {
        if (self.video_encoder) |encoder| {
            encoder.deinit();
            self.video_encoder = null;
        }
    }

    pub fn getCapturePreviewTexture(self: *Self, vulkan_image_buffer: *VulkanImageBuffer) !*CapturePreviewTexture {
        if (self.capture_preview_textures.getPtr(vulkan_image_buffer)) |capture_preview_texture| {
            return capture_preview_texture;
        } else {
            const capture_preview_texture = try CapturePreviewTexture.init(self, vulkan_image_buffer.image_view);
            try self.capture_preview_textures.put(vulkan_image_buffer, capture_preview_texture);
            return self.capture_preview_textures.getPtr(vulkan_image_buffer).?;
        }
    }

    fn clearCapturePreviewTextures(self: *Self) void {
        var iter = self.capture_preview_textures.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.capture_preview_textures.clearRetainingCapacity();
    }

    pub fn initCapturePreviewRingBuffer(self: *Self, width: u32, height: u32) !void {
        self.capture_preview_ring_buffer = try VulkanImageRingBuffer.init(
            .{
                .allocator = self.allocator,
                .vulkan = self,
                .dst_access_mask = .{ .shader_read_bit = true },
                .dst_stage_mask = .{ .fragment_shader_bit = true },
                .image_component_mapping = .{
                    .r = .b,
                    .g = .identity,
                    .b = .r,
                    .a = .one,
                },
                .image_layout = .shader_read_only_optimal,
                .width = width,
                .height = height,
                .usage = .{ .sampled_bit = true },
                .src_queue_family_index = self.graphics_queue.family,
            },
        );
    }

    /// Destroy the ring buffer, but also clear the capture preview textures.
    pub fn destroyCapturePreviewRingBuffer(self: *Self) !void {
        try self.waitForUIFences();
        if (self.capture_preview_ring_buffer) |capture_preview_ring_buffer| {
            capture_preview_ring_buffer.deinit();
            self.capture_preview_ring_buffer = null;
        }
        self.clearCapturePreviewTextures();
    }

    pub fn initCaptureRingBuffer(self: *Self, width: u32, height: u32) !void {
        self.capture_ring_buffer.set(try VulkanImageRingBuffer.init(
            .{
                .allocator = self.allocator,
                .vulkan = self,
                .dst_access_mask = .{ .transfer_write_bit = true },
                .dst_stage_mask = .{ .all_transfer_bit = true },
                .image_layout = .color_attachment_optimal,
                .image_component_mapping = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .width = width,
                .height = height,
                .usage = .{ .storage_bit = true, .transfer_src_bit = true, .color_attachment_bit = true },
                .src_queue_family_index = vk.QUEUE_FAMILY_EXTERNAL,
            },
        ));
    }

    pub fn destroyCaptureRingBuffer(self: *Self) void {
        const capture_ring_buffer_locked = self.capture_ring_buffer.lock();
        defer capture_ring_buffer_locked.unlock();
        if (capture_ring_buffer_locked.unwrap()) |capture_ring_buffer| {
            capture_ring_buffer.deinit();
        }
        capture_ring_buffer_locked.unwrapPtr().* = null;
    }

    /// Caller owns the memory - must free
    pub fn queryFormatModifiers(self: *const Self, format: vk.Format) !std.ArrayList(u64) {
        var modifiers_list = vk.DrmFormatModifierPropertiesListEXT{};
        var props = vk.FormatProperties2{
            .p_next = @ptrCast(&modifiers_list),
            .format_properties = .{},
        };

        self.instance.getPhysicalDeviceFormatProperties2KHR(self.physical_device, format, &props);

        const format_mod_props = try self.allocator.alloc(vk.DrmFormatModifierPropertiesEXT, modifiers_list.drm_format_modifier_count);
        defer self.allocator.free(format_mod_props);

        modifiers_list.p_drm_format_modifier_properties = format_mod_props.ptr;

        self.instance.getPhysicalDeviceFormatProperties2KHR(self.physical_device, format, &props);

        var modifiers = try std.ArrayList(u64).initCapacity(self.allocator, 0);

        for (format_mod_props) |modifier| {
            try modifiers.append(self.allocator, modifier.drm_format_modifier);
        }

        return modifiers;
    }

    fn pickPhysicalDevice(
        instance: Instance,
        allocator: std.mem.Allocator,
    ) !DeviceCandidate {
        const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
        defer allocator.free(pdevs);

        var best_candidate: ?DeviceCandidate = null;
        var best_score: u32 = 0;

        for (pdevs) |pdev| {
            if (try checkSuitable(instance, pdev, allocator)) |candidate| {
                const score = deviceScore(candidate.props, candidate.queues);
                if (best_candidate == null or score > best_score) {
                    best_candidate = candidate;
                    best_score = score;
                }
            }
        }

        if (best_candidate == null) {
            return error.NoSuitableDevice;
        }

        const device = best_candidate.?;

        log.info("[pickPhysicalDevice] using device: {s}", .{device.props.device_name});

        return device;
    }

    /// Simple score function to determine what GPU to auto select based on its capabilties.
    /// Prefer devices that support Vulkan video encoding above all, because the app doesn't
    /// work otherwise.
    fn deviceScore(props: vk.PhysicalDeviceProperties, queues: QueueAllocation) u32 {
        var score: u32 = 0;

        if (queues.video_encode_family != null) {
            score += 10;
        }

        switch (props.device_type) {
            .discrete_gpu => score += 3,
            .integrated_gpu => score += 2,
            .virtual_gpu => score += 1,
            else => {},
        }

        return score;
    }

    fn checkSuitable(
        instance: Instance,
        pdev: vk.PhysicalDevice,
        allocator: std.mem.Allocator,
    ) !?DeviceCandidate {
        const props = instance.getPhysicalDeviceProperties(pdev);
        log.debug("[checkSuitable] checking potential device: {s}, device type: {}", .{ props.device_name, props.device_type });

        if (!try checkDeviceExtensionSupport(.device, instance, pdev, allocator)) {
            return null;
        }

        if (try initQueues(instance, pdev, allocator)) |allocation| {
            return DeviceCandidate{
                .pdev = pdev,
                .props = props,
                .queues = allocation,
                .video_extensions_supported = try checkDeviceExtensionSupport(.video, instance, pdev, allocator),
            };
        }

        return null;
    }

    fn checkDeviceExtensionSupport(
        extension_type: enum { device, video },
        instance: Instance,
        pdev: vk.PhysicalDevice,
        allocator: std.mem.Allocator,
    ) !bool {
        var supported = true;
        // TODO: Combine these branches.
        switch (extension_type) {
            .device => {
                // Loop through all extensions so that we can log all the unsupported ones.
                for (DEVICE_EXTENSIONS) |extension| {
                    if (!try extensionSupported(instance, pdev, allocator, extension)) {
                        log.info("[extensionEnabled] extension is not supported on device: {s}", .{extension});
                        supported = false;
                    }
                }
            },
            .video => {
                // Loop through all extensions so that we can log all the unsupported ones.
                for (DEVICE_VIDEO_EXTENSIONS) |extension| {
                    if (!try extensionSupported(instance, pdev, allocator, extension)) {
                        log.info("[extensionEnabled] extension is not supported on device: {s}", .{extension});
                        supported = false;
                    }
                }
            },
        }

        return supported;
    }

    fn extensionSupported(
        instance: Instance,
        pdev: vk.PhysicalDevice,
        allocator: std.mem.Allocator,
        extension: [*:0]const u8,
    ) !bool {
        // TODO: change this so that we can query enabled extensions without an instance created yet
        const propsv = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
        defer allocator.free(propsv);
        for (propsv) |props| {
            if (std.mem.eql(u8, std.mem.span(extension), std.mem.sliceTo(&props.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
        return true;
    }

    /// Does not actually allocate anything in Vulkan. It just gets the queue family indexes.
    fn initQueues(
        instance: Instance,
        pdev: vk.PhysicalDevice,
        allocator: std.mem.Allocator,
    ) !?QueueAllocation {
        const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
        defer allocator.free(families);

        var graphics_family: ?u32 = null;
        var video_encode_family: ?u32 = null;

        for (families, 0..) |properties, i| {
            const family: u32 = @intCast(i);

            if (graphics_family == null and properties.queue_flags.graphics_bit) {
                graphics_family = family;
            }

            if (video_encode_family == null and properties.queue_flags.video_encode_bit_khr) {
                video_encode_family = family;
            }
        }

        if (graphics_family != null) {
            return QueueAllocation{
                .graphics_family = graphics_family.?,
                .video_encode_family = video_encode_family,
            };
        }

        return null;
    }

    /// - create device
    /// - add device extensions
    /// - add device queues
    fn initializeCandidate(allocator: std.mem.Allocator, instance: Instance, candidate: DeviceCandidate) !vk.Device {
        const priority = [_]f32{1};
        var qci = try std.ArrayList(vk.DeviceQueueCreateInfo).initCapacity(allocator, 1);
        defer qci.deinit(allocator);

        try qci.append(allocator, .{
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        });

        if (candidate.queues.video_encode_family) |video_encode_family| {
            if (video_encode_family != candidate.queues.graphics_family) {
                try qci.append(allocator, .{
                    .queue_family_index = video_encode_family,
                    .queue_count = 1,
                    .p_queue_priorities = &priority,
                });
            }
        }

        const synchronization2_features = vk.PhysicalDeviceSynchronization2Features{
            .synchronization_2 = .true,
        };

        const dynamic_rendering_features = vk.PhysicalDeviceDynamicRenderingFeaturesKHR{
            .p_next = @ptrCast(@constCast(&synchronization2_features)),
            .dynamic_rendering = .true,
        };

        var enabled_extensions = try std.ArrayList([*:0]const u8).initCapacity(allocator, 2);
        defer enabled_extensions.deinit(allocator);

        try enabled_extensions.appendSlice(allocator, DEVICE_EXTENSIONS[0..]);

        if (candidate.video_extensions_supported) {
            try enabled_extensions.appendSlice(allocator, DEVICE_VIDEO_EXTENSIONS[0..]);
        }

        return try instance.createDevice(candidate.pdev, &.{
            .p_next = &dynamic_rendering_features,
            .queue_create_info_count = @intCast(qci.items.len),
            .p_queue_create_infos = qci.items.ptr,
            .enabled_extension_count = @intCast(enabled_extensions.items.len),
            .pp_enabled_extension_names = enabled_extensions.items.ptr,
        }, null);
    }

    fn debugCallback(
        message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
        message_types: vk.DebugUtilsMessageTypeFlagsEXT,
        p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
        p_user_data: ?*anyopaque,
    ) callconv(vk.vulkan_call_conv) vk.Bool32 {
        _ = message_severity;
        _ = message_types;
        _ = p_user_data;
        b: {
            const msg = (p_callback_data orelse break :b).p_message orelse break :b;
            log.warn("[debugCallback] {s}", .{msg});

            return .false;
        }
        log.warn("[debugCallback] unrecognized validation layer debug message", .{});
        return .true;
    }

    pub fn allocate(
        self: *Self,
        requirements: vk.MemoryRequirements,
        flags: vk.MemoryPropertyFlags,
        p_next: ?*anyopaque,
    ) !vk.DeviceMemory {
        return try self.device.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
            .p_next = p_next,
        }, null);
    }

    pub fn findMemoryTypeIndex(self: *Self, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
            if (memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
                return @truncate(i);
            }
        }

        return error.NoSuitableMemoryType;
    }

    /// Thread safe queue submit.
    /// - locks queue mutex
    /// - resets fence if not null
    /// - submits queue
    pub fn queueSubmit(
        self: *Self,
        queue: enum { graphics, encode },
        submit_info: []const vk.SubmitInfo,
        args: struct {
            fence: vk.Fence = .null_handle,
        },
    ) !void {
        const _queue: ?*Queue = switch (queue) {
            // NOTE: Queues must be referenced. Mutexes cannot be copied.
            .graphics => &self.graphics_queue,
            .encode => if (self.video_encode_queue != null) &self.video_encode_queue.? else null,
        };

        // It should never get to this point. The caller of this function should always have valid queues.
        assert(_queue != null);

        _queue.?.mutex.lock();
        defer _queue.?.mutex.unlock();
        if (args.fence != .null_handle) {
            try self.device.resetFences(1, @ptrCast(&args.fence));
        }
        try self.device.queueSubmit(_queue.?.handle, @intCast(submit_info.len), submit_info.ptr, args.fence);
    }

    /// Lock graphics mutex and present.
    pub fn queuePresentKHR(self: *Self, present_info: *const vk.PresentInfoKHR) !void {
        self.graphics_queue.mutex.lock();
        defer self.graphics_queue.mutex.unlock();
        _ = try self.device.queuePresentKHR(self.graphics_queue.handle, present_info);
    }

    /// Wait for all fences on the imgui Vulkan window.
    pub fn waitForUIFences(self: *Self) !void {
        if (self.window) |window| {
            for (0..@intCast(window.Frames.Size)) |i| {
                const fd = window.Frames.Data[i];
                _ = try self.device.waitForFences(1, @ptrCast(&fd.Fence), .true, std.math.maxInt(u64));
            }
        }
    }

    /// This will lock both queues (graphics, encode), and
    /// then wait for all valid fences.
    ///
    /// WARNING: Must be followed up by `waitForAllFencesEnd` to unlock mutexes.
    pub fn waitForAllFencesBegin(self: *Self) !void {
        self.graphics_queue.mutex.lock();
        if (self.video_encode_queue) |*video_encode_queue| {
            video_encode_queue.mutex.lock();
        }

        var wait_fences = try std.ArrayList(vk.Fence).initCapacity(self.allocator, 0);
        defer wait_fences.deinit(self.allocator);

        if (self.video_encoder) |encoder| {
            try wait_fences.appendSlice(self.allocator, &.{
                encoder.compute_finished_fence,
                encoder.encode_finished_fence,
            });
        }

        if (self.capture_preview_ring_buffer) |capture_preview_ring_buffer| {
            for (capture_preview_ring_buffer.buffers) |buffer| {
                try wait_fences.append(self.allocator, buffer.value.*.fence);
            }
        }

        // TODO: This causes a deadlock when the window is resized. We may not need
        // this here actually...
        // {
        //     const capture_ring_buffer_locked = self.capture_ring_buffer.lock();
        //     defer capture_ring_buffer_locked.unlock();
        //     if (capture_ring_buffer_locked.unwrap()) |capture_ring_buffer| {
        //         for (capture_ring_buffer.buffers) |buffer| {
        //             try wait_fences.append(self.allocator, buffer.value.*.fence);
        //         }
        //     }
        // }

        if (self.window) |window| {
            const fd = &window.Frames.Data[window.FrameIndex];
            try wait_fences.append(self.allocator, @enumFromInt(@intFromPtr(fd.Fence)));
        }

        _ = try self.device.waitForFences(
            @intCast(wait_fences.items.len),
            wait_fences.items.ptr,
            .true,
            std.math.maxInt(u64),
        );
    }

    pub fn waitForAllFencesEnd(self: *Self) void {
        self.graphics_queue.mutex.unlock();
        if (self.video_encode_queue) |*video_encode_queue| {
            video_encode_queue.mutex.unlock();
        }
    }

    /// Copy a vulkan image on the GPU.
    /// NOTE: This is only for the graphics queue.
    pub fn copyImage(
        self: *Self,
        command_buffer: vk.CommandBuffer,
        src_image: vk.Image,
        dst_image: vk.Image,
        src_width: u32,
        src_height: u32,
        dst_width: u32,
        dst_height: u32,
        args: struct {
            new_layout: vk.ImageLayout,
            dst_stage_mask: vk.PipelineStageFlags2,
            dst_access_mask: vk.AccessFlags2,
            src_queue_family_index: u32,
            wait_semaphores: []vk.Semaphore = &.{},
            signal_semaphores: []vk.Semaphore = &.{},
            fence: vk.Fence = .null_handle,
        },
    ) !void {
        try self.device.beginCommandBuffer(command_buffer, &.{});

        const src_barrier = vk.ImageMemoryBarrier2{
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .dst_access_mask = .{ .transfer_read_bit = true },
            .old_layout = .color_attachment_optimal,
            .new_layout = .transfer_src_optimal,
            .src_queue_family_index = args.src_queue_family_index,
            .dst_queue_family_index = self.graphics_queue.family,
            .image = src_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const initial_dep_info = vk.DependencyInfoKHR{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&src_barrier),
        };
        self.device.cmdPipelineBarrier2(command_buffer, &initial_dep_info);

        const dst_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{},
            .src_access_mask = .{},
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = dst_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const dst_dep_info = vk.DependencyInfoKHR{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&dst_barrier),
        };

        self.device.cmdPipelineBarrier2(command_buffer, &dst_dep_info);

        // Clear the image, otherwise if the window resizes smaller, the
        // background will have the previous frames.
        const clear_value = vk.ClearColorValue{ .float_32 = .{ 0, 0, 0, 1 } };
        const clear_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        self.device.cmdClearColorImage(
            command_buffer,
            dst_image,
            .transfer_dst_optimal,
            &clear_value,
            1,
            @ptrCast(&clear_range),
        );

        const copy_width = @min(dst_width, src_width);
        const copy_height = @min(dst_height, src_height);

        const copy_region = vk.ImageCopy{
            .src_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .src_offset = .{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
            .extent = .{ .width = copy_width, .height = copy_height, .depth = 1 },
        };

        self.device.cmdCopyImage(
            command_buffer,
            src_image,
            .transfer_src_optimal,
            dst_image,
            .transfer_dst_optimal,
            1,
            @ptrCast(&copy_region),
        );

        // Transfer the source image back to its original layout.
        const src_restore_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .transfer_read_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_access_mask = .{ .color_attachment_write_bit = true },
            .old_layout = .transfer_src_optimal,
            .new_layout = .color_attachment_optimal,
            .src_queue_family_index = args.src_queue_family_index,
            .dst_queue_family_index = self.graphics_queue.family,
            .image = src_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const src_restore_dep_info = vk.DependencyInfoKHR{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&src_restore_barrier),
        };

        self.device.cmdPipelineBarrier2(command_buffer, &src_restore_dep_info);

        const post_copy_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = args.dst_stage_mask,
            .dst_access_mask = args.dst_access_mask,
            .old_layout = .transfer_dst_optimal,
            .new_layout = args.new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = dst_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const shader_dep_info = vk.DependencyInfoKHR{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&post_copy_barrier),
        };

        self.device.cmdPipelineBarrier2(command_buffer, &shader_dep_info);

        try self.device.endCommandBuffer(command_buffer);

        const dst_stage_mask = vk.PipelineStageFlags{
            .transfer_bit = true,
        };
        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .p_wait_dst_stage_mask = @ptrCast(&dst_stage_mask),
            .p_wait_semaphores = args.wait_semaphores.ptr,
            .wait_semaphore_count = @intCast(args.wait_semaphores.len),
            .p_signal_semaphores = args.signal_semaphores.ptr,
            .signal_semaphore_count = @intCast(args.signal_semaphores.len),
        };

        try self.queueSubmit(.graphics, &.{submit_info}, .{ .fence = args.fence });
    }
};
