const c = @import("imguiz").imguiz;
const Store = @import("../store/store.zig").Store;
const String = @import("../string.zig").String;
const FileBrowserState = @import("../store/file_browser_store.zig").FileBrowserStore.State;

var select_tab = true;

pub fn draw(store: *Store, state: *const FileBrowserState) !void {
    const flags = if (select_tab) c.ImGuiTabItemFlags_SetSelected else c.ImGuiTabItemFlags_None;
    const visible = c.ImGui_BeginTabItem("Files", null, flags);
    select_tab = false;
    if (!visible) return;
    defer c.ImGui_EndTabItem();

    c.ImGui_Text("Sample text");

    if (state.files.paths.items.len == 0) {
        c.ImGui_TextDisabled("No files found");
        return;
    }

    for (state.files.paths.items) |file_path| {
        c.ImGui_TextUnformattedEx(file_path.bytes.ptr, file_path.bytes.ptr + file_path.bytes.len);
        if (c.ImGui_IsItemClicked()) {
            store.dispatch(.{ .file_browser = .{
                .select_file = try String.init(store.allocator, file_path.bytes),
            } });
        }
    }
}
