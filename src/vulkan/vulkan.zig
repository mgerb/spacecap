const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const imguiz = @import("imguiz").imguiz;
const vk = @import("vulkan");
const util = @import("../util.zig");
const VulkanVideoEncoder = @import("../video/vulkan_video_encoder.zig").VulkanVideoEncoder;
const VulkanImageRingBuffer = @import("./vulkan_image_ring_buffer.zig").VulkanImageRingBuffer;
const Mutex = @import("../mutex.zig").Mutex;

const BaseDispatch = vk.BaseWrapper;
const InstanceDispatch = vk.InstanceWrapper;
const DeviceDispatch = vk.DeviceWrapper;
pub const Instance = vk.InstanceProxy;
pub const Device = vk.DeviceProxy;
pub const CommandBuffer = vk.CommandBufferProxy;
pub const API_VERSION = vk.API_VERSION_1_4;

const IGNORED_DEBUG_MESSAGE_IDS = [_][]const u8{
    // FFmpeg related issues - check these after updating FFmpeg
    "VUID-VkImageCreateInfo-pNext-06811",
    "VUID-VkVideoBeginCodingInfoKHR-flags-07244",
};

// ----------------------------------------------------------------------------
// Vulkan extensions.
// ----------------------------------------------------------------------------
const RENDER_EXTENSIONS = [_][*:0]const u8{
    vk.extensions.khr_dynamic_rendering.name,
    vk.extensions.khr_synchronization_2.name,
    vk.extensions.khr_swapchain.name,
};

const DEVICE_CAPTURE_EXTENSIONS = blk: {
    // linux specific device extensions
    if (util.is_linux()) {
        break :blk [_][*:0]const u8{
            vk.extensions.ext_image_drm_format_modifier.name,
            vk.extensions.khr_external_memory.name,
            vk.extensions.khr_external_memory_fd.name,
            vk.extensions.ext_external_memory_dma_buf.name,
            vk.extensions.khr_external_semaphore_fd.name,
        };
    }

    break :blk [_][*:0]const u8{};
};

const VIDEO_ENCODE_H264_EXTENSIONS = [_][*:0]const u8{
    vk.extensions.khr_video_queue.name,
    vk.extensions.khr_video_encode_queue.name,
    vk.extensions.khr_video_encode_h_264.name,
};

pub const VIDEO_DECODE_H264_EXTENSIONS = blk: {
    const extensions = [_][*:0]const u8{
        vk.extensions.khr_video_queue.name,
        vk.extensions.khr_video_decode_queue.name,
        vk.extensions.khr_video_decode_h_264.name,
    };

    if (util.is_linux()) {
        break :blk extensions ++ .{
            vk.extensions.ext_image_drm_format_modifier.name,
            vk.extensions.khr_external_memory_fd.name,
            vk.extensions.ext_external_memory_dma_buf.name,
            vk.extensions.khr_external_semaphore_fd.name,
        };
    }

    break :blk extensions;
};

pub const VIDEO_DECODE_H265_EXTENSIONS = blk: {
    const extensions = [_][*:0]const u8{
        vk.extensions.khr_video_queue.name,
        vk.extensions.khr_video_decode_queue.name,
        vk.extensions.khr_video_decode_h_265.name,
    };

    if (util.is_linux()) {
        break :blk extensions ++ .{
            vk.extensions.ext_image_drm_format_modifier.name,
            vk.extensions.khr_external_memory_fd.name,
            vk.extensions.ext_external_memory_dma_buf.name,
            vk.extensions.khr_external_semaphore_fd.name,
        };
    }

    break :blk extensions;
};
// ----------------------------------------------------------------------------

const Queues = struct {
    graphics_family: u32,
    /// Could be null on machines that don't support Vulkan video.
    video_encode_h264_family: ?u32,
    video_decode_h264_family: ?u32,
    video_decode_h265_family: ?u32,
};

pub const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: Queues,
    capture_extensions_supported: bool,
    video_encode_h264_supported: bool,
    video_decode_h264_supported: bool,
    video_decode_h265_supported: bool,
};

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,
    mutex: std.Io.Mutex = .init,

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

    // C vulkan libs
    pub extern fn vkGetInstanceProcAddr(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;

    allocator: std.mem.Allocator,
    io: std.Io,
    vkb: BaseDispatch,
    instance: Instance,
    device: Device,
    debug_messenger: ?vk.DebugUtilsMessengerEXT,
    graphics_queue: Queue,
    video_encode_h264_queue: ?Queue,
    video_decode_h264_queue: ?Queue,
    video_decode_h265_queue: ?Queue,
    capture_extensions_supported: bool,
    physical_device: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    video_encoder: ?*VulkanVideoEncoder = null,
    /// Ring buffer that holds the preview images that are rendered on the UI.
    capture_preview_ring_buffer: Mutex(?*VulkanImageRingBuffer),
    /// Ring buffer that can be used in the capture method to hold frames
    /// in which the encoder can grab from.
    capture_ring_buffer: Mutex(?*VulkanImageRingBuffer),

    /// The window used to render the UI with imgui
    window: ?imguiz.ImGui_ImplVulkanH_Window = null,
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
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

        var extension_names: std.ArrayList([*:0]const u8) = .empty;
        defer extension_names.deinit(allocator);

        try extension_names.append(allocator, vk.extensions.khr_get_physical_device_properties_2.name);

        if (extra_instance_extensions) |extensions| {
            for (extensions) |extension| {
                try extension_names.append(allocator, std.mem.span(extension));
            }
        }

        // TODO: might want to check for more extensions to
        // enable with vkEnumerateInstanceExtensionProperties.
        // See imgui example_sdl3_vulkan for reference.

        if (util.DEBUG) {
            try extension_names.append(allocator, vk.extensions.ext_debug_utils.name);
            // TODO: check if this extension is enabled
            //try extension_names.append(vk.extensions.ext_device_address_binding_report.name);
            // try extension_names.append(vk.extensions.ext_debug_report.name);
        }

        const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
        const enabled_layers: []const [*:0]const u8 = if (util.DEBUG) &validation_layers else &.{};

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

        if (util.DEBUG) {
            debug_messenger = try instance.createDebugUtilsMessengerEXT(&.{
                .message_severity = .{
                    .error_ext = true,
                    .warning_ext = true,
                },
                .message_type = .{
                    .general_ext = true,
                    .validation_ext = true,
                    .performance_ext = true,
                    .device_address_binding_ext = false,
                },
                .pfn_user_callback = debug_callback,
            }, null);
        }
        errdefer {
            if (debug_messenger) |dm| {
                instance.destroyDebugUtilsMessengerEXT(dm, null);
            }
        }

        const candidate = try pick_physical_device(instance, allocator);

        const pdev = candidate.pdev;
        const props = candidate.props;
        const mem_props = instance.getPhysicalDeviceMemoryProperties(pdev);

        const device_candidate = try initialize_candidate(allocator, instance, candidate);
        const vkd = try allocator.create(DeviceDispatch);
        errdefer allocator.destroy(vkd);
        vkd.* = DeviceDispatch.load(device_candidate, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
        const device = Device.init(device_candidate, vkd);
        errdefer device.destroyDevice(null);

        const graphics_queue = Queue.init(device, candidate.queues.graphics_family);
        const video_encode_h264_queue = if (candidate.video_encode_h264_supported)
            Queue.init(device, candidate.queues.video_encode_h264_family.?)
        else
            null;
        const video_decode_h264_queue = if (candidate.video_decode_h264_supported)
            Queue.init(device, candidate.queues.video_decode_h264_family.?)
        else
            null;
        const video_decode_h265_queue = if (candidate.video_decode_h265_supported)
            Queue.init(device, candidate.queues.video_decode_h265_family.?)
        else
            null;

        // We use an allocator here because we don't want the
        // reference to change when we return this object.
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = Self{
            .allocator = allocator,
            .io = io,
            .vkb = vkbd,
            .instance = instance,
            .debug_messenger = debug_messenger,
            .device = device,
            .graphics_queue = graphics_queue,
            .video_encode_h264_queue = video_encode_h264_queue,
            .video_decode_h264_queue = video_decode_h264_queue,
            .video_decode_h265_queue = video_decode_h265_queue,
            .capture_extensions_supported = candidate.capture_extensions_supported,
            .physical_device = pdev,
            .props = props,
            .mem_props = mem_props,
            .capture_preview_ring_buffer = .init(io, null),
            .capture_ring_buffer = .init(io, null),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        defer self.allocator.destroy(self);
        self.deinit_video_encoder();
        self.destroy_capture_preview_ring_buffer();
        self.destroy_capture_ring_buffer();

        if (self.debug_messenger) |debug_messenger| {
            self.instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);
        }

        self.device.destroyDevice(null);
        self.instance.destroyInstance(null);

        self.allocator.destroy(self.device.wrapper);
        self.allocator.destroy(self.instance.wrapper);
    }

    pub fn init_video_encoder(
        self: *Self,
        width: u32,
        height: u32,
        fps: u32,
        bit_rate: u64,
    ) !void {
        if (self.video_encode_h264_queue == null) {
            return error.VideoNotSupported;
        }

        self.video_encoder = try VulkanVideoEncoder.init(
            self.allocator,
            self,
            width,
            height,
            fps,
            bit_rate,
        );
    }

    pub fn deinit_video_encoder(self: *Self) void {
        if (self.video_encoder) |encoder| {
            encoder.deinit();
            self.video_encoder = null;
        }
    }

    pub fn init_capture_preview_ring_buffer(self: *Self, width: u32, height: u32) !void {
        self.capture_preview_ring_buffer.set(try VulkanImageRingBuffer.init(
            .{
                .allocator = self.allocator,
                .io = self.io,
                .vulkan = self,
                .dst_access_mask = .{ .shader_read = true },
                .dst_stage_mask = .{ .fragment_shader = true },
                .image_component_mapping = .{
                    .r = .b,
                    .g = .identity,
                    .b = .r,
                    .a = .one,
                },
                .image_layout = .shader_read_only_optimal,
                .width = width,
                .height = height,
                .usage = .{ .sampled = true },
                .src_queue_family_index = self.graphics_queue.family,
            },
        ));
    }

    pub fn destroy_capture_preview_ring_buffer(self: *Self) void {
        self.wait_for_ui_fences();
        var capture_preview_ring_buffer_locked = self.capture_preview_ring_buffer.lock();
        defer capture_preview_ring_buffer_locked.unlock();

        if (capture_preview_ring_buffer_locked.unwrap()) |capture_preview_ring_buffer| {
            capture_preview_ring_buffer.deinit();
            capture_preview_ring_buffer_locked.set(null);
        }
    }

    pub fn init_capture_ring_buffer(self: *Self, width: u32, height: u32) !void {
        self.capture_ring_buffer.set(try VulkanImageRingBuffer.init(
            .{
                .allocator = self.allocator,
                .io = self.io,
                .vulkan = self,
                .dst_access_mask = .{ .transfer_write = true },
                .dst_stage_mask = .{ .all_transfer = true },
                .image_layout = .color_attachment_optimal,
                .image_component_mapping = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .width = width,
                .height = height,
                .usage = .{ .storage = true, .transfer_src = true, .color_attachment = true },
                .src_queue_family_index = vk.QUEUE_FAMILY_EXTERNAL,
            },
        ));
    }

    pub fn destroy_capture_ring_buffer(self: *Self) void {
        const capture_ring_buffer = blk: {
            var capture_ring_buffer_locked = self.capture_ring_buffer.lock();
            defer capture_ring_buffer_locked.unlock();

            const capture_ring_buffer = capture_ring_buffer_locked.unwrap();
            capture_ring_buffer_locked.set(null);
            break :blk capture_ring_buffer;
        };

        if (capture_ring_buffer) |_capture_ring_buffer| {
            _capture_ring_buffer.wait_for_fences();
            _capture_ring_buffer.deinit();
        }
    }

    /// Caller owns the memory - must free.
    /// Query format modifiers on the device that support importing the buffer with Vulkan.
    pub fn query_format_modifiers(self: *const Self, allocator: Allocator, format: vk.Format) !std.ArrayList(u64) {
        var modifiers_list = vk.DrmFormatModifierPropertiesListEXT{};
        var props = vk.FormatProperties2{
            .p_next = @ptrCast(&modifiers_list),
            .format_properties = .{},
        };

        self.instance.getPhysicalDeviceFormatProperties2KHR(self.physical_device, format, &props);

        const format_mod_props = try allocator.alloc(vk.DrmFormatModifierPropertiesEXT, modifiers_list.drm_format_modifier_count);
        defer allocator.free(format_mod_props);

        modifiers_list.p_drm_format_modifier_properties = format_mod_props.ptr;

        self.instance.getPhysicalDeviceFormatProperties2KHR(self.physical_device, format, &props);

        var modifiers = try std.ArrayList(u64).initCapacity(allocator, 0);

        for (format_mod_props) |modifier| {
            if (self.supports_importable_modifier(format, modifier.drm_format_modifier)) {
                try modifiers.append(allocator, modifier.drm_format_modifier);
            }
        }

        return modifiers;
    }

    /// Check for the importable modifier. This is required for direct memory
    /// access to the buffer.
    fn supports_importable_modifier(self: *const Self, format: vk.Format, modifier: u64) bool {
        var modifier_info = vk.PhysicalDeviceImageDrmFormatModifierInfoEXT{
            .drm_format_modifier = modifier,
            .sharing_mode = .exclusive,
        };
        var external_image_info = vk.PhysicalDeviceExternalImageFormatInfo{
            .p_next = &modifier_info,
            .handle_type = .{ .dma_buf_ext = true },
        };
        const format_info = vk.PhysicalDeviceImageFormatInfo2{
            .p_next = &external_image_info,
            .format = format,
            .type = .@"2d",
            .tiling = .drm_format_modifier_ext,
            .usage = .{ .transfer_src = true, .color_attachment = true },
        };

        var external_properties = std.mem.zeroes(vk.ExternalImageFormatProperties);
        external_properties.s_type = .external_image_format_properties;
        var properties = std.mem.zeroes(vk.ImageFormatProperties2);
        properties.s_type = .image_format_properties_2;
        properties.p_next = &external_properties;

        self.instance.getPhysicalDeviceImageFormatProperties2(
            self.physical_device,
            &format_info,
            &properties,
        ) catch |err| {
            log.debug("[supports_capture_modifier] modifier {x} is unsupported for capture: {}", .{ modifier, err });
            return false;
        };

        return external_properties.external_memory_properties.external_memory_features.importable;
    }

    fn pick_physical_device(
        instance: Instance,
        allocator: std.mem.Allocator,
    ) !DeviceCandidate {
        const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
        defer allocator.free(pdevs);

        var best_candidate: ?DeviceCandidate = null;
        var best_score: u32 = 0;

        for (pdevs) |pdev| {
            if (try check_suitable(instance, pdev, allocator)) |candidate| {
                const score = device_score(candidate.props, candidate.queues);
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

        log.info("[pick_physical_device] using device: {s}", .{device.props.device_name});

        return device;
    }

    /// Simple score function to determine what GPU to auto select based on its capabilties.
    /// Prefer devices that support Vulkan video encoding above all, because the app doesn't
    /// work otherwise.
    fn device_score(props: vk.PhysicalDeviceProperties, queues: Queues) u32 {
        var score: u32 = 0;

        if (queues.video_encode_h264_family != null or
            queues.video_decode_h264_family != null or
            queues.video_decode_h265_family != null)
        {
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

    fn check_suitable(
        instance: Instance,
        pdev: vk.PhysicalDevice,
        allocator: Allocator,
    ) !?DeviceCandidate {
        const props = instance.getPhysicalDeviceProperties(pdev);
        log.debug("[check_suitable] checking potential device: {s}, device type: {}", .{ props.device_name, props.device_type });

        // The render extensions are required. Bail if not supported.
        if (!try check_device_extension_support(allocator, &RENDER_EXTENSIONS, instance, pdev)) {
            return null;
        }

        if (try get_available_queues(instance, pdev, allocator)) |available_queues| {
            const video_encode_h264_supported = available_queues.video_encode_h264_family != null and
                try check_device_extension_support(allocator, &VIDEO_ENCODE_H264_EXTENSIONS, instance, pdev);
            const video_decode_h264_supported = available_queues.video_decode_h264_family != null and
                try check_device_extension_support(allocator, &VIDEO_DECODE_H264_EXTENSIONS, instance, pdev);
            const video_decode_h265_supported = available_queues.video_decode_h265_family != null and
                try check_device_extension_support(allocator, &VIDEO_DECODE_H265_EXTENSIONS, instance, pdev);

            return DeviceCandidate{
                .pdev = pdev,
                .props = props,
                .queues = available_queues,
                .capture_extensions_supported = try check_device_extension_support(
                    allocator,
                    &DEVICE_CAPTURE_EXTENSIONS,
                    instance,
                    pdev,
                ),
                .video_encode_h264_supported = video_encode_h264_supported,
                .video_decode_h264_supported = video_decode_h264_supported,
                .video_decode_h265_supported = video_decode_h265_supported,
            };
        }

        return null;
    }

    fn check_device_extension_support(
        allocator: Allocator,
        extensions: []const [*:0]const u8,
        instance: Instance,
        pdev: vk.PhysicalDevice,
    ) !bool {
        var supported = true;
        for (extensions) |extension| {
            if (!try extension_supported(instance, pdev, allocator, extension)) {
                log.info("[check_device_extension_support] extension is not supported on device: {s}", .{extension});
                supported = false;
            }
        }
        return supported;
    }

    fn extension_supported(
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
    fn get_available_queues(
        instance: Instance,
        pdev: vk.PhysicalDevice,
        allocator: std.mem.Allocator,
    ) !?Queues {
        var family_count: u32 = 0;
        instance.getPhysicalDeviceQueueFamilyProperties2(pdev, &family_count, null);

        const families = try allocator.alloc(vk.QueueFamilyProperties2, @intCast(family_count));
        defer allocator.free(families);

        const video_properties = try allocator.alloc(vk.QueueFamilyVideoPropertiesKHR, @intCast(family_count));
        defer allocator.free(video_properties);

        for (families, video_properties) |*family, *video| {
            video.* = .{ .video_codec_operations = .{} };
            family.* = .{
                .p_next = @ptrCast(video),
                .queue_family_properties = undefined,
            };
        }

        instance.getPhysicalDeviceQueueFamilyProperties2(pdev, &family_count, families.ptr);

        var graphics_family: ?u32 = null;
        var video_encode_h264_family: ?u32 = null;
        var video_decode_h264_family: ?u32 = null;
        var video_decode_h265_family: ?u32 = null;

        for (families[0..@intCast(family_count)], 0..) |family_properties, i| {
            const family: u32 = @intCast(i);
            const properties = family_properties.queue_family_properties;

            if (graphics_family == null and properties.queue_flags.graphics) {
                // Unit tests will not have a surface, so just grab the first
                // graphics queue.
                const presentation_supported = @import("builtin").is_test or
                    imguiz.SDL_Vulkan_GetPresentationSupport(
                        @ptrFromInt(@backingInt(instance.handle)),
                        @ptrFromInt(@backingInt(pdev)),
                        family,
                    );
                if (presentation_supported) {
                    graphics_family = family;
                }
            }

            if (video_encode_h264_family == null and
                properties.queue_flags.video_encode_khr and
                video_properties[i].video_codec_operations.encode_h264_khr)
            {
                video_encode_h264_family = family;
            }

            if (properties.queue_flags.video_decode_khr) {
                const operations = video_properties[i].video_codec_operations;
                if (video_decode_h264_family == null and operations.decode_h264_khr) {
                    video_decode_h264_family = family;
                }
                if (video_decode_h265_family == null and operations.decode_h265_khr) {
                    video_decode_h265_family = family;
                }
            }
        }

        if (graphics_family != null) {
            return Queues{
                .graphics_family = graphics_family.?,
                .video_encode_h264_family = video_encode_h264_family,
                .video_decode_h264_family = video_decode_h264_family,
                .video_decode_h265_family = video_decode_h265_family,
            };
        }

        return null;
    }

    /// - create device
    /// - add device extensions
    /// - add device queues
    fn initialize_candidate(allocator: std.mem.Allocator, instance: Instance, candidate: DeviceCandidate) !vk.Device {
        const priority = [_]f32{1};
        var queue_create_info = try std.ArrayList(vk.DeviceQueueCreateInfo).initCapacity(allocator, 1);
        defer queue_create_info.deinit(allocator);

        try queue_create_info.append(allocator, .{
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        });

        if (candidate.video_encode_h264_supported) {
            if (candidate.queues.video_encode_h264_family) |video_encode_h264_family| {
                if (video_encode_h264_family != candidate.queues.graphics_family) {
                    try queue_create_info.append(allocator, .{
                        .queue_family_index = video_encode_h264_family,
                        .queue_count = 1,
                        .p_queue_priorities = &priority,
                    });
                }
            }
        }

        const video_decode_families = [_]?u32{
            if (candidate.video_decode_h264_supported) candidate.queues.video_decode_h264_family else null,
            if (candidate.video_decode_h265_supported) candidate.queues.video_decode_h265_family else null,
        };
        for (video_decode_families) |maybe_family| {
            const family = maybe_family orelse continue;
            for (queue_create_info.items) |qci| {
                if (qci.queue_family_index == family) {
                    break;
                }
            } else {
                try queue_create_info.append(allocator, .{
                    .queue_family_index = family,
                    .queue_count = 1,
                    .p_queue_priorities = &priority,
                });
            }
        }

        var vulkan_12_features = vk.PhysicalDeviceVulkan12Features{
            .timeline_semaphore = .true,
        };

        var vulkan_11_features = vk.PhysicalDeviceVulkan11Features{
            .p_next = @ptrCast(&vulkan_12_features),
        };

        var synchronization2_features = vk.PhysicalDeviceSynchronization2Features{
            .p_next = @ptrCast(&vulkan_11_features),
            .synchronization_2 = .true,
        };

        const dynamic_rendering_features = vk.PhysicalDeviceDynamicRenderingFeaturesKHR{
            .p_next = @ptrCast(&synchronization2_features),
            .dynamic_rendering = .true,
        };

        var enabled_extensions = try std.ArrayList([*:0]const u8).initCapacity(allocator, 2);
        defer enabled_extensions.deinit(allocator);

        try enabled_extensions.appendSlice(allocator, RENDER_EXTENSIONS[0..]);

        if (candidate.capture_extensions_supported) {
            try enabled_extensions.appendSlice(allocator, DEVICE_CAPTURE_EXTENSIONS[0..]);
        }

        if (candidate.video_encode_h264_supported) {
            try enabled_extensions.appendSlice(allocator, VIDEO_ENCODE_H264_EXTENSIONS[0..]);
        }

        if (candidate.video_decode_h264_supported) {
            try enabled_extensions.appendSlice(allocator, VIDEO_DECODE_H264_EXTENSIONS[0..]);
        }
        if (candidate.video_decode_h265_supported) {
            try enabled_extensions.appendSlice(allocator, VIDEO_DECODE_H265_EXTENSIONS[0..]);
        }

        return try instance.createDevice(candidate.pdev, &.{
            .p_next = &dynamic_rendering_features,
            .queue_create_info_count = @intCast(queue_create_info.items.len),
            .p_queue_create_infos = queue_create_info.items.ptr,
            .enabled_extension_count = @intCast(enabled_extensions.items.len),
            .pp_enabled_extension_names = enabled_extensions.items.ptr,
        }, null);
    }

    fn debug_callback(
        message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
        message_types: vk.DebugUtilsMessageTypeFlagsEXT,
        p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
        p_user_data: ?*anyopaque,
    ) callconv(vk.vulkan_call_conv) vk.Bool32 {
        _ = message_severity;
        _ = message_types;
        _ = p_user_data;
        const callback_data = p_callback_data orelse {
            log.warn("[debug_callback] unrecognized validation layer debug message", .{});
            return .true;
        };

        if (callback_data.p_message_id_name) |p_message_id_name| {
            const message_id = std.mem.span(p_message_id_name);
            inline for (IGNORED_DEBUG_MESSAGE_IDS) |ignored_message_id| {
                if (std.mem.eql(u8, message_id, ignored_message_id)) {
                    return .false;
                }
            }
        }

        const msg = callback_data.p_message orelse {
            log.warn("[debug_callback] unrecognized validation layer debug message", .{});
            return .true;
        };
        log.warn("[debug_callback] {s}", .{msg});
        return .false;
    }

    pub fn allocate(
        self: *Self,
        requirements: vk.MemoryRequirements,
        flags: vk.MemoryPropertyFlags,
        p_next: ?*anyopaque,
    ) !vk.DeviceMemory {
        return try self.device.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.find_memory_type_index(requirements.memory_type_bits, flags),
            .p_next = p_next,
        }, null);
    }

    pub fn find_memory_type_index(self: *Self, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
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
    pub fn queue_submit(
        self: *Self,
        queue: enum { graphics, encode_h264 },
        submit_info: []const vk.SubmitInfo,
        args: struct {
            fence: vk.Fence = .null_handle,
        },
    ) !void {
        const _queue: ?*Queue = switch (queue) {
            // NOTE: Queues must be referenced. Mutexes cannot be copied.
            .graphics => &self.graphics_queue,
            .encode_h264 => if (self.video_encode_h264_queue != null) &self.video_encode_h264_queue.? else null,
        };

        // It should never get to this point. The caller of this function should always have valid queues.
        assert(_queue != null);

        self.lock_queue_family(_queue.?.family);
        defer self.unlock_queue_family(_queue.?.family);
        if (args.fence != .null_handle) {
            try self.device.resetFences(&.{args.fence});
        }
        try self.device.queueSubmit(_queue.?.handle, submit_info, args.fence);
    }

    pub fn lock_queue_family(self: *Self, family: u32) void {
        self.get_queue_mutex_by_family(family).lockUncancelable(self.io);
    }

    pub fn unlock_queue_family(self: *Self, family: u32) void {
        self.get_queue_mutex_by_family(family).unlock(self.io);
    }

    fn get_queue_mutex_by_family(self: *Self, family: u32) *std.Io.Mutex {
        if (self.graphics_queue.family == family) {
            return &self.graphics_queue.mutex;
        }
        if (self.video_encode_h264_queue) |*queue| {
            if (queue.family == family) {
                return &queue.mutex;
            }
        }
        if (self.video_decode_h264_queue) |*queue| {
            if (queue.family == family) {
                return &queue.mutex;
            }
        }
        if (self.video_decode_h265_queue) |*queue| {
            if (queue.family == family) {
                return &queue.mutex;
            }
        }
        @panic("[queue_mutex] unknown queue family");
    }

    /// Lock graphics mutex and present.
    pub fn queue_present_khr(self: *Self, present_info: *const vk.PresentInfoKHR) !void {
        self.graphics_queue.mutex.lockUncancelable(self.io);
        defer self.graphics_queue.mutex.unlock(self.io);
        _ = try self.device.queuePresentKHR(self.graphics_queue.handle, present_info);
    }

    /// Wait for all fences on the imgui Vulkan window.
    pub fn wait_for_ui_fences(self: *Self) void {
        if (self.window) |window| {
            for (0..@intCast(window.Frames.Size)) |i| {
                const fd = window.Frames.Data[i];
                const fence: vk.Fence = @fromBackingInt(@intCast(@intFromPtr(fd.Fence.?)));
                _ = self.device.waitForFences(
                    &.{fence},
                    .true,
                    std.math.maxInt(u64),
                ) catch |err| {
                    log.err("[wait_for_ui_fences] err: {}", .{err});
                };
            }
        }
    }

    pub fn wait_for_capture_ring_buffer_fences(self: *Self) void {
        const capture_ring_buffer_locked = self.capture_ring_buffer.lock();
        defer capture_ring_buffer_locked.unlock();

        if (capture_ring_buffer_locked.unwrap()) |capture_ring_buffer| {
            capture_ring_buffer.wait_for_fences();
        }
    }

    /// Lock the graphics queue and wait for all fences on the queue.
    ///
    /// WARNING: Must be followed up by `waitForAllGraphicsFencesEnd` to
    /// unlock mutexes EXCEPT when it returns an error.
    pub fn wait_for_all_graphics_fences_begin(self: *Self) !void {
        var wait_fences = try std.ArrayList(vk.Fence).initCapacity(self.allocator, 0);
        defer wait_fences.deinit(self.allocator);

        // Collect fences before queue locks to avoid lock-order inversion.
        {
            const capture_preview_ring_buffer_locked = self.capture_preview_ring_buffer.lock();
            defer capture_preview_ring_buffer_locked.unlock();
            if (capture_preview_ring_buffer_locked.unwrap()) |capture_preview_ring_buffer| {
                for (capture_preview_ring_buffer.buffers) |buffer| {
                    try wait_fences.append(self.allocator, buffer.as_ptr().fence);
                }
            }
        }

        // Capture-ring copy command buffers run on the graphics queue and may still be reading
        // pipewire dmabuf images during format-change callbacks.
        {
            const capture_ring_buffer_locked = self.capture_ring_buffer.lock();
            defer capture_ring_buffer_locked.unlock();
            if (capture_ring_buffer_locked.unwrap()) |capture_ring_buffer| {
                for (capture_ring_buffer.buffers) |buffer| {
                    try wait_fences.append(self.allocator, buffer.as_ptr().fence);
                }
            }
        }

        if (self.window) |window| {
            if (window.Frames.Size > 0 and window.Frames.Data != null and window.FrameIndex < window.Frames.Size) {
                const fd = &window.Frames.Data[window.FrameIndex];
                if (fd.Fence != null) {
                    try wait_fences.append(self.allocator, @fromBackingInt(@intCast(@intFromPtr(fd.Fence))));
                }
            }
        }

        // Encoder compute work is submitted on the graphics queue.
        if (self.video_encoder) |encoder| {
            try wait_fences.append(self.allocator, encoder.compute_finished_fence);
        }

        self.graphics_queue.mutex.lockUncancelable(self.io);
        errdefer self.graphics_queue.mutex.unlock(self.io);

        if (wait_fences.items.len > 0) {
            _ = try self.device.waitForFences(
                wait_fences.items,
                .true,
                std.math.maxInt(u64),
            );
        } else {
            log.debug("[wait_for_all_graphics_fences_begin] wait_fences length is 0", .{});
        }
    }

    pub fn wait_for_all_graphics_fences_end(self: *Self) void {
        self.graphics_queue.mutex.unlock(self.io);
    }

    /// Copy a Vulkan image to a buffer in which the CPU can access.
    pub fn copy_image_to_cpu_buffer(
        self: *Self,
        allocator: Allocator,
        image: vk.Image,
        image_layout: vk.ImageLayout,
        width: u32,
        height: u32,
        args: struct {
            src_stage_mask: vk.PipelineStageFlags2,
            src_access_mask: vk.AccessFlags2,
        },
    ) ![]u8 {
        const size: u64 = width * height * 4; // bgra

        const buffer_create_info = vk.BufferCreateInfo{
            .size = size,
            .usage = .{ .transfer_dst = true },
            .sharing_mode = .exclusive,
        };

        const buffer = try self.device.createBuffer(&buffer_create_info, null);
        defer self.device.destroyBuffer(buffer, null);

        const mem_reqs = self.device.getBufferMemoryRequirements(buffer);
        const memory = try self.allocate(
            mem_reqs,
            .{ .host_visible = true, .host_coherent = true },
            null,
        );
        defer self.device.freeMemory(memory, null);

        try self.device.bindBufferMemory(buffer, memory, 0);

        const command_pool = try self.device.createCommandPool(&.{
            .queue_family_index = self.graphics_queue.family,
            .flags = .{ .reset_command_buffer = true },
        }, null);
        defer self.device.destroyCommandPool(command_pool, null);

        const command_buffer_alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };

        var command_buffer: vk.CommandBuffer = undefined;
        try self.device.allocateCommandBuffers(&command_buffer_alloc_info, @ptrCast(&command_buffer));
        defer self.device.freeCommandBuffers(command_pool, &.{command_buffer});

        try self.device.beginCommandBuffer(command_buffer, &.{});

        const color_subresource_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };

        const image_to_transfer_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = args.src_stage_mask,
            .src_access_mask = args.src_access_mask,
            .dst_stage_mask = .{ .all_transfer = true },
            .dst_access_mask = .{ .transfer_read = true },
            .old_layout = image_layout,
            .new_layout = .transfer_src_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = color_subresource_range,
        };
        const image_to_transfer_dep_info = vk.DependencyInfoKHR{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&image_to_transfer_barrier),
        };
        self.device.cmdPipelineBarrier2(command_buffer, &image_to_transfer_dep_info);

        const copy_region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = width, .height = height, .depth = 1 },
        };

        self.device.cmdCopyImageToBuffer(
            command_buffer,
            image,
            .transfer_src_optimal,
            buffer,
            &.{copy_region},
        );

        const buffer_read_barrier = vk.BufferMemoryBarrier2{
            .src_stage_mask = .{ .all_transfer = true },
            .src_access_mask = .{ .transfer_write = true },
            .dst_stage_mask = .{ .host = true },
            .dst_access_mask = .{ .host_read = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = buffer,
            .offset = 0,
            .size = size,
        };
        const read_dep_info = vk.DependencyInfoKHR{
            .buffer_memory_barrier_count = 1,
            .p_buffer_memory_barriers = @ptrCast(&buffer_read_barrier),
        };
        self.device.cmdPipelineBarrier2(command_buffer, &read_dep_info);

        try self.device.endCommandBuffer(command_buffer);

        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
        };

        const fence = try self.device.createFence(&.{}, null);
        defer self.device.destroyFence(fence, null);

        try self.queue_submit(.graphics, &.{submit_info}, .{ .fence = fence });

        const result = try self.device.waitForFences(&.{fence}, .true, std.math.maxInt(u64));
        if (result != .success) {
            return error.WaitForFences;
        }

        const mapped = try self.device.mapMemory(memory, 0, size, .{});
        defer self.device.unmapMemory(memory);

        const mapped_data: [*]const u8 = @ptrCast(mapped);
        const data = try allocator.alloc(u8, size);
        errdefer allocator.free(data);
        @memcpy(data, mapped_data[0..data.len]);
        return data;
    }

    /// Copy a vulkan image on the GPU.
    /// NOTE: This is only for the graphics queue.
    pub fn copy_image(
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
            .dst_stage_mask = .{ .all_transfer = true },
            .dst_access_mask = .{ .transfer_read = true },
            .old_layout = .color_attachment_optimal,
            .new_layout = .transfer_src_optimal,
            .src_queue_family_index = args.src_queue_family_index,
            .dst_queue_family_index = self.graphics_queue.family,
            .image = src_image,
            .subresource_range = .{
                .aspect_mask = .{ .color = true },
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
            .dst_stage_mask = .{ .all_transfer = true },
            .dst_access_mask = .{ .transfer_write = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = dst_image,
            .subresource_range = .{
                .aspect_mask = .{ .color = true },
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
            .aspect_mask = .{ .color = true },
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
            &.{clear_range},
        );

        const copy_width = @min(dst_width, src_width);
        const copy_height = @min(dst_height, src_height);

        const copy_region = vk.ImageCopy{
            .src_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .src_offset = .{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
            .extent = .{ .width = copy_width, .height = copy_height, .depth = 1 },
        };

        self.device.cmdCopyImage(
            command_buffer,
            src_image,
            .transfer_src_optimal,
            dst_image,
            .transfer_dst_optimal,
            &.{copy_region},
        );

        // Transfer the source image back to its original layout.
        const src_restore_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .all_transfer = true },
            .src_access_mask = .{ .transfer_read = true },
            .dst_stage_mask = .{ .color_attachment_output = true },
            .dst_access_mask = .{ .color_attachment_write = true },
            .old_layout = .transfer_src_optimal,
            .new_layout = .color_attachment_optimal,
            .src_queue_family_index = args.src_queue_family_index,
            .dst_queue_family_index = self.graphics_queue.family,
            .image = src_image,
            .subresource_range = .{
                .aspect_mask = .{ .color = true },
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
            .src_stage_mask = .{ .all_transfer = true },
            .src_access_mask = .{ .transfer_write = true },
            .dst_stage_mask = args.dst_stage_mask,
            .dst_access_mask = args.dst_access_mask,
            .old_layout = .transfer_dst_optimal,
            .new_layout = args.new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = dst_image,
            .subresource_range = .{
                .aspect_mask = .{ .color = true },
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
            .transfer = true,
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

        try self.queue_submit(.graphics, &.{submit_info}, .{ .fence = args.fence });
    }
};
