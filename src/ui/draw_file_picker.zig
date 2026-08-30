const std = @import("std");
const imguiz = @import("imguiz").imguiz;
const imgui_util = @import("./imgui_util.zig");

const MAX_PATH_BYTES = std.fs.max_path_bytes;
const PICKER_BUTTON_WIDTH: f32 = 34;

pub const Action = union(enum) {
    none,
    browse,
    set_path: [MAX_PATH_BYTES:0]u8,
};

fn FilePickerState(comptime id: [:0]const u8) type {
    return struct {
        const picker_id = id;
        var edit_buffer: ?[MAX_PATH_BYTES:0]u8 = null;
    };
}

/// Each comptime ID has its own local edit buffer.
pub fn draw(comptime id: [:0]const u8, path: []const u8) Action {
    const local_file_picker_state = FilePickerState(id);

    var buffer = local_file_picker_state.edit_buffer orelse blk: {
        var initial = std.mem.zeroes([MAX_PATH_BYTES:0]u8);
        const copy_len = @min(path.len, initial.len - 1);
        @memmove(initial[0..copy_len], path[0..copy_len]);
        break :blk initial;
    };
    var action: Action = .none;

    imguiz.ImGui_PushID(local_file_picker_state.picker_id.ptr);
    defer imguiz.ImGui_PopID();

    if (imguiz.ImGui_BeginTable("##file_picker_row", 2, imguiz.ImGuiTableFlags_SizingStretchProp)) {
        defer imguiz.ImGui_EndTable();

        imguiz.ImGui_TableSetupColumnEx("input", imguiz.ImGuiTableColumnFlags_WidthStretch, 1.0, 0);
        imguiz.ImGui_TableSetupColumnEx("button", imguiz.ImGuiTableColumnFlags_WidthFixed, PICKER_BUTTON_WIDTH, 0);

        _ = imguiz.ImGui_TableNextColumn();
        imgui_util.set_next_item_width_fill();
        _ = imguiz.ImGui_InputText("##path", &buffer, buffer.len, imguiz.ImGuiInputTextFlags_None);
        if (imguiz.ImGui_IsItemEdited()) {
            local_file_picker_state.edit_buffer = buffer;
        }
        if (imguiz.ImGui_IsItemDeactivatedAfterEdit()) {
            const updated_path = std.mem.sliceTo(&buffer, 0);
            if (updated_path.len > 0 and !std.mem.eql(u8, updated_path, path)) {
                action = .{ .set_path = buffer };
            }
            local_file_picker_state.edit_buffer = null;
        } else if (!imguiz.ImGui_IsItemActive()) {
            local_file_picker_state.edit_buffer = null;
        }

        _ = imguiz.ImGui_TableNextColumn();
        if (imguiz.ImGui_ButtonEx("...##picker", .{ .x = imgui_util.WIDTH_FILL, .y = 0 })) {
            action = .browse;
        }
        if (imguiz.ImGui_BeginItemTooltip()) {
            imguiz.ImGui_TextUnformatted("Choose directory");
            imguiz.ImGui_EndTooltip();
        }
    }

    return action;
}
