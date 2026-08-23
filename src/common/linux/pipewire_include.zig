const std = @import("std");
const pw = @import("pipewire").c;

pub const c = @import("linux_c");

/// NOTE: The following are definitions where Zig has trouble converting the C code.
pub const c_def = struct {
    pub extern fn spa_format_audio_raw_parse(
        arg_format: [*c]const pw.struct_spa_pod,
        arg_info: [*c]pw.struct_spa_audio_info_raw,
    ) callconv(.c) c_int;

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
        return pw.spa_pod_builder_pop(b, &_f);
    }
};
