const std = @import("std");
const pw = @import("pipewire").c;

pub const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
    @cInclude("linux/dma-buf.h");
    @cInclude("xf86drm.h");
});

/// NOTE: The following are definitions where Zig has trouble converting the C code.
pub const c_def = struct {
    pub const G_VARIANT_TYPE_VARDICT = @as(*const c.GVariantType, @ptrCast("a{sv}".ptr));
    pub const G_VARIANT_TYPE_ARRAY = @as(*const c.GVariantType, @ptrCast("a*".ptr));
    pub const G_VARIANT_TYPE_STRING = @as(*const c.GVariantType, @ptrCast("s".ptr));

    pub const PIPEWIRE_CAPTURE_DESKTOP = 1;
    pub const PIPEWIRE_CAPTURE_WINDOW = 2;

    // TODO: start - can get rid of these
    pub const DRM_FORMAT_MOD_VENDOR_NONE = 0;
    pub const DRM_FORMAT_RESERVED: u64 = (1 << 56) - 1;

    fn fourcc_mod_code(vendor: u64, val: u64) u64 {
        return (vendor << 56) | (val & 0x00ffffffffffffff);
    }

    pub const DRM_FORMAT_MOD_INVALID = fourcc_mod_code(DRM_FORMAT_MOD_VENDOR_NONE, DRM_FORMAT_RESERVED);
    pub const DRM_FORMAT_MOD_LINEAR = fourcc_mod_code(DRM_FORMAT_MOD_VENDOR_NONE, 0);
    // TODO: end

    pub extern fn spa_format_parse(
        arg_format: [*c]const pw.struct_spa_pod,
        arg_media_type: [*c]u32,
        arg_media_subtype: [*c]u32,
    ) callconv(.c) c_int;

    pub extern fn spa_format_video_raw_parse(
        arg_format: [*c]const pw.struct_spa_pod,
        arg_info: [*c]pw.struct_spa_video_info_raw,
    ) callconv(.c) c_int;

    pub extern fn spa_format_audio_raw_parse(
        arg_format: [*c]const pw.struct_spa_pod,
        arg_info: [*c]pw.struct_spa_audio_info_raw,
    ) callconv(.c) c_int;

    pub extern fn spa_pod_builder_long(arg_builder: [*c]pw.struct_spa_pod_builder, arg_val: i64) callconv(.c) c_int;

    pub extern fn spa_pod_builder_pop(
        arg_builder: [*c]pw.struct_spa_pod_builder,
        arg_frame: [*c]pw.struct_spa_pod_frame,
    ) callconv(.c) ?*anyopaque;

    // Replace the C macro because Zig has issues with it.
    pub fn spa_pod_builder_add_object(
        b: ?*pw.spa_pod_builder,
        type_: u32,
        id: u32,
        args: anytype,
    ) ?*anyopaque {
        var _f = std.mem.zeroes(pw.spa_pod_frame);
        _ = pw.spa_pod_builder_push_object(b, @ptrCast(&_f), type_, id);
        _ = @call(.auto, pw.spa_pod_builder_add, .{b} ++ args ++ .{@as(i32, 0)});
        return spa_pod_builder_pop(b, &_f);
    }
};
