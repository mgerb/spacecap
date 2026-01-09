const std = @import("std");
const ffmpeg = @import("./ffmpeg.zig");
const pipewire_include = @import("./capture/video/linux/pipewire/pipewire_include.zig");
const c = pipewire_include.c;
const c_def = pipewire_include.c_def;

const metadata_events = c.pw_metadata_events{
    .version = c.PW_VERSION_METADATA_EVENTS,
    .property = onMetadataProperty,
};

const DefaultTargets = struct {
    allocator: std.mem.Allocator,
    sink: ?[]u8 = null,
    source: ?[]u8 = null,

    fn deinit(self: *DefaultTargets) void {
        if (self.sink) |value| self.allocator.free(value);
        if (self.source) |value| self.allocator.free(value);
    }
};

const DeviceInfo = struct {
    id: u32,
    media_class: []const u8,
    node_name: []const u8,
    node_desc: []const u8,
};

const ListData = struct {
    allocator: std.mem.Allocator,
    devices: std.ArrayList(DeviceInfo),
    default_sink: ?[]const u8 = null,
    default_source: ?[]const u8 = null,
    configured_sink: ?[]const u8 = null,
    configured_source: ?[]const u8 = null,
    registry: ?*c.pw_registry = null,
    metadata: ?*c.pw_metadata = null,
    metadata_listener: c.spa_hook = undefined,

    fn deinit(self: *ListData) void {
        for (self.devices.items) |device| {
            self.allocator.free(device.media_class);
            self.allocator.free(device.node_name);
            self.allocator.free(device.node_desc);
        }
        self.devices.deinit(self.allocator);

        if (self.default_sink) |value| self.allocator.free(value);
        if (self.default_source) |value| self.allocator.free(value);
        if (self.configured_sink) |value| self.allocator.free(value);
        if (self.configured_source) |value| self.allocator.free(value);
    }

    fn setDefault(self: *ListData, key: []const u8, value: []const u8) !void {
        const trimmed = if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
            value[1 .. value.len - 1]
        else
            value;
        const parsed_name = parseDefaultName(trimmed) orelse trimmed;

        if (std.mem.eql(u8, key, "default.audio.sink")) {
            if (self.default_sink) |old| self.allocator.free(old);
            self.default_sink = try self.allocator.dupe(u8, parsed_name);
        } else if (std.mem.eql(u8, key, "default.audio.source")) {
            if (self.default_source) |old| self.allocator.free(old);
            self.default_source = try self.allocator.dupe(u8, parsed_name);
        } else if (std.mem.eql(u8, key, "default.configured.audio.sink")) {
            if (self.configured_sink) |old| self.allocator.free(old);
            self.configured_sink = try self.allocator.dupe(u8, parsed_name);
        } else if (std.mem.eql(u8, key, "default.configured.audio.source")) {
            if (self.configured_source) |old| self.allocator.free(old);
            self.configured_source = try self.allocator.dupe(u8, parsed_name);
        }
    }

    fn parseDefaultName(value: []const u8) ?[]const u8 {
        const key = "\"name\"";
        const key_index = std.mem.indexOf(u8, value, key) orelse return null;
        var i = key_index + key.len;
        while (i < value.len and value[i] != ':') : (i += 1) {}
        if (i >= value.len) return null;
        i += 1;
        while (i < value.len and (value[i] == ' ' or value[i] == '\t')) : (i += 1) {}
        if (i >= value.len or value[i] != '"') return null;
        i += 1;
        const start = i;
        while (i < value.len and value[i] != '"') : (i += 1) {}
        if (i >= value.len) return null;
        return value[start..i];
    }
};

fn isAudioSource(media_class: []const u8) bool {
    return std.mem.startsWith(u8, media_class, "Audio/Source");
}

fn isAudioSink(media_class: []const u8) bool {
    return std.mem.startsWith(u8, media_class, "Audio/Sink");
}

fn nameMatches(name: ?[]const u8, node_name: []const u8) bool {
    return name != null and std.mem.eql(u8, node_name, name.?);
}

fn listAudioDevices(allococator: std.mem.Allocator) !DefaultTargets {
    const list_loop = c.pw_main_loop_new(null) orelse return error.pw_main_loop_new;
    defer c.pw_main_loop_destroy(list_loop);

    const context = c.pw_context_new(c.pw_main_loop_get_loop(list_loop), null, 0) orelse return error.pw_context_new;
    defer c.pw_context_destroy(context);

    const core = c.pw_context_connect(context, null, 0) orelse return error.pw_context_connect;
    defer _ = c.pw_core_disconnect(core);

    const registry = c.pw_core_get_registry(core, c.PW_VERSION_REGISTRY, 0) orelse return error.pw_registry_new;
    var list_data = ListData{
        .allocator = allococator,
        .devices = try std.ArrayList(DeviceInfo).initCapacity(allococator, 0),
        .registry = registry,
    };
    defer list_data.deinit();

    var registry_listener: c.spa_hook = undefined;
    const registry_events = c.pw_registry_events{
        .version = c.PW_VERSION_REGISTRY_EVENTS,
        .global = onRegistryGlobal,
        .global_remove = null,
    };

    _ = c.pw_registry_add_listener(registry, &registry_listener, &registry_events, &list_data);

    const Quitter = struct {
        fn run(loop: ?*c.pw_main_loop) void {
            std.Thread.sleep(500 * std.time.ns_per_ms);
            if (loop) |list_loop_ptr| {
                _ = c.pw_main_loop_quit(list_loop_ptr);
            }
        }
    };

    const quit_thread = try std.Thread.spawn(.{}, Quitter.run, .{list_loop});
    defer quit_thread.join();

    _ = c.pw_main_loop_run(list_loop);

    const default_sink_name = list_data.default_sink;
    const default_source_name = list_data.default_source;
    const configured_sink_name = list_data.configured_sink;
    const configured_source_name = list_data.configured_source;
    const selected_sink_name = default_sink_name orelse configured_sink_name;
    const selected_source_name = default_source_name orelse configured_source_name;
    var targets = DefaultTargets{ .allocator = allococator };
    errdefer targets.deinit();
    if (selected_sink_name) |name| {
        targets.sink = try allococator.dupe(u8, name);
    }
    if (selected_source_name) |name| {
        targets.source = try allococator.dupe(u8, name);
    }

    std.debug.print("Audio devices:\n", .{});
    for (list_data.devices.items) |device| {
        const is_default_sink = nameMatches(default_sink_name, device.node_name);
        const is_default_source = nameMatches(default_source_name, device.node_name);
        const is_configured_sink = nameMatches(configured_sink_name, device.node_name);
        const is_configured_source = nameMatches(configured_source_name, device.node_name);

        std.debug.print(
            "  id {d}: {s} | {s} | {s}{s}{s}{s}{s}\n",
            .{
                device.id,
                device.media_class,
                device.node_name,
                device.node_desc,
                if (is_default_sink) " [default sink]" else "",
                if (is_default_source) " [default source]" else "",
                if (is_configured_sink and !is_default_sink) " [configured sink]" else "",
                if (is_configured_source and !is_default_source) " [configured source]" else "",
            },
        );
    }

    return targets;
}

fn onMetadataProperty(
    userdata: ?*anyopaque,
    subject: u32,
    key: [*c]const u8,
    type_: [*c]const u8,
    value: [*c]const u8,
) callconv(.c) c_int {
    _ = subject;
    _ = type_;
    if (userdata == null) return 0;
    if (key == null or value == null) return 0;

    const list_data: *ListData = @ptrCast(@alignCast(userdata));
    const key_slice = std.mem.span(@as([*:0]const u8, @ptrCast(key)));
    if (!std.mem.eql(u8, key_slice, "default.audio.sink") and
        !std.mem.eql(u8, key_slice, "default.audio.source") and
        !std.mem.eql(u8, key_slice, "default.configured.audio.sink") and
        !std.mem.eql(u8, key_slice, "default.configured.audio.source"))
    {
        return 0;
    }

    const value_slice = std.mem.span(@as([*:0]const u8, @ptrCast(value)));
    list_data.setDefault(key_slice, value_slice) catch {};
    return 0;
}

fn onRegistryGlobal(
    userdata: ?*anyopaque,
    id: u32,
    permissions: u32,
    type_: [*c]const u8,
    version: u32,
    props: ?*const c.struct_spa_dict,
) callconv(.c) void {
    _ = permissions;
    _ = version;
    if (userdata == null) return;
    const list_data: *ListData = @ptrCast(@alignCast(userdata));

    const type_z: [*:0]const u8 = @ptrCast(type_);
    const type_slice = std.mem.span(type_z);
    const node_type = std.mem.span(@as([*:0]const u8, @ptrCast(c.PW_TYPE_INTERFACE_Node)));
    const metadata_type = std.mem.span(@as([*:0]const u8, @ptrCast(c.PW_TYPE_INTERFACE_Metadata)));
    if (std.mem.eql(u8, type_slice, metadata_type)) {
        if (list_data.metadata == null) {
            if (list_data.registry) |registry| {
                var should_bind = true;
                if (props) |props_ptr| {
                    if (c.spa_dict_lookup(props_ptr, c.PW_KEY_METADATA_NAME)) |name_c| {
                        const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_c)));
                        should_bind = std.mem.eql(u8, name, "default");
                    }
                }
                if (!should_bind) return;
                const metadata_ptr = c.pw_registry_bind(
                    registry,
                    id,
                    c.PW_TYPE_INTERFACE_Metadata,
                    c.PW_VERSION_METADATA,
                    0,
                );
                if (metadata_ptr != null) {
                    const metadata: *c.pw_metadata = @ptrCast(metadata_ptr.?);
                    list_data.metadata = metadata;
                    _ = c.pw_metadata_add_listener(
                        metadata,
                        &list_data.metadata_listener,
                        &metadata_events,
                        list_data,
                    );
                }
            }
        }
        return;
    }
    if (!std.mem.eql(u8, type_slice, node_type)) return;

    const props_ptr = props orelse return;
    const media_class_c = c.spa_dict_lookup(props_ptr, c.PW_KEY_MEDIA_CLASS);
    if (media_class_c == null) return;
    const media_class = std.mem.span(@as([*:0]const u8, @ptrCast(media_class_c)));
    if (!isAudioSource(media_class) and !isAudioSink(media_class)) return;

    const node_name_c = c.spa_dict_lookup(props_ptr, c.PW_KEY_NODE_NAME);
    const node_desc_c = c.spa_dict_lookup(props_ptr, c.PW_KEY_NODE_DESCRIPTION);
    const node_name = if (node_name_c) |ptr| std.mem.span(@as([*:0]const u8, @ptrCast(ptr))) else "unknown";
    const node_desc = if (node_desc_c) |ptr| std.mem.span(@as([*:0]const u8, @ptrCast(ptr))) else "";

    const device_media_class_copy = list_data.allocator.dupe(u8, media_class) catch return;
    const node_name_copy = list_data.allocator.dupe(u8, node_name) catch {
        list_data.allocator.free(device_media_class_copy);
        return;
    };
    const node_desc_copy = list_data.allocator.dupe(u8, node_desc) catch {
        list_data.allocator.free(device_media_class_copy);
        list_data.allocator.free(node_name_copy);
        return;
    };
    const device = DeviceInfo{
        .id = id,
        .media_class = device_media_class_copy,
        .node_name = node_name_copy,
        .node_desc = node_desc_copy,
    };
    list_data.devices.append(list_data.allocator, device) catch {
        list_data.allocator.free(device_media_class_copy);
        list_data.allocator.free(node_name_copy);
        list_data.allocator.free(node_desc_copy);
    };
}

const PipewireAudio = struct {
    const sample_rate: u32 = 48_000;
    const channels: u32 = 2;
    const capture_seconds: u32 = 5;

    const AudioClip = struct {
        samples: []f32,
        used_samples: usize,
        sample_rate: u32,
        channels: u32,
    };

    const Shared = struct {
        loop: ?*c.pw_main_loop = null,
        completed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        expected: u32 = 2,
    };

    const Data = struct {
        stream: ?*c.pw_stream = null,
        channels: u32 = channels,
        sample_rate: u32 = sample_rate,
        samples: []f32 = &.{},
        sample_write_index: usize = 0,
        capture_complete: bool = false,
        shared: *Shared = undefined,
        label: []const u8 = "",
    };

    fn markComplete(data: *Data) void {
        if (data.capture_complete) return;
        data.capture_complete = true;
        const finished = data.shared.completed.fetchAdd(1, .seq_cst) + 1;
        if (finished >= data.shared.expected) {
            if (data.shared.loop) |loop| {
                _ = c.pw_main_loop_quit(loop);
            }
        }
    }

    fn onProcess(userdata: ?*anyopaque) callconv(.c) void {
        if (userdata == null) return;
        const data: *Data = @ptrCast(@alignCast(userdata));
        const stream = data.stream orelse return;

        const pwb = c.pw_stream_dequeue_buffer(stream) orelse return;
        defer _ = c.pw_stream_queue_buffer(stream, pwb);

        if (data.capture_complete) return;

        if (pwb.*.buffer == null) return;
        const buffer = pwb.*.buffer.?;
        if (buffer.*.n_datas == 0) return;

        const data_ptr = buffer.*.datas[0].data orelse return;
        const chunk = buffer.*.datas[0].chunk;
        if (chunk == null) return;

        const size: usize = @intCast(chunk.*.size);
        if (size == 0) return;

        const n_channels_usize: usize = @intCast(data.channels);
        const total_samples: usize = size / @sizeOf(f32);
        if (total_samples < n_channels_usize) return;
        const n_samples = total_samples - (total_samples % n_channels_usize);
        if (n_samples == 0) return;

        const aligned_ptr: *align(@alignOf(f32)) const anyopaque = @alignCast(data_ptr);
        const samples = @as([*]const f32, @ptrCast(aligned_ptr));

        const remaining = data.samples.len - data.sample_write_index;
        if (remaining == 0) {
            markComplete(data);
            return;
        }

        const to_copy = if (remaining < n_samples) remaining else n_samples;
        @memcpy(
            data.samples[data.sample_write_index .. data.sample_write_index + to_copy],
            samples[0..to_copy],
        );
        data.sample_write_index += to_copy;

        if (data.sample_write_index >= data.samples.len) {
            markComplete(data);
        }
    }

    fn onStreamParamChanged(userdata: ?*anyopaque, id: u32, param: [*c]const c.struct_spa_pod) callconv(.c) void {
        if (userdata == null) return;
        if (param == null or id != c.SPA_PARAM_Format) return;

        var media_type: u32 = 0;
        var media_subtype: u32 = 0;
        if (c_def.spa_format_parse(param, @ptrCast(&media_type), @ptrCast(&media_subtype)) < 0) return;
        if (media_type != c.SPA_MEDIA_TYPE_audio or media_subtype != c.SPA_MEDIA_SUBTYPE_raw) return;

        const data: *Data = @ptrCast(@alignCast(userdata));
        std.debug.print("{s} capturing rate:{d} channels:{d}\n", .{ data.label, data.sample_rate, data.channels });
    }

    fn onQuit(userdata: ?*anyopaque, signal_number: c_int) callconv(.c) void {
        _ = signal_number;
        if (userdata == null) return;
        const shared: *Shared = @ptrCast(@alignCast(userdata));
        if (shared.loop) |loop| {
            _ = c.pw_main_loop_quit(loop);
        }
    }

    pub fn run(alloc: std.mem.Allocator) !AudioClip {
        const total_frames: usize = @intCast(sample_rate * capture_seconds);
        const total_samples: usize = total_frames * @as(usize, @intCast(channels));
        const mic_samples = try alloc.alloc(f32, total_samples);
        errdefer alloc.free(mic_samples);
        const sink_samples = try alloc.alloc(f32, total_samples);
        errdefer alloc.free(sink_samples);

        c.pw_init(null, null);
        defer c.pw_deinit();

        var targets = try listAudioDevices(alloc);
        defer targets.deinit();

        var shared = Shared{};
        shared.loop = c.pw_main_loop_new(null) orelse return error.pw_main_loop_new;
        defer c.pw_main_loop_destroy(shared.loop);

        const loop = c.pw_main_loop_get_loop(shared.loop);
        _ = c.pw_loop_add_signal(loop, @intCast(std.posix.SIG.INT), onQuit, &shared);
        _ = c.pw_loop_add_signal(loop, @intCast(std.posix.SIG.TERM), onQuit, &shared);

        const mic_props = c.pw_properties_new(
            c.PW_KEY_MEDIA_TYPE,
            "Audio",
            c.PW_KEY_MEDIA_CATEGORY,
            "Capture",
            c.PW_KEY_MEDIA_ROLE,
            "Music",
            c.NULL,
        ) orelse return error.pw_properties_new;
        if (targets.source) |source_name| {
            const source_z = try alloc.dupeZ(u8, source_name);
            defer alloc.free(source_z);
            _ = c.pw_properties_set(mic_props, c.PW_KEY_TARGET_OBJECT, source_z);
        }

        const sink_props = c.pw_properties_new(
            c.PW_KEY_MEDIA_TYPE,
            "Audio",
            c.PW_KEY_MEDIA_CATEGORY,
            "Capture",
            c.PW_KEY_MEDIA_ROLE,
            "Music",
            c.NULL,
        ) orelse return error.pw_properties_new;
        _ = c.pw_properties_set(sink_props, c.PW_KEY_STREAM_CAPTURE_SINK, "true");
        if (targets.sink) |sink_name| {
            const sink_z = try alloc.dupeZ(u8, sink_name);
            defer alloc.free(sink_z);
            _ = c.pw_properties_set(sink_props, c.PW_KEY_TARGET_OBJECT, sink_z);
        }

        const stream_events = c.pw_stream_events{
            .version = c.PW_VERSION_STREAM_EVENTS,
            .param_changed = onStreamParamChanged,
            .process = onProcess,
        };

        var mic_data = Data{
            .shared = &shared,
            .samples = mic_samples,
            .label = "mic",
        };
        mic_data.stream = c.pw_stream_new_simple(
            loop,
            "audio-capture-mic",
            mic_props,
            &stream_events,
            &mic_data,
        ) orelse return error.pw_stream_new;
        defer c.pw_stream_destroy(mic_data.stream);

        var sink_data = Data{
            .shared = &shared,
            .samples = sink_samples,
            .label = "sink",
        };
        sink_data.stream = c.pw_stream_new_simple(
            loop,
            "audio-capture-sink",
            sink_props,
            &stream_events,
            &sink_data,
        ) orelse return error.pw_stream_new;
        defer c.pw_stream_destroy(sink_data.stream);

        // TODO: extract into function
        {
            var format_buffer = std.mem.zeroes([256]u8);
            var builder = c.spa_pod_builder{
                .data = @ptrCast(&format_buffer),
                .size = format_buffer.len,
            };

            const format = c_def.spa_pod_builder_add_object(
                &builder,
                c.SPA_TYPE_OBJECT_Format,
                c.SPA_PARAM_EnumFormat,
                .{
                    c.SPA_FORMAT_mediaType,
                    "I",
                    @as(i32, c.SPA_MEDIA_TYPE_audio),
                    c.SPA_FORMAT_mediaSubtype,
                    "I",
                    @as(i32, c.SPA_MEDIA_SUBTYPE_raw),
                    c.SPA_FORMAT_AUDIO_format,
                    "I",
                    @as(i32, c.SPA_AUDIO_FORMAT_F32),
                    c.SPA_FORMAT_AUDIO_rate,
                    "i",
                    @as(i32, sample_rate),
                    c.SPA_FORMAT_AUDIO_channels,
                    "i",
                    @as(i32, channels),
                },
            ) orelse return error.pw_format_build;

            var params = [_]*c.struct_spa_pod{@ptrCast(@alignCast(format))};
            const status = c.pw_stream_connect(
                mic_data.stream,
                c.PW_DIRECTION_INPUT,
                c.PW_ID_ANY,
                c.PW_STREAM_FLAG_AUTOCONNECT |
                    c.PW_STREAM_FLAG_MAP_BUFFERS |
                    c.PW_STREAM_FLAG_RT_PROCESS,
                @ptrCast(params[0..].ptr),
                @intCast(params.len),
            );
            if (status < 0) return error.pw_stream_connect;
        }

        {
            var format_buffer = std.mem.zeroes([256]u8);
            var builder = c.spa_pod_builder{
                .data = @ptrCast(&format_buffer),
                .size = format_buffer.len,
            };

            const format = c_def.spa_pod_builder_add_object(
                &builder,
                c.SPA_TYPE_OBJECT_Format,
                c.SPA_PARAM_EnumFormat,
                .{
                    c.SPA_FORMAT_mediaType,
                    "I",
                    @as(i32, c.SPA_MEDIA_TYPE_audio),
                    c.SPA_FORMAT_mediaSubtype,
                    "I",
                    @as(i32, c.SPA_MEDIA_SUBTYPE_raw),
                    c.SPA_FORMAT_AUDIO_format,
                    "I",
                    @as(i32, c.SPA_AUDIO_FORMAT_F32),
                    c.SPA_FORMAT_AUDIO_rate,
                    "i",
                    @as(i32, sample_rate),
                    c.SPA_FORMAT_AUDIO_channels,
                    "i",
                    @as(i32, channels),
                },
            ) orelse return error.pw_format_build;

            var params = [_]*c.struct_spa_pod{@ptrCast(@alignCast(format))};
            const status = c.pw_stream_connect(
                sink_data.stream,
                c.PW_DIRECTION_INPUT,
                c.PW_ID_ANY,
                c.PW_STREAM_FLAG_AUTOCONNECT |
                    c.PW_STREAM_FLAG_MAP_BUFFERS |
                    c.PW_STREAM_FLAG_RT_PROCESS,
                @ptrCast(params[0..].ptr),
                @intCast(params.len),
            );
            if (status < 0) return error.pw_stream_connect;
        }

        _ = c.pw_main_loop_run(shared.loop);

        const mic_used = mic_data.sample_write_index;
        const sink_used = sink_data.sample_write_index;
        const mixed_len = if (mic_used > sink_used) mic_used else sink_used;
        if (mixed_len == 0) return error.NoAudioCaptured;

        const mixed_samples = try alloc.alloc(f32, mixed_len);
        errdefer alloc.free(mixed_samples);

        var idx: usize = 0;
        while (idx < mixed_len) : (idx += 1) {
            var mixed: f32 = 0.0;
            if (idx < mic_used) mixed += mic_samples[idx];
            if (idx < sink_used) mixed += sink_samples[idx];
            if (mixed > 1.0) mixed = 1.0;
            if (mixed < -1.0) mixed = -1.0;
            mixed_samples[idx] = mixed;
        }

        alloc.free(mic_samples);
        alloc.free(sink_samples);

        return .{
            .samples = mixed_samples,
            .used_samples = mixed_len,
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }
};

pub fn record_audio_clip(allocator: std.mem.Allocator) !void {
    const clip = try PipewireAudio.run(allocator);
    defer allocator.free(clip.samples);
    try ffmpeg.writeAudioToFile(
        allocator,
        clip.sample_rate,
        clip.channels,
        clip.samples[0..clip.used_samples],
    );
}
