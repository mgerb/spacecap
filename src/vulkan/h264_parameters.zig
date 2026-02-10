const std = @import("std");
const vk = @import("vulkan");

const H264MbSizeAlignment = 16;

fn alignSize(comptime T: type, size: T, alignment: T) T {
    std.debug.assert((alignment & (alignment - 1)) == 0); // Ensure power of two
    return (size + alignment - 1) & ~(@as(T, alignment - 1));
}

pub fn getStdVideoH264SequenceParameterSetVui(fps: u32) vk.StdVideoH264SequenceParameterSetVui {
    const flags = vk.StdVideoH264SpsVuiFlags{
        .video_signal_type_present_flag = true,
        .color_description_present_flag = true,
        .video_full_range_flag = false,
        .timing_info_present_flag = true,
        .fixed_frame_rate_flag = true,
    };

    var ret = std.mem.zeroes(vk.StdVideoH264SequenceParameterSetVui);
    ret.flags = flags;
    // "Unspecified" video format (H.264 Table E-2).
    ret.video_format = 5;
    // BT.709 primaries, transfer, and matrix (H.264 Table E-3/E-4/E-5).
    ret.colour_primaries = 1;
    ret.transfer_characteristics = 1;
    ret.matrix_coefficients = 1;
    ret.num_units_in_tick = 1;
    ret.time_scale = fps * 2;

    return ret;
}

pub fn getStdVideoH264SequenceParameterSet(
    width: u32,
    height: u32,
    p_vui: ?*const vk.StdVideoH264SequenceParameterSetVui,
) vk.StdVideoH264SequenceParameterSet {
    const mb_aligned_width = alignSize(u32, width, H264MbSizeAlignment);
    const mb_aligned_height = alignSize(u32, height, H264MbSizeAlignment);

    var ret = std.mem.zeroes(vk.StdVideoH264SequenceParameterSet);
    ret.profile_idc = .main;
    ret.level_idc = .@"4_1";
    ret.seq_parameter_set_id = 0;
    ret.chroma_format_idc = .@"420";
    ret.bit_depth_luma_minus_8 = 0;
    ret.bit_depth_chroma_minus_8 = 0;
    ret.log_2_max_frame_num_minus_4 = 0;
    ret.pic_order_cnt_type = .@"0";
    ret.max_num_ref_frames = 1;
    ret.pic_width_in_mbs_minus_1 = mb_aligned_width / H264MbSizeAlignment - 1;
    ret.pic_height_in_map_units_minus_1 = mb_aligned_height / H264MbSizeAlignment - 1;
    ret.flags = .{
        .direct_8x_8_inference_flag = true,
        .frame_mbs_only_flag = true,
        .vui_parameters_present_flag = true,
    };
    ret.p_sequence_parameter_set_vui = p_vui.?;
    ret.frame_crop_right_offset = mb_aligned_width - width;
    ret.frame_crop_bottom_offset = mb_aligned_height - height;

    ret.log_2_max_pic_order_cnt_lsb_minus_4 = 4;

    if (ret.frame_crop_right_offset > 0 or ret.frame_crop_bottom_offset > 0) {
        ret.flags.frame_cropping_flag = true;

        if (ret.chroma_format_idc == .@"420") {
            ret.frame_crop_right_offset >>= 1;
            ret.frame_crop_bottom_offset >>= 1;
        }
    }

    return ret;
}

pub fn getStdVideoH264PictureParameterSet() vk.StdVideoH264PictureParameterSet {
    var pps = std.mem.zeroes(vk.StdVideoH264PictureParameterSet);
    pps.flags = .{
        .deblocking_filter_control_present_flag = true,
        .entropy_coding_mode_flag = true,
    };

    return pps;
}

pub const FrameInfo = struct {
    const Self = @This();

    encode_h264_frame_info: vk.VideoEncodeH264PictureInfoKHR = std.mem.zeroes(vk.VideoEncodeH264PictureInfoKHR),
    std_picture_info: vk.StdVideoEncodeH264PictureInfo = std.mem.zeroes(vk.StdVideoEncodeH264PictureInfo),
    picture_info_flags: vk.StdVideoEncodeH264PictureInfoFlags = std.mem.zeroes(vk.StdVideoEncodeH264PictureInfoFlags),
    reference_lists: vk.StdVideoEncodeH264ReferenceListsInfo = std.mem.zeroes(vk.StdVideoEncodeH264ReferenceListsInfo),
    slice_header_flags: vk.StdVideoEncodeH264SliceHeaderFlags = std.mem.zeroes(vk.StdVideoEncodeH264SliceHeaderFlags),
    slice_header: vk.StdVideoEncodeH264SliceHeader = std.mem.zeroes(vk.StdVideoEncodeH264SliceHeader),
    slice_info: vk.VideoEncodeH264NaluSliceInfoKHR = std.mem.zeroes(vk.VideoEncodeH264NaluSliceInfoKHR),

    pub fn init(
        self: *Self,
        frame_count: u32,
        sps: vk.StdVideoH264SequenceParameterSet,
        pps: vk.StdVideoH264PictureParameterSet,
        use_constant_qp: bool,
    ) void {
        const is_i_frame = frame_count == 0;
        const max_pic_order_count_lsb = @as(u32, 1) << @as(u5, @intCast((sps.log_2_max_pic_order_cnt_lsb_minus_4 + @as(u32, 4))));

        self.slice_header_flags.direct_spatial_mv_pred_flag = true;
        self.slice_header_flags.num_ref_idx_active_override_flag = false;

        self.slice_header.flags = self.slice_header_flags;
        self.slice_header.slice_type = if (is_i_frame) .i else .p;
        self.slice_header.cabac_init_idc = .@"0";
        self.slice_header.disable_deblocking_filter_idc = .disabled;
        self.slice_header.slice_alpha_c_0_offset_div_2 = 0;
        self.slice_header.slice_beta_offset_div_2 = 0;

        self.slice_info.s_type = .video_encode_h264_nalu_slice_info_khr;
        self.slice_info.p_next = null;
        self.slice_info.p_std_slice_header = &self.slice_header;
        self.slice_info.constant_qp = if (use_constant_qp) pps.pic_init_qp_minus_26 + 26 else 0;

        self.picture_info_flags.idr_pic_flag = is_i_frame;
        self.picture_info_flags.is_reference = true;
        self.picture_info_flags.adaptive_ref_pic_marking_mode_flag = false;
        self.picture_info_flags.no_output_of_prior_pics_flag = is_i_frame;

        self.std_picture_info.flags = self.picture_info_flags;
        self.std_picture_info.seq_parameter_set_id = 0;
        self.std_picture_info.pic_parameter_set_id = pps.pic_parameter_set_id;
        self.std_picture_info.idr_pic_id = 0;
        self.std_picture_info.primary_pic_type = if (is_i_frame) .idr else .p;
        self.std_picture_info.frame_num = frame_count;

        self.std_picture_info.pic_order_cnt = @as(i32, @intCast((frame_count * 2) % max_pic_order_count_lsb));
        self.reference_lists.num_ref_idx_l_0_active_minus_1 = 0;
        self.reference_lists.num_ref_idx_l_1_active_minus_1 = 0;
        @memset(&self.reference_lists.ref_pic_list_0, vk.STD_VIDEO_H264_NO_REFERENCE_PICTURE);
        @memset(&self.reference_lists.ref_pic_list_1, vk.STD_VIDEO_H264_NO_REFERENCE_PICTURE);
        if (!is_i_frame) {
            self.reference_lists.ref_pic_list_0[0] = @intFromBool((frame_count & 1) == 0);
        }
        self.std_picture_info.p_ref_lists = &self.reference_lists;

        self.encode_h264_frame_info.s_type = .video_encode_h264_picture_info_khr;
        self.encode_h264_frame_info.p_next = null;
        self.encode_h264_frame_info.nalu_slice_entry_count = 1;
        self.encode_h264_frame_info.p_nalu_slice_entries = @ptrCast(&self.slice_info);
        self.encode_h264_frame_info.p_std_picture_info = &self.std_picture_info;
    }
};
