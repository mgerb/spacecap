const std = @import("std");

const c = @import("imguiz").imguiz;
const vk = @import("vulkan");
const rc = @import("zigrc");
const sdl = @import("./sdl.zig");
const Tray = @import("./tray.zig").Tray;

const VulkanCapturePreviewTexture = @import("../vulkan/vulkan_capture_preview_texture.zig").VulkanCapturePreviewTexture;
const Actor = @import("../state/actor.zig").Actor;
const Vulkan = @import("../vulkan/vulkan.zig").Vulkan;
const API_VERSION = @import("../vulkan/vulkan.zig").API_VERSION;
const draw_left_column = @import("./draw_left_column.zig").draw_left_column;
const draw_video_preview = @import("./draw_video_preview.zig").draw_video_preview;
const VulkanImageBuffer = @import("../vulkan/vulkan_image_buffer.zig").VulkanImageBuffer;
const WaylandPresentGate = @import("./wayland_present_gate.zig").WaylandPresentGate;
const AppIcon = @import("./app_icon.zig").AppIcon;
const Store = @import("../state/store.zig").Store;

// TODO: save and restore window size
const WIDTH = 1600;
const HEIGHT = 1000;

const MIN_IMAGE_COUNT = 2;
var g_PipelineCache: c.VkPipelineCache = std.mem.zeroes(c.VkPipelineCache);

pub const UI = struct {
    const log = std.log.scoped(.ui);
    const Self = @This();

    store: *Store,
    actor: *Actor,
    vulkan: *Vulkan,
    allocator: std.mem.Allocator,

    window: ?*c.struct_SDL_Window = null,
    window_icon_surface: ?*c.SDL_Surface = null,
    tray: ?Tray = null,
    surface: ?c.VkSurfaceKHR = null,
    descriptor_pool: ?vk.DescriptorPool = null,
    swapchain_rebuild: bool = false,
    wayland_present_gate: ?WaylandPresentGate = null,
    app_icon: AppIcon,

    /// Init SDL and return new UI instance.
    pub fn init(
        allocator: std.mem.Allocator,
        store: *Store,
        actor: *Actor,
        vulkan: *Vulkan,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = Self{
            .allocator = allocator,
            .store = store,
            .actor = actor,
            .vulkan = vulkan,
            .app_icon = .init(),
        };

        try sdl.init();

        const version = c.SDL_GetVersion();
        std.log.info("SDL version: {}\n", .{version});

        try self.init_vulkan();

        return self;
    }

    pub fn deinit(self: *Self) void {
        const did_wait = self.vulkan.wait_for_all_graphics_fences_begin();
        defer {
            if (did_wait) {
                self.vulkan.wait_for_all_graphics_fences_end();
            } else |err| {
                log.err("[deinit] wait for fence error: {}", .{err});
            }
        }

        self.app_icon.deinit();
        c.cImGui_ImplVulkan_Shutdown();
        c.cImGui_ImplSDL3_Shutdown();
        if (self.wayland_present_gate) |*wayland_present_gate| {
            wayland_present_gate.deinit();
        }

        if (self.descriptor_pool) |descriptor_pool| {
            self.vulkan.device.destroyDescriptorPool(descriptor_pool, null);
        }

        if (self.vulkan.window) |window| {
            c.cImGui_ImplVulkanH_DestroyWindow(
                self.vk_instance(),
                self.vk_device(),
                @ptrCast(@constCast(&window)),
                null,
            );
            self.vulkan.window = null;
        }

        if (self.surface) |surface| {
            c.SDL_Vulkan_DestroySurface(self.vk_instance(), surface, null);
            self.surface = null;
        }

        if (self.window) |window| {
            c.SDL_DestroyWindow(window);
        }
        if (self.tray) |*tray| {
            tray.deinit();
        }
        if (self.window_icon_surface) |icon_surface| {
            c.SDL_DestroySurface(icon_surface);
        }
        c.SDL_Quit();

        self.allocator.destroy(self);
    }

    // TODO: Split off the main loop into its own method.
    fn init_vulkan(self: *Self) !void {
        self.window = c.SDL_CreateWindow("Spacecap", WIDTH, HEIGHT, c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY);
        if (self.window == null) return error.SDLCreateWindowFailure;
        errdefer {
            if (self.window) |window| {
                c.SDL_DestroyWindow(window);
            }
        }

        if (!c.SDL_SetWindowIcon(self.window.?, self.app_icon.app_icon_surface_blue)) {
            log.warn("[init_vulkan] failed to set window icon: {s}", .{c.SDL_GetError()});
        }

        // Just log the error. Should still run without the tray.
        self.tray = Tray.init(self.actor, &self.app_icon) catch |err| blk: {
            log.err("[init_vulkan] unable to initialize tray: {}", .{err});
            break :blk null;
        };
        errdefer {
            if (self.tray) |*tray| tray.deinit();
            self.tray = null;
        }

        var surface: c.VkSurfaceKHR = undefined;

        if (!c.SDL_Vulkan_CreateSurface(self.window, self.vk_instance(), null, &surface)) {
            return error.SDLVulkanCreateSurfaceFailure;
        }
        self.surface = surface;

        if (!c.cImGui_ImplVulkan_LoadFunctions(@bitCast(API_VERSION), loader)) {
            return error.ImGuiVulkanLoadFailure;
        }

        try self.setup_vulkan_window();
        errdefer c.cImGui_ImplVulkanH_DestroyWindow(
            self.vk_instance(),
            self.vk_device(),
            @ptrCast(&self.vulkan.window),
            null,
        );

        // TODO: not supported in wayland
        // if (!c.SDL_SetWindowPosition(
        //     self.window.?,
        //     c.SDL_WINDOWPOS_CENTERED,
        //     c.SDL_WINDOWPOS_CENTERED,
        // )) {
        //     return error.SDLSetWindowPositionFailure;
        // }
        if (!c.SDL_ShowWindow(self.window.?)) {
            return error.SDLShowWindowFailure;
        }
        self.wayland_present_gate = WaylandPresentGate.init(self.window.?);

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
            return error.SDLInitForVulkanFailure;
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
        init_info.Instance = self.vk_instance();
        init_info.PhysicalDevice = self.vk_physical_device();
        init_info.Device = self.vk_device();
        init_info.QueueFamily = self.vulkan.graphics_queue.family;
        init_info.Queue = self.vk_queue();
        init_info.PipelineCache = g_PipelineCache; // TODO: maybe need?
        init_info.DescriptorPool = self.vk_descriptor_pool();
        init_info.MinImageCount = MIN_IMAGE_COUNT;
        init_info.ImageCount = self.vulkan.window.?.ImageCount;
        init_info.Allocator = null;
        init_info.CheckVkResultFn = check_vk_result;
        init_info.PipelineInfoMain.RenderPass = self.vulkan.window.?.RenderPass;
        init_info.PipelineInfoMain.Subpass = 0;
        init_info.PipelineInfoMain.MSAASamples = c.VK_SAMPLE_COUNT_1_BIT;
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
            .ExtraSizeScale = 1.0,
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
            if (self.wayland_present_gate) |*wayland_present_gate| {
                wayland_present_gate.dispatch_pending();
            }

            if (self.tray) |*tray| {
                self.actor.ui_mutex.lock();
                defer self.actor.ui_mutex.unlock();
                tray.set_state(.{
                    .is_recording = self.actor.state.is_recording_video,
                    .is_capturing = self.actor.state.is_capturing_video,
                });
            }

            // Resize swap chain?
            var fb_width: i32 = undefined;
            var fb_height: i32 = undefined;
            if (!c.SDL_GetWindowSizeInPixels(self.window.?, &fb_width, &fb_height)) {
                return error.SDLGetWindowSizeInPixelsFailure;
            }
            const framebuffer_zero_sized = fb_width <= 0 or fb_height <= 0;
            const run_ui_frame = self.should_run_ui_frame(framebuffer_zero_sized);

            if (!run_ui_frame) {
                c.SDL_Delay(1);
                continue;
            }

            if (fb_width > 0 and fb_height > 0 and
                (self.swapchain_rebuild or
                    self.vulkan.window.?.Width != fb_width or
                    self.vulkan.window.?.Height != fb_height))
            {
                // This causes big problems if we don't wait for the GPU to be ready.
                try self.vulkan.wait_for_all_graphics_fences_begin();
                defer self.vulkan.wait_for_all_graphics_fences_end();

                c.cImGui_ImplVulkan_SetMinImageCount(MIN_IMAGE_COUNT);
                c.cImGui_ImplVulkanH_CreateOrResizeWindow(
                    self.vk_instance(),
                    self.vk_physical_device(),
                    self.vk_device(),
                    &self.vulkan.window.?,
                    self.vulkan.graphics_queue.family,
                    null,
                    fb_width,
                    fb_height,
                    MIN_IMAGE_COUNT,
                    c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
                );
                self.vulkan.window.?.FrameIndex = 0;
                self.swapchain_rebuild = false;
            }

            // Start the Dear ImGui frame
            c.cImGui_ImplVulkan_NewFrame();
            c.cImGui_ImplSDL3_NewFrame();
            c.ImGui_NewFrame();

            {
                var capture_preview_buffer: ?rc.Arc(*VulkanImageBuffer) = null;
                var capture_preview_texture: ?rc.Arc(VulkanCapturePreviewTexture) = null;
                // Hold onto the buffer until draw/render/present is done.
                defer {
                    if (capture_preview_buffer) |buffer| {
                        if (buffer.releaseUnwrap()) |val| {
                            val.deinit();
                        } else {
                            buffer.value.*.in_use.store(false, .release);
                        }
                    }
                    if (capture_preview_texture) |_capture_preview_texture| {
                        if (_capture_preview_texture.releaseUnwrap()) |*val| {
                            @constCast(val).deinit();
                        }
                    }
                }

                {
                    const locked_state = self.store.state.lock();
                    defer locked_state.unlock();
                    const state = locked_state.unwrap_ptr();
                    self.actor.ui_mutex.lock();
                    defer self.actor.ui_mutex.unlock();

                    // 1. Show the big demo window (Most of the sample code is in ImGui::ShowDemoWindow()! You can browse its code to learn more about Dear ImGui!).
                    if (state.show_demo) {
                        var show_demo_window: bool = true;
                        c.ImGui_ShowDemoWindow(&show_demo_window);

                        if (!show_demo_window) {
                            self.store.dispatch(.show_demo);
                        }
                    }

                    try draw_left_column(self.allocator, self.actor, self.store, state);

                    if (!self.actor.state.is_video_capture_supprted) {
                        try draw_video_preview(.vulkan_video_not_supported);
                    } else if (self.actor.state.is_capturing_video) {
                        const capture_preview_ring_buffer_locked = self.vulkan.capture_preview_ring_buffer.lock();
                        defer capture_preview_ring_buffer_locked.unlock();
                        if (capture_preview_ring_buffer_locked.unwrap()) |capture_preview_ring_buffer| {
                            if (capture_preview_ring_buffer.get_most_recent_buffer()) |buffer| {
                                capture_preview_buffer = buffer;
                                capture_preview_texture = try self.vulkan.get_capture_preview_texture(buffer.value.*);
                                try draw_video_preview(.{ .capture_preview = .{
                                    .capture_preview_buffer = capture_preview_texture.?.value,
                                    .width = buffer.value.*.width,
                                    .height = buffer.value.*.height,
                                } });
                            }
                        }
                    }
                }

                // Rendering while preview locks are held.
                c.ImGui_Render();
                const draw_data = c.ImGui_GetDrawData();
                const imgui_zero_sized = (draw_data.*.DisplaySize.x <= 0.0 or draw_data.*.DisplaySize.y <= 0.0);
                const should_present = run_ui_frame and !imgui_zero_sized;
                self.vulkan.window.?.ClearValue.color.float32[0] = clear_color.x * clear_color.w;
                self.vulkan.window.?.ClearValue.color.float32[1] = clear_color.y * clear_color.w;
                self.vulkan.window.?.ClearValue.color.float32[2] = clear_color.z * clear_color.w;
                self.vulkan.window.?.ClearValue.color.float32[3] = clear_color.w;
                if (should_present) {
                    try self.frame_render(draw_data);
                }

                if (io.*.ConfigFlags & c.ImGuiConfigFlags_ViewportsEnable > 0) {
                    c.ImGui_UpdatePlatformWindows();
                    c.ImGui_RenderPlatformWindowsDefault();
                }

                if (should_present) {
                    try self.frame_present();
                }
            }
        }

        try self.actor.dispatch(.exit);
    }

    fn frame_render(self: *Self, draw_data: *c.ImDrawData) !void {
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

        {
            self.vulkan.graphics_queue.mutex.lock();
            defer self.vulkan.graphics_queue.mutex.unlock();
            c.cImGui_ImplVulkan_RenderDrawData(draw_data, fd.CommandBuffer);
        }

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
            try self.vulkan.queue_submit(.graphics, &.{info}, .{ .fence = @enumFromInt(@intFromPtr(fd.Fence.?)) });
        }
    }

    fn frame_present(self: *Self) !void {
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
        var present_completed = true;
        if (self.wayland_present_gate) |*wayland_present_gate| {
            present_completed = try wayland_present_gate.register_present_callback();
            if (!present_completed) {
                log.debug("[frame_present] skipping present because wl_surface.frame is not ready", .{});
                return;
            }
            defer {
                if (!present_completed) {
                    wayland_present_gate.cancel_callback();
                }
            }
        }
        self.vulkan.queue_present_khr(&info) catch |err| {
            switch (err) {
                error.OutOfDateKHR => {
                    self.swapchain_rebuild = true;
                    return;
                },
                else => return err,
            }
        };
        present_completed = true;

        wd.SemaphoreIndex = (wd.SemaphoreIndex + 1) % wd.SemaphoreCount; // Now we can use the next set of semaphores
    }

    /// Check for various window states to see if UI frames
    /// should be rendered/presented. SDL3 does not provide
    /// what we need for Wayland so we have to implement some
    /// custom stuff.
    fn should_run_ui_frame(
        self: *Self,
        framebuffer_zero_sized: bool,
    ) bool {
        const window_flags = c.SDL_GetWindowFlags(self.window.?);
        const window_hidden = (window_flags & c.SDL_WINDOW_HIDDEN) > 0;
        const window_minimized = (window_flags & c.SDL_WINDOW_MINIMIZED) > 0;
        const window_occluded = (window_flags & c.SDL_WINDOW_OCCLUDED) > 0;
        const wayland_allows_present = blk: {
            if (self.wayland_present_gate) |wayland_present_gate| {
                break :blk wayland_present_gate.frame_ready();
            }

            break :blk true;
        };

        return !window_hidden and
            !window_minimized and
            !window_occluded and
            !framebuffer_zero_sized and
            wayland_allows_present;
    }

    fn setup_vulkan_window(self: *Self) !void {
        self.vulkan.window = .{
            .Surface = self.surface.?,
            .AttachmentDesc = .{
                .format = c.VK_FORMAT_UNDEFINED,
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
                .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            },
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
            self.vk_physical_device(),
            self.vulkan.window.?.Surface,
            @ptrCast(&requestSurfaceImageFormat),
            requestSurfaceImageFormat.len,
            requestSurfaceColorSpace,
        );

        // Select Present Mode
        const present_modes = [_]c.VkPresentModeKHR{
            // c.VK_PRESENT_MODE_IMMEDIATE_KHR,
            // c.VK_PRESENT_MODE_MAILBOX_KHR,
            // NOTE: FIFO seems to be the best for a desktop application and is
            // more widely supported. When using this method, we MUST make sure
            // it doesn't try to render/present when the window is not visible
            // (or is throttled by the compositor).
            c.VK_PRESENT_MODE_FIFO_KHR,
        };
        self.vulkan.window.?.PresentMode = c.cImGui_ImplVulkanH_SelectPresentMode(
            self.vk_physical_device(),
            self.vulkan.window.?.Surface,
            &present_modes[0],
            present_modes.len,
        );

        // Create SwapChain, RenderPass, Framebuffer, etc.
        var fb_width: i32 = undefined;
        var fb_height: i32 = undefined;
        if (!c.SDL_GetWindowSizeInPixels(self.window.?, &fb_width, &fb_height)) {
            return error.SDLGetWindowSizeInPixelsFailure;
        }

        {
            self.vulkan.graphics_queue.mutex.lock();
            defer self.vulkan.graphics_queue.mutex.unlock();
            c.cImGui_ImplVulkanH_CreateOrResizeWindow(
                self.vk_instance(),
                self.vk_physical_device(),
                self.vk_device(),
                &self.vulkan.window.?,
                self.vulkan.graphics_queue.family,
                null,
                fb_width,
                fb_height,
                MIN_IMAGE_COUNT,
                c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            );
        }
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

    fn vk_instance(self: *const Self) c.VkInstance {
        return @ptrFromInt(@intFromEnum(self.vulkan.instance.handle));
    }

    fn vk_device(self: *const Self) c.VkDevice {
        return @ptrFromInt(@intFromEnum(self.vulkan.device.handle));
    }

    fn vk_physical_device(self: *const Self) c.VkPhysicalDevice {
        return @ptrFromInt(@intFromEnum(self.vulkan.physical_device));
    }

    fn vk_descriptor_pool(self: *const Self) c.VkDescriptorPool {
        return @ptrFromInt(@intFromEnum(self.descriptor_pool.?));
    }

    fn vk_queue(self: *const Self) c.VkQueue {
        return @ptrFromInt(@intFromEnum(self.vulkan.graphics_queue.handle));
    }
};
