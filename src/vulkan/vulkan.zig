const std = @import("std");

const vk = @import("vulkan");
const BaseDispatch = vk.BaseWrapper;
const InstanceDispatch = vk.InstanceWrapper;
const DeviceDispatch = vk.DeviceWrapper;
pub const Instance = vk.InstanceProxy;
pub const Device = vk.DeviceProxy;
pub const CommandBuffer = vk.CommandBufferProxy;
pub const API_VERSION = vk.API_VERSION_1_4;

const util = @import("../util.zig");
const Encoder = @import("./encoder.zig").Encoder;
const EncodeResult = @import("./encoder.zig").EncodeResult;
const TrianglePipeline = @import("./triangle_pipeline.zig").TrianglePipeline;

// TODO: update before release
const DEBUG = true;

const INSTANCE_EXTENSIONS = [_][*:0]const u8{
    vk.extensions.khr_get_physical_device_properties_2.name,
};

const DEVICE_EXTENSIONS = blk: {
    const base_device_extensions = [_][*:0]const u8{
        vk.extensions.khr_dynamic_rendering.name,
        vk.extensions.khr_video_queue.name,
        vk.extensions.khr_video_encode_queue.name,
        vk.extensions.khr_video_encode_h_264.name,
        vk.extensions.khr_synchronization_2.name,
        vk.extensions.khr_swapchain.name,
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
    video_encode_family: u32,
};

pub const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
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
    const Self = @This();
    allocator: std.mem.Allocator,
    vkb: BaseDispatch,
    instance: Instance,
    device: Device,
    debug_messenger: ?vk.DebugUtilsMessengerEXT,
    graphics_queue: Queue,
    encode_queue: Queue,
    physical_device: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    command_pool: vk.CommandPool,
    descriptor_pool: vk.DescriptorPool,

    encoder: ?*Encoder = null,

    // NOTE: used for testing
    triangle_pipeline: ?*TrianglePipeline = null,

    pub fn init(
        allocator: std.mem.Allocator,
        extra_instance_extensions: ?[][*:0]const u8,
    ) !*Self {
        if (extra_instance_extensions) |e| {
            for (e) |ee| {
                std.debug.print("extra_instance_extension: {s}\n", .{ee});
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

        var extension_names = std.ArrayList([*:0]const u8).init(allocator);
        defer extension_names.deinit();

        try extension_names.appendSlice(&INSTANCE_EXTENSIONS);

        if (extra_instance_extensions) |extensions| {
            for (extensions) |extension| {
                try extension_names.append(std.mem.span(extension));
            }
        }

        // TODO: might want to check for more extensions to
        // enable with vkEnumerateInstanceExtensionProperties.
        // See imgui example_sdl3_vulkan for reference.

        if (DEBUG) {
            try extension_names.append(vk.extensions.ext_debug_utils.name);
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

        const device_candidate = try initializeCandidate(instance, candidate);
        const vkd = try allocator.create(DeviceDispatch);
        errdefer allocator.destroy(vkd);
        vkd.* = DeviceDispatch.load(device_candidate, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
        const device = Device.init(device_candidate, vkd);
        errdefer device.destroyDevice(null);

        const graphics_queue = Queue.init(device, candidate.queues.graphics_family);
        const video_encode_queue = Queue.init(device, candidate.queues.video_encode_family);

        const pool_size = vk.DescriptorPoolSize{
            .type = .combined_image_sampler,
            .descriptor_count = 1,
        };

        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{ .free_descriptor_set_bit = true },
            .max_sets = 1,
            .p_pool_sizes = @ptrCast(&pool_size),
            .pool_size_count = 1,
        };

        // used for sdl window
        const descriptor_pool = try device.createDescriptorPool(&pool_info, null);
        errdefer device.destroyDescriptorPool(descriptor_pool, null);

        const command_pool = try device.createCommandPool(&.{
            .queue_family_index = graphics_queue.family,
            .flags = .{ .reset_command_buffer_bit = true },
        }, null);
        errdefer device.destroyCommandPool(command_pool, null);

        // We use an allocator here because we don't want the
        // reference to change when we return this object.
        var self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .vkb = vkbd,
            .instance = instance,
            .debug_messenger = debug_messenger,
            .device = device,
            .graphics_queue = graphics_queue,
            .encode_queue = video_encode_queue,
            .physical_device = pdev,
            .props = props,
            .mem_props = mem_props,
            .command_pool = command_pool,
            .descriptor_pool = descriptor_pool,
        };

        std.debug.print("Using device: {s}\n", .{self.props.device_name});

        self.triangle_pipeline = try TrianglePipeline.init(
            allocator,
            self,
            device,
            self.graphics_queue,
            self.command_pool,
            800,
            600,
        );

        return self;
    }

    pub fn initVideoEncoder(
        self: *Self,
        width: u32,
        height: u32,
        fps: u32,
        bit_rate: u64,
    ) !void {
        self.encoder = try Encoder.init(
            self.allocator,
            self,
            width,
            height,
            fps,
            bit_rate,
        );
    }

    pub fn destroyVideoEncoder(self: *Self) void {
        if (self.encoder) |encoder| {
            encoder.deinit();
            self.encoder = null;
        }
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

        var modifiers = std.ArrayList(u64).init(self.allocator);

        for (format_mod_props) |modifier| {
            try modifiers.append(modifier.drm_format_modifier);
        }

        return modifiers;
    }

    fn pickPhysicalDevice(
        instance: Instance,
        allocator: std.mem.Allocator,
    ) !DeviceCandidate {
        const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
        defer allocator.free(pdevs);

        for (pdevs) |pdev| {
            if (try checkSuitable(instance, pdev, allocator)) |candidate| {
                return candidate;
            }
        }

        return error.NoSuitableDevice;
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
            std.log.scoped(.validation).warn("{s}", .{msg});
            return vk.FALSE;
        }
        std.log.scoped(.validation).warn("unrecognized validation layer debug message", .{});
        return vk.FALSE;
    }

    fn checkSuitable(
        instance: Instance,
        pdev: vk.PhysicalDevice,
        allocator: std.mem.Allocator,
    ) !?DeviceCandidate {
        if (!try checkDeviceExtensionSupport(instance, pdev, allocator)) {
            return null;
        }

        if (try allocateQueues(instance, pdev, allocator)) |allocation| {
            const props = instance.getPhysicalDeviceProperties(pdev);
            return DeviceCandidate{
                .pdev = pdev,
                .props = props,
                .queues = allocation,
            };
        }

        return null;
    }

    fn extensionEnabled(
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
            std.log.err("Extension is not supported by device: {s}\n", .{extension});
            return false;
        }
        return true;
    }

    fn checkDeviceExtensionSupport(
        instance: Instance,
        pdev: vk.PhysicalDevice,
        allocator: std.mem.Allocator,
    ) !bool {
        for (DEVICE_EXTENSIONS) |ext| {
            if (!try extensionEnabled(instance, pdev, allocator, ext)) {
                return false;
            }
        }

        return true;
    }

    fn allocateQueues(
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

        if (graphics_family != null and video_encode_family != null) {
            return QueueAllocation{
                .graphics_family = graphics_family.?,
                .video_encode_family = video_encode_family.?,
            };
        }

        return null;
    }

    /// - create device
    /// - add device extensions
    /// - add device queues
    fn initializeCandidate(instance: Instance, candidate: DeviceCandidate) !vk.Device {
        const priority = [_]f32{1};
        const qci = [_]vk.DeviceQueueCreateInfo{
            .{
                .queue_family_index = candidate.queues.graphics_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            .{
                .queue_family_index = candidate.queues.video_encode_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
        };

        const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.video_encode_family)
            1
        else
            2;

        const synchronization2_features = vk.PhysicalDeviceSynchronization2Features{
            .synchronization_2 = vk.TRUE,
        };

        const dynamic_rendering_features = vk.PhysicalDeviceDynamicRenderingFeaturesKHR{
            .p_next = @constCast(@ptrCast(&synchronization2_features)),
            .dynamic_rendering = vk.TRUE,
        };

        return try instance.createDevice(candidate.pdev, &.{
            .p_next = &dynamic_rendering_features,
            .queue_create_info_count = queue_count,
            .p_queue_create_infos = &qci,
            .enabled_extension_count = DEVICE_EXTENSIONS.len,
            .pp_enabled_extension_names = @ptrCast(&DEVICE_EXTENSIONS),
        }, null);
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

    pub fn deinit(self: *Self) void {
        if (self.encoder) |encoder| {
            encoder.deinit();
        }

        self.device.destroyDescriptorPool(self.descriptor_pool, null);

        if (self.debug_messenger) |debug_messenger| {
            self.instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);
        }

        self.device.destroyCommandPool(self.command_pool, null);

        if (self.triangle_pipeline) |triangle_pipeline| {
            triangle_pipeline.deinit();
        }

        self.device.destroyDevice(null);
        self.instance.destroyInstance(null);

        // allocator destroys
        self.allocator.destroy(self.device.wrapper);
        self.allocator.destroy(self.instance.wrapper);
        self.allocator.destroy(self);
    }
};

test "simple test for memory leaks" {
    const a = std.testing.allocator;

    const start_time = std.time.nanoTimestamp();
    std.debug.print("init", .{});
    const vulkan = try Vulkan.init(a, 30, 60, null);
    try vulkan.initVideoEncoder(
        vulkan.triangle_pipeline.?.width,
        vulkan.triangle_pipeline.?.height,
    );
    defer vulkan.deinit();
    try vulkan.encoder.?.updateImages(
        vulkan.triangle_pipeline.?.images.items,
        vulkan.triangle_pipeline.?.image_views.items,
    );

    std.debug.print("starting mainloop", .{});
    for (0..5) |i| {
        const current_frame_ix: u32 = @intCast(i % vulkan.triangle_pipeline.?.images.items.len);
        try vulkan.triangle_pipeline.?.drawFrame(current_frame_ix, @intCast(i));
        const file_name = try std.fmt.allocPrint(a, "frame_{}.bmp", .{i});
        defer a.free(file_name);

        // try vulkan_debug_util.debugWriteImageToFile(
        //     vulkan,
        //     vulkan.triangle_pipeline.images.items[current_frame_ix],
        //     // vk.Format.r8g8b8a8_unorm,
        //     vulkan.triangle_pipeline.fence,
        //     vulkan.triangle_pipeline.width,
        //     vulkan.triangle_pipeline.height,
        //     file_name,
        //     null,
        // );

        try vulkan.encodeFrame(current_frame_ix);
        try vulkan.waitEncodeFrame();
    }

    util.printElapsed(start_time, "start_time");
}
