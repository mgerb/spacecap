const std = @import("std");

const c = @import("imguiz").imguiz;
const vk = @import("vulkan");

const StateActor = @import("../state_actor.zig").StateActor;
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const API_VERSION = @import("../vulkan/vulkan.zig").API_VERSION;
const drawLeftColumn = @import("./draw_left_column.zig").drawLeftColumn;
const drawVideoPreview = @import("./draw_video_preview.zig").drawVideoPreview;
const drawVideoPreviewUnavailable = @import("./draw_video_preview.zig").drawVideoPreviewUnavailable;
const VulkanImageBuffer = @import("../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;

// TODO: save and restore window size
const WIDTH = 1600;
const HEIGHT = 1000;

const MIN_IMAGE_COUNT = 2;
var g_PipelineCache: c.VkPipelineCache = std.mem.zeroes(c.VkPipelineCache);

const SDL_INIT_FLAGS = c.SDL_INIT_VIDEO | c.SDL_INIT_GAMEPAD;

pub const UI = struct {
    const Self = @This();

    state_actor: *StateActor,
    vulkan: *Vulkan,
    allocator: std.mem.Allocator,

    window: ?*c.struct_SDL_Window = null,
    surface: ?c.VkSurfaceKHR = null,
    descriptor_pool: ?vk.DescriptorPool = null,
    swapchain_rebuild: bool = false,

    /// Init SDL and return new UI instance
    pub fn init(
        allocator: std.mem.Allocator,
        state_actor: *StateActor,
        vulkan: *Vulkan,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = Self{
            .allocator = allocator,
            .state_actor = state_actor,
            .vulkan = vulkan,
        };

        if (!c.SDL_Init(SDL_INIT_FLAGS)) {
            return error.SDL_initFailure;
        }

        const version = c.SDL_GetVersion();
        std.log.info("SDL version: {}\n", .{version});

        try self.initVulkan();

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.vulkan.waitForAllFencesBegin() catch unreachable;
        defer self.vulkan.waitForAllFencesEnd();

        c.cImGui_ImplVulkan_Shutdown();
        c.cImGui_ImplSDL3_Shutdown();

        if (self.descriptor_pool) |descriptor_pool| {
            self.vulkan.device.destroyDescriptorPool(descriptor_pool, null);
        }

        if (self.vulkan.window) |window| {
            c.cImGui_ImplVulkanH_DestroyWindow(
                self.vkInstance(),
                self.vkDevice(),
                @ptrCast(@constCast(&window)),
                null,
            );
            self.vulkan.window = null;
        }

        // Seems like destroying the vulkan window destroys the surface?
        // if (self.surface) |surface| {
        //     c.SDL_Vulkan_DestroySurface(self.vkInstance(), surface, null);
        // }

        if (self.window) |window| {
            c.SDL_DestroyWindow(window);
        }
        c.SDL_Quit();

        self.allocator.destroy(self);
    }

    /// Caller owns memory
    /// TODO: check why not returning "wayland"
    pub fn getSDLVulkanExtensions(allocator: std.mem.Allocator) !std.ArrayList([*:0]const u8) {
        if (!c.SDL_Init(SDL_INIT_FLAGS)) {
            return error.SDL_initFailure;
        }
        defer c.SDL_Quit();

        var extensions = try std.ArrayList([*:0]const u8).initCapacity(allocator, 0);
        var extensions_count: u32 = 0;
        const sdl_extensions = c.SDL_Vulkan_GetInstanceExtensions(&extensions_count);
        for (0..extensions_count) |i| try extensions.append(allocator, std.mem.span(sdl_extensions[i]));

        return extensions;
    }

    fn initVulkan(self: *Self) !void {
        self.window = c.SDL_CreateWindow("Spacecap", WIDTH, HEIGHT, c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY);
        if (self.window == null) return error.SDL_CreateWindowFailure;
        errdefer {
            if (self.window) |window| {
                c.SDL_DestroyWindow(window);
            }
        }

        var surface: c.VkSurfaceKHR = undefined;

        if (!c.SDL_Vulkan_CreateSurface(self.window, self.vkInstance(), null, &surface)) {
            return error.SDL_Vulkan_CreateSurfaceFailure;
        }
        self.surface = surface;

        if (!c.cImGui_ImplVulkan_LoadFunctions(@bitCast(API_VERSION), loader)) {
            return error.ImGuiVulkanLoadFailure;
        }

        try self.setupVulkanWindow();
        errdefer c.cImGui_ImplVulkanH_DestroyWindow(
            self.vkInstance(),
            self.vkDevice(),
            @ptrCast(&self.vulkan.window),
            null,
        );

        // TODO: not supported in wayland
        // if (!c.SDL_SetWindowPosition(
        //     self.window.?,
        //     c.SDL_WINDOWPOS_CENTERED,
        //     c.SDL_WINDOWPOS_CENTERED,
        // )) {
        //     return error.SDL_SetWindowPositionFailure;
        // }
        if (!c.SDL_ShowWindow(self.window.?)) {
            return error.SDL_ShowWindowFailure;
        }

        // Setup Dear ImGui context
        if (c.ImGui_CreateContext(null) == null) return error.ImGuiCreateContextFailure;
        errdefer c.ImGui_DestroyContext(null);
        const io = c.ImGui_GetIO();
        io.*.ConfigFlags |= c.ImGuiConfigFlags_NavEnableKeyboard; // Enable Keyboard Controls
        io.*.ConfigFlags |= c.ImGuiConfigFlags_NavEnableGamepad; // Enable Gamepad Controls
        // io.*.ConfigFlags |= c.ImGuiConfigFlags_DockingEnable;
        // io.*.ConfigFlags |= c.ImGuiConfigFlags_ViewportsEnable;

        // Setup Dear ImGui style
        c.ImGui_StyleColorsDark(null);

        const style = c.ImGui_GetStyle();
        if (io.*.ConfigFlags & c.ImGuiConfigFlags_ViewportsEnable > 0) {
            style.*.WindowRounding = 0.0;
            style.*.Colors[c.ImGuiCol_WindowBg].w = 1.0;
        }

        // Setup Platform/Renderer backends
        if (!c.cImGui_ImplSDL3_InitForVulkan(self.window.?)) {
            return error.cImGui_ImplSDL3_InitForVulkanFailure;
        }
        errdefer c.cImGui_ImplSDL3_Shutdown();

        const pool_size = vk.DescriptorPoolSize{
            .type = .combined_image_sampler,
            .descriptor_count = 1,
        };

        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{
                .free_descriptor_set_bit = true,
            },
            // NOTE: If we create more textures then this number
            // needs to increase, otherwise we'll get segfaults.
            .max_sets = 10,
            .p_pool_sizes = @ptrCast(&pool_size),
            .pool_size_count = 1,
        };

        // used for imgui/vulkan/sdl
        self.descriptor_pool = try self.vulkan.device.createDescriptorPool(&pool_info, null);
        errdefer self.vulkan.device.destroyDescriptorPool(self.descriptor_pool.?, null);

        var init_info = c.ImGui_ImplVulkan_InitInfo{};
        init_info.Instance = self.vkInstance();
        init_info.PhysicalDevice = self.vkPhysicalDevice();
        init_info.Device = self.vkDevice();
        init_info.QueueFamily = self.vulkan.graphics_queue.family;
        init_info.Queue = self.vkQueue();
        init_info.PipelineCache = g_PipelineCache; // TODO: maybe need?
        init_info.DescriptorPool = self.vkDescriptorPool();
        init_info.RenderPass = self.vulkan.window.?.RenderPass;
        init_info.Subpass = 0;
        init_info.MinImageCount = MIN_IMAGE_COUNT;
        init_info.ImageCount = self.vulkan.window.?.ImageCount;
        init_info.MSAASamples = c.VK_SAMPLE_COUNT_1_BIT;
        init_info.Allocator = null;
        init_info.CheckVkResultFn = check_vk_result;
        if (!c.cImGui_ImplVulkan_Init(&init_info)) {
            return error.ImGuiVulkanInitFailure;
        }
        errdefer c.cImGui_ImplVulkan_Shutdown();

        // Load Fonts
        // - If no fonts are loaded, dear imgui will use the default font. You can also load multiple fonts and use ImGui::PushFont()/PopFont() to select them.
        // - AddFontFromFileTTF() will return the ImFont* so you can store it if you need to select the font among multiple.
        // - If the file cannot be loaded, the function will return a nullptr. Please handle those errors in your application (e.g. use an assertion, or display an error and quit).
        // - The fonts will be rasterized at a given size (w/ oversampling) and stored into a texture when calling ImFontAtlas::Build()/GetTexDataAsXXXX(), which ImGui_ImplXXXX_NewFrame below will call.
        // - Use '#define IMGUI_ENABLE_FREETYPE' in your imconfig file to use Freetype for higher quality font rendering.
        // - Read 'docs/FONTS.md' for more instructions and details.
        // - Remember that in C/C++ if you want to include a backslash \ in a string literal you need to write a double backslash \\ !
        //io.Fonts->AddFontDefault();
        //io.Fonts->AddFontFromFileTTF("c:\\Windows\\Fonts\\segoeui.ttf", 18.0f);
        //io.Fonts->AddFontFromFileTTF("../../misc/fonts/DroidSans.ttf", 16.0f);
        //io.Fonts->AddFontFromFileTTF("../../misc/fonts/Roboto-Medium.ttf", 16.0f);
        //io.Fonts->AddFontFromFileTTF("../../misc/fonts/Cousine-Regular.ttf", 15.0f);
        //ImFont* font = io.Fonts->AddFontFromFileTTF("c:\\Windows\\Fonts\\ArialUni.ttf", 18.0f, nullptr, io.Fonts->GetGlyphRangesJapanese());
        //IM_ASSERT(font != nullptr);
        const font_data = @embedFile("../fonts/LilexNerdFontMono-Regular.ttf");
        const font_cfg: c.ImFontConfig = .{
            .GlyphMaxAdvanceX = std.math.floatMax(f32),
            .RasterizerMultiply = 1.0,
            .RasterizerDensity = 1.0,
        };

        const font = c.ImFontAtlas_AddFontFromMemoryTTF(
            io.*.Fonts,
            @constCast(font_data.ptr),
            @intCast(font_data.len),
            18.0,
            &font_cfg,
            null,
        );
        if (font == null) {
            return error.ImGuiFontLoadFailure;
        }
        io.*.FontDefault = font;

        // black background
        const clear_color: c.ImVec4 = .{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 1.0 };

        // Main loop
        var done = false;
        var timer = try std.time.Timer.start();
        var window_has_focus = true;

        while (!done) {
            timer.reset();
            // Poll and handle events (inputs, window resize, etc.)
            // You can read the io.WantCaptureMouse, io.WantCaptureKeyboard flags to tell if dear imgui wants to use your inputs.
            // - When io.WantCaptureMouse is true, do not dispatch mouse input data to your main application, or clear/overwrite your copy of the mouse data.
            // - When io.WantCaptureKeyboard is true, do not dispatch keyboard input data to your main application, or clear/overwrite your copy of the keyboard data.
            // Generally you may always pass all inputs to dear imgui, and hide them from your application based on those two flags.
            var event: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&event)) {
                _ = c.cImGui_ImplSDL3_ProcessEvent(&event);
                switch (event.type) {
                    c.SDL_EVENT_QUIT => done = true,
                    c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                        if (event.window.windowID == c.SDL_GetWindowID(self.window.?)) {
                            done = true;
                        }
                    },
                    c.SDL_EVENT_WINDOW_FOCUS_GAINED => window_has_focus = true,
                    c.SDL_EVENT_WINDOW_FOCUS_LOST => window_has_focus = false,
                    else => {},
                }
            }

            // NOTE: SDL_WINDOW_MINIMIZED - this event does not get invoked on wayland.
            // TODO: Test this out on windows. We may not want this at all?
            if ((c.SDL_GetWindowFlags(self.window.?) & c.SDL_WINDOW_MINIMIZED) > 0) {
                c.SDL_Delay(10);
                continue;
            }

            // Resize swap chain?
            var fb_width: i32 = undefined;
            var fb_height: i32 = undefined;
            if (!c.SDL_GetWindowSizeInPixels(self.window.?, &fb_width, &fb_height)) {
                return error.SDL_GetWindowSizeInPixelsFailure;
            }
            if (fb_width > 0 and fb_height > 0 and
                (self.swapchain_rebuild or
                    self.vulkan.window.?.Width != fb_width or
                    self.vulkan.window.?.Height != fb_height))
            {
                // This causes big problems if we don't wait for the GPU to be ready.
                try self.vulkan.waitForAllFencesBegin();
                defer self.vulkan.waitForAllFencesEnd();

                c.cImGui_ImplVulkan_SetMinImageCount(MIN_IMAGE_COUNT);
                c.cImGui_ImplVulkanH_CreateOrResizeWindow(
                    self.vkInstance(),
                    self.vkPhysicalDevice(),
                    self.vkDevice(),
                    &self.vulkan.window.?,
                    self.vulkan.graphics_queue.family,
                    null,
                    fb_width,
                    fb_height,
                    MIN_IMAGE_COUNT,
                );
                self.vulkan.window.?.FrameIndex = 0;
                self.swapchain_rebuild = false;
            }

            // Start the Dear ImGui frame
            c.cImGui_ImplVulkan_NewFrame();
            c.cImGui_ImplSDL3_NewFrame();
            c.ImGui_NewFrame();

            var capture_preview_buffer: ?*VulkanImageBuffer = null;
            defer {
                // First, check if the ring buffer has been destroyed. The buffer
                // gets locked when we call `getMostRecentBuffer`, so we must
                // unlock it before the next iteration.
                if (self.vulkan.capture_preview_ring_buffer != null) {
                    if (capture_preview_buffer) |buffer| {
                        buffer.mutex.unlock();
                    }
                }
            }

            {
                self.state_actor.ui_mutex.lock();
                defer self.state_actor.ui_mutex.unlock();

                // 1. Show the big demo window (Most of the sample code is in ImGui::ShowDemoWindow()! You can browse its code to learn more about Dear ImGui!).
                if (self.state_actor.state.show_demo) {
                    var show_demo_window: bool = true;
                    c.ImGui_ShowDemoWindow(&show_demo_window);

                    if (!show_demo_window) {
                        try self.state_actor.dispatch(.show_demo);
                    }
                }

                try drawLeftColumn(self.allocator, self.state_actor);

                if (!self.state_actor.state.is_video_capture_supprted) {
                    try drawVideoPreview(.vulkan_video_not_supported);
                } else if (self.state_actor.state.recording) {
                    if (self.vulkan.capture_preview_ring_buffer) |capture_preview_ring_buffer| {
                        if (capture_preview_ring_buffer.getMostRecentBuffer()) |buffer| {
                            capture_preview_buffer = buffer;
                            const capture_preview_texture = try self.vulkan.getCapturePreviewTexture(buffer);
                            try drawVideoPreview(.{ .capture_preview = .{
                                .capture_preview_buffer = capture_preview_texture,
                                .width = buffer.width,
                                .height = buffer.height,
                            } });
                        }
                    }
                }
            }

            // Rendering
            c.ImGui_Render();
            const draw_data = c.ImGui_GetDrawData();
            const is_minimized = (draw_data.*.DisplaySize.x <= 0.0 or draw_data.*.DisplaySize.y <= 0.0);
            self.vulkan.window.?.ClearValue.color.float32[0] = clear_color.x * clear_color.w;
            self.vulkan.window.?.ClearValue.color.float32[1] = clear_color.y * clear_color.w;
            self.vulkan.window.?.ClearValue.color.float32[2] = clear_color.z * clear_color.w;
            self.vulkan.window.?.ClearValue.color.float32[3] = clear_color.w;
            if (!is_minimized) {
                try self.frameRender(draw_data);
            }

            if (io.*.ConfigFlags & c.ImGuiConfigFlags_ViewportsEnable > 0) {
                c.ImGui_UpdatePlatformWindows();
                c.ImGui_RenderPlatformWindowsDefault();
            }

            if (!is_minimized) {
                try self.framePresent();
            }

            // Delay until the next frame to maintain desired FPS.
            // We use mailbox present mode so unlimited FPS can get
            // pretty high e.g. 2k+
            self.state_actor.ui_mutex.lock();
            const fg_fps = self.state_actor.state.user_settings.settings.gui_foreground_fps;
            const bg_fps = self.state_actor.state.user_settings.settings.gui_background_fps;
            self.state_actor.ui_mutex.unlock();

            const frame_duration_ns = if (window_has_focus) (1_000_000_000 / fg_fps) else (1_000_000_000 / bg_fps);
            const elapsed_ns = timer.read();
            if (elapsed_ns < frame_duration_ns) {
                const sleep_duration_ns = frame_duration_ns - elapsed_ns;
                c.SDL_DelayNS(sleep_duration_ns);
            }
        }

        try self.state_actor.dispatch(.exit);
    }

    fn frameRender(self: *Self, draw_data: *c.ImDrawData) !void {
        var wd = &self.vulkan.window.?;

        const image_acquired_semaphore = wd.FrameSemaphores.Data[wd.SemaphoreIndex].ImageAcquiredSemaphore;
        var render_complete_semaphore = wd.FrameSemaphores.Data[wd.SemaphoreIndex].RenderCompleteSemaphore;
        const result = (self.vulkan.device.acquireNextImageKHR(
            @enumFromInt(@intFromPtr(wd.Swapchain)),
            std.math.maxInt(u64),
            @enumFromInt(@intFromPtr(image_acquired_semaphore)),
            .null_handle,
        ) catch |err| {
            switch (err) {
                error.OutOfDateKHR => {
                    self.swapchain_rebuild = true;
                    return;
                },
                else => return err,
            }
        });

        if (result.result == .suboptimal_khr) {
            self.swapchain_rebuild = true;
        }

        wd.FrameIndex = result.image_index;

        var fd = &wd.Frames.Data[wd.FrameIndex];

        {
            const err = try self.vulkan.device.waitForFences(1, @ptrCast(&fd.Fence), .true, std.math.maxInt(u64));
            check_vk_result(@intFromEnum(err));
        }

        {
            try self.vulkan.device.resetCommandPool(@enumFromInt(@intFromPtr(fd.CommandPool)), .{});
            const info = vk.CommandBufferBeginInfo{
                .flags = .{ .one_time_submit_bit = true },
            };
            try self.vulkan.device.beginCommandBuffer(@enumFromInt(@intFromPtr(fd.CommandBuffer)), @ptrCast(&info));
        }
        {
            const info = vk.RenderPassBeginInfo{
                .render_pass = @enumFromInt(@intFromPtr(wd.RenderPass)),
                .framebuffer = @enumFromInt(@intFromPtr(fd.Framebuffer)),
                .render_area = .{ .extent = .{ .width = @intCast(wd.Width), .height = @intCast(wd.Height) }, .offset = .{ .x = 0, .y = 0 } },
                .clear_value_count = 1,
                .p_clear_values = @ptrCast(&wd.ClearValue),
            };
            self.vulkan.device.cmdBeginRenderPass(@enumFromInt(@intFromPtr(fd.CommandBuffer)), @ptrCast(&info), .@"inline");
        }

        // Record dear imgui primitives into command buffer
        c.cImGui_ImplVulkan_RenderDrawData(draw_data, fd.CommandBuffer);

        // Submit command buffer
        self.vulkan.device.cmdEndRenderPass(@enumFromInt(@intFromPtr(fd.CommandBuffer)));
        {
            var wait_stage = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
            const info = vk.SubmitInfo{
                .wait_semaphore_count = 1,
                .p_wait_semaphores = @ptrCast(&image_acquired_semaphore),
                .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
                .command_buffer_count = 1,
                .p_command_buffers = @ptrCast(&fd.CommandBuffer),
                .signal_semaphore_count = 1,
                .p_signal_semaphores = @ptrCast(&render_complete_semaphore),
            };

            try self.vulkan.device.endCommandBuffer(@enumFromInt(@intFromPtr(fd.CommandBuffer)));
            try self.vulkan.queueSubmit(.graphics, &.{info}, .{ .fence = @enumFromInt(@intFromPtr(fd.Fence.?)) });
        }
    }

    fn framePresent(self: *Self) !void {
        var wd = &self.vulkan.window.?;
        if (self.swapchain_rebuild) {
            return;
        }
        var render_complete_semaphore = wd.FrameSemaphores.Data[wd.SemaphoreIndex].RenderCompleteSemaphore;
        const info = vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&render_complete_semaphore),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&wd.Swapchain),
            .p_image_indices = @ptrCast(&wd.FrameIndex),
        };
        self.vulkan.queuePresentKHR(&info) catch |err| {
            switch (err) {
                error.OutOfDateKHR => {
                    self.swapchain_rebuild = true;
                    return;
                },
                else => return err,
            }
        };

        wd.SemaphoreIndex = (wd.SemaphoreIndex + 1) % wd.SemaphoreCount; // Now we can use the next set of semaphores
    }

    fn setupVulkanWindow(self: *Self) !void {
        self.vulkan.window = .{
            .Surface = self.surface.?,
            .ClearEnable = true,
        };

        // Check for WSI support
        _ = self.vulkan.instance.getPhysicalDeviceSurfaceSupportKHR(
            self.vulkan.physical_device,
            self.vulkan.graphics_queue.family,
            @enumFromInt(@intFromPtr(self.vulkan.window.?.Surface)),
        ) catch return error.NoWSISupport;

        // Select Surface Format
        const requestSurfaceImageFormat = [_]c.VkFormat{ c.VK_FORMAT_B8G8R8A8_UNORM, c.VK_FORMAT_R8G8B8A8_UNORM, c.VK_FORMAT_B8G8R8_UNORM, c.VK_FORMAT_R8G8B8_UNORM };
        const requestSurfaceColorSpace = c.VK_COLORSPACE_SRGB_NONLINEAR_KHR;
        self.vulkan.window.?.SurfaceFormat = c.cImGui_ImplVulkanH_SelectSurfaceFormat(
            self.vkPhysicalDevice(),
            self.vulkan.window.?.Surface,
            @ptrCast(&requestSurfaceImageFormat),
            requestSurfaceImageFormat.len,
            requestSurfaceColorSpace,
        );

        // Select Present Mode
        const present_modes = [_]c.VkPresentModeKHR{
            // NOTE: Had some deadlocks with fifo, use mailbox instead
            // and limit fps manually.
            // c.VK_PRESENT_MODE_FIFO_KHR,
            // c.VK_PRESENT_MODE_IMMEDIATE_KHR,
            c.VK_PRESENT_MODE_MAILBOX_KHR,
        };
        self.vulkan.window.?.PresentMode = c.cImGui_ImplVulkanH_SelectPresentMode(
            self.vkPhysicalDevice(),
            self.vulkan.window.?.Surface,
            &present_modes[0],
            present_modes.len,
        );

        // Create SwapChain, RenderPass, Framebuffer, etc.
        var fb_width: i32 = undefined;
        var fb_height: i32 = undefined;
        if (!c.SDL_GetWindowSizeInPixels(self.window.?, &fb_width, &fb_height)) {
            return error.SDL_GetWindowSizeInPixelsFailure;
        }

        c.cImGui_ImplVulkanH_CreateOrResizeWindow(
            self.vkInstance(),
            self.vkPhysicalDevice(),
            self.vkDevice(),
            &self.vulkan.window.?,
            self.vulkan.graphics_queue.family,
            null,
            fb_width,
            fb_height,
            MIN_IMAGE_COUNT,
        );
    }

    fn loader(name: [*c]const u8, instance: ?*anyopaque) callconv(.c) ?*const fn () callconv(.c) void {
        const vkGetInstanceProcAddr: c.PFN_vkGetInstanceProcAddr = @ptrCast(c.SDL_Vulkan_GetVkGetInstanceProcAddr());
        return vkGetInstanceProcAddr.?(@ptrCast(instance), name);
    }

    fn check_vk_result(err: c.VkResult) callconv(.c) void {
        if (err == 0) return;
        std.log.err("[vulkan] Error: VkResult = {d}\n", .{err});
        if (err < 0) std.process.exit(1);
    }

    fn vkInstance(self: *const Self) c.VkInstance {
        return @ptrFromInt(@intFromEnum(self.vulkan.instance.handle));
    }

    fn vkDevice(self: *const Self) c.VkDevice {
        return @ptrFromInt(@intFromEnum(self.vulkan.device.handle));
    }

    fn vkPhysicalDevice(self: *const Self) c.VkPhysicalDevice {
        return @ptrFromInt(@intFromEnum(self.vulkan.physical_device));
    }

    fn vkDescriptorPool(self: *const Self) c.VkDescriptorPool {
        return @ptrFromInt(@intFromEnum(self.descriptor_pool.?));
    }

    fn vkQueue(self: *const Self) c.VkQueue {
        return @ptrFromInt(@intFromEnum(self.vulkan.graphics_queue.handle));
    }
};
