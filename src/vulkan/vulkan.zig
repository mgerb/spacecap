const std = @import("std");

const imguiz = @import("imguiz").imguiz;
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
const CapturePreviewSwapchain = @import("./capture_preview_swapchain.zig").CapturePreviewSwapchain;

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

    encoder: ?*Encoder = null,
    capture_preview_swapchain: ?*CapturePreviewSwapchain = null,

    /// The window used to render the UI with imgui
    window: ?imguiz.ImGui_ImplVulkanH_Window = null,

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

        const device_candidate = try initializeCandidate(instance, candidate);
        const vkd = try allocator.create(DeviceDispatch);
        errdefer allocator.destroy(vkd);
        vkd.* = DeviceDispatch.load(device_candidate, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
        const device = Device.init(device_candidate, vkd);
        errdefer device.destroyDevice(null);

        const graphics_queue = Queue.init(device, candidate.queues.graphics_family);
        const video_encode_queue = Queue.init(device, candidate.queues.video_encode_family);

        // We use an allocator here because we don't want the
        // reference to change when we return this object.
        const self = try allocator.create(Self);
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
        };

        std.log.info("Using device: {s}\n", .{self.props.device_name});

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

    pub fn initCapturePreviewSwapchain(self: *Self, width: u32, height: u32) !void {
        self.capture_preview_swapchain = try CapturePreviewSwapchain.init(self.allocator, self, width, height);
    }

    pub fn destroyCapturePreviewSwapchain(self: *Self) !void {
        if (self.capture_preview_swapchain) |capture_preview_swapchain| {
            try self.waitForUIFences();
            capture_preview_swapchain.deinit();
            self.capture_preview_swapchain = null;
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

            return .false;
        }
        std.log.scoped(.validation).warn("unrecognized validation layer debug message", .{});
        return .true;
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
            .synchronization_2 = .true,
        };

        const dynamic_rendering_features = vk.PhysicalDeviceDynamicRenderingFeaturesKHR{
            .p_next = @ptrCast(@constCast(&synchronization2_features)),
            .dynamic_rendering = .true,
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
        const _queue = switch (queue) {
            // NOTE: Queues must be referenced. Mutexes cannot be copied.
            .graphics => &self.graphics_queue,
            .encode => &self.encode_queue,
        };

        _queue.mutex.lock();
        defer _queue.mutex.unlock();
        if (args.fence != .null_handle) {
            try self.device.resetFences(1, @ptrCast(&args.fence));
        }
        try self.device.queueSubmit(_queue.handle, @intCast(submit_info.len), submit_info.ptr, args.fence);
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
        self.encode_queue.mutex.lock();

        var wait_fences = try std.ArrayList(vk.Fence).initCapacity(self.allocator, 0);
        defer wait_fences.deinit(self.allocator);

        if (self.encoder) |encoder| {
            try wait_fences.appendSlice(self.allocator, &.{
                encoder.compute_finished_fence,
                encoder.encode_finished_fence,
            });
        }

        if (self.capture_preview_swapchain) |capture_preview_swapchain| {
            for (capture_preview_swapchain.buffers) |buffer| {
                try wait_fences.append(self.allocator, buffer.fence);
            }
        }

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
        self.encode_queue.mutex.unlock();
    }

    pub fn deinit(self: *Self) void {
        self.destroyVideoEncoder();
        self.destroyCapturePreviewSwapchain() catch |err| {
            std.log.err("failed to destroy capture preview swapchain: {}\n", .{err});
        };

        if (self.debug_messenger) |debug_messenger| {
            self.instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);
        }

        self.device.destroyDevice(null);
        self.instance.destroyInstance(null);

        // allocator destroys
        self.allocator.destroy(self.device.wrapper);
        self.allocator.destroy(self.instance.wrapper);
        self.allocator.destroy(self);
    }
};
