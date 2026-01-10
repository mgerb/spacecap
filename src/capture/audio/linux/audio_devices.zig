//// Utilities to list all available audio devices.

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const c = @import("../../../common/linux/pipewire_include.zig").c;
const AudioDeviceList = @import("../audio_capture.zig").AudioDeviceList;
const AudioDeviceType = @import("../audio_capture.zig").AudioDeviceType;

const log = std.log.scoped(.audio_devices);

const DeviceInfo = struct {
    id: u32,
    media_class: []const u8,
    node_name: []const u8,
    node_desc: []const u8,
};

const ListData = struct {
    arena: *ArenaAllocator,
    devices: std.ArrayList(DeviceInfo),
    default_sink: ?[]const u8 = null,
    default_source: ?[]const u8 = null,
    configured_sink: ?[]const u8 = null,
    configured_source: ?[]const u8 = null,
    registry: ?*c.pw_registry = null,
    metadata: ?*c.pw_metadata = null,
    metadata_listener: c.spa_hook = undefined,

    fn init(allocator: std.mem.Allocator, registry: *c.pw_registry) !ListData {
        const arena = try allocator.create(ArenaAllocator);
        arena.* = .init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }

        return .{
            .arena = arena,
            .devices = try std.ArrayList(DeviceInfo).initCapacity(arena.allocator(), 0),
            .registry = registry,
        };
    }

    fn deinit(self: *ListData) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }

    fn setDefault(self: *ListData, key: []const u8, value: []const u8) !void {
        const trimmed = if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
            value[1 .. value.len - 1]
        else
            value;
        const allocator = self.arena.allocator();
        const parsed_name = parseDefaultName(allocator, trimmed);
        const selected_name = parsed_name orelse try allocator.dupe(u8, trimmed);

        if (std.mem.eql(u8, key, "default.audio.sink")) {
            self.default_sink = selected_name;
        } else if (std.mem.eql(u8, key, "default.audio.source")) {
            self.default_source = selected_name;
        } else if (std.mem.eql(u8, key, "default.configured.audio.sink")) {
            self.configured_sink = selected_name;
        } else if (std.mem.eql(u8, key, "default.configured.audio.source")) {
            self.configured_source = selected_name;
        }
    }

    /// Parse PipeWire metadata JSON and return the `"name"` field.
    /// Caller owns the memory.
    fn parseDefaultName(allocator: std.mem.Allocator, value: []const u8) ?[]const u8 {
        const ParsedDefaultName = struct {
            name: []const u8,
        };

        var parsed = std.json.parseFromSlice(ParsedDefaultName, allocator, value, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();

        return allocator.dupe(u8, parsed.value.name) catch return null;
    }
};

pub fn listAudioDevices(allocator: std.mem.Allocator) !AudioDeviceList {
    const list_loop = c.pw_main_loop_new(null) orelse return error.pw_main_loop_new;
    defer c.pw_main_loop_destroy(list_loop);

    const context = c.pw_context_new(c.pw_main_loop_get_loop(list_loop), null, 0) orelse return error.pw_context_new;
    defer c.pw_context_destroy(context);

    const core = c.pw_context_connect(context, null, 0) orelse return error.pw_context_connect;
    defer _ = c.pw_core_disconnect(core);

    const registry = c.pw_core_get_registry(core, c.PW_VERSION_REGISTRY, 0) orelse return error.pw_registry_new;
    var list_data = try ListData.init(allocator, registry);
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

    const selected_sink_name = list_data.default_sink orelse list_data.configured_sink;
    const selected_source_name = list_data.default_source orelse list_data.configured_source;

    var devices = try AudioDeviceList.init(allocator);
    errdefer devices.deinit();

    for (list_data.devices.items) |device| {
        const device_type: AudioDeviceType = if (isAudioSink(device.media_class)) .sink else .source;
        const device_name = if (device.node_desc.len > 0) device.node_desc else device.node_name;

        try devices.append(.{
            .id = device.node_name,
            .name = device_name,
            .device_type = device_type,
            .is_default = switch (device_type) {
                .sink => nameMatches(selected_sink_name, device.node_name),
                .source => nameMatches(selected_source_name, device.node_name),
            },
        });
    }

    return devices;
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
    if (std.mem.eql(u8, type_slice, c.PW_TYPE_INTERFACE_Metadata)) {
        if (list_data.metadata == null) {
            if (list_data.registry) |registry| {
                var should_bind = true;
                if (props) |props_ptr| {
                    if (c.spa_dict_lookup(props_ptr, c.PW_KEY_METADATA_NAME)) |name_c| {
                        const name = std.mem.span(name_c);
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
    if (!std.mem.eql(u8, type_slice, c.PW_TYPE_INTERFACE_Node)) return;

    const props_ptr = props orelse return;
    const media_class_c = c.spa_dict_lookup(props_ptr, c.PW_KEY_MEDIA_CLASS);
    if (media_class_c == null) return;
    const media_class = std.mem.span(media_class_c);
    if (!isAudioSource(media_class) and !isAudioSink(media_class)) return;

    const node_name_c = c.spa_dict_lookup(props_ptr, c.PW_KEY_NODE_NAME);
    const node_desc_c = c.spa_dict_lookup(props_ptr, c.PW_KEY_NODE_DESCRIPTION);
    const node_name = if (node_name_c) |ptr| std.mem.span(ptr) else "unknown";
    const node_desc = if (node_desc_c) |ptr| std.mem.span(ptr) else "";

    const allocator = list_data.arena.allocator();
    const device_media_class_copy = allocator.dupe(u8, media_class) catch return;
    const node_name_copy = allocator.dupe(u8, node_name) catch return;
    const node_desc_copy = allocator.dupe(u8, node_desc) catch return;
    const device = DeviceInfo{
        .id = id,
        .media_class = device_media_class_copy,
        .node_name = node_name_copy,
        .node_desc = node_desc_copy,
    };
    list_data.devices.append(allocator, device) catch {};
}

fn nameMatches(name: ?[]const u8, node_name: []const u8) bool {
    return name != null and std.mem.eql(u8, node_name, name.?);
}

const metadata_events = c.pw_metadata_events{
    .version = c.PW_VERSION_METADATA_EVENTS,
    .property = onMetadataProperty,
};

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
    const key_slice = std.mem.span(key);
    if (!std.mem.eql(u8, key_slice, "default.audio.sink") and
        !std.mem.eql(u8, key_slice, "default.audio.source") and
        !std.mem.eql(u8, key_slice, "default.configured.audio.sink") and
        !std.mem.eql(u8, key_slice, "default.configured.audio.source"))
    {
        log.warn("[onMetadataProperty] unknown audio device type", .{});
        return 0;
    }

    const value_slice = std.mem.span(value);
    list_data.setDefault(key_slice, value_slice) catch {};
    return 0;
}

fn isAudioSource(media_class: []const u8) bool {
    return std.mem.startsWith(u8, media_class, "Audio/Source");
}

fn isAudioSink(media_class: []const u8) bool {
    return std.mem.startsWith(u8, media_class, "Audio/Sink");
}
