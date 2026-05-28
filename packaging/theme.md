# Spacecap Colors

#c24d3f
#6bdc9c

#5bbcff
#3791d2
#2a7cb7

#faf4eb
#f2e6cf
#e1ccad

#0a0a0a
#212121
#363636

## ImGui Theme

```cpp
void SetupImGuiStyle()
{
	// spacecap style from ImThemes
	ImGuiStyle& style = ImGui::GetStyle();

	style.Alpha = 1.0f;
	style.DisabledAlpha = 0.6f;
	style.WindowPadding = ImVec2(8.0f, 8.0f);
	style.WindowRounding = 1.0f;
	style.WindowBorderSize = 1.0f;
	style.WindowMinSize = ImVec2(32.0f, 32.0f);
	style.WindowTitleAlign = ImVec2(0.0f, 0.5f);
	style.WindowMenuButtonPosition = ImGuiDir_Left;
	style.ChildRounding = 1.0f;
	style.ChildBorderSize = 1.0f;
	style.PopupRounding = 1.0f;
	style.PopupBorderSize = 1.0f;
	style.FramePadding = ImVec2(4.0f, 3.0f);
	style.FrameRounding = 1.0f;
	style.FrameBorderSize = 0.0f;
	style.ItemSpacing = ImVec2(8.0f, 4.0f);
	style.ItemInnerSpacing = ImVec2(4.0f, 4.0f);
	style.CellPadding = ImVec2(4.0f, 2.0f);
	style.IndentSpacing = 21.0f;
	style.ColumnsMinSpacing = 6.0f;
	style.ScrollbarSize = 14.0f;
	style.ScrollbarRounding = 4.0f;
	style.GrabMinSize = 10.0f;
	style.GrabRounding = 4.0f;
	style.TabRounding = 4.0f;
	style.TabBorderSize = 0.0f;
	style.TabMinWidthForCloseButton = 0.0f;
	style.ColorButtonPosition = ImGuiDir_Right;
	style.ButtonTextAlign = ImVec2(0.5f, 0.5f);
	style.SelectableTextAlign = ImVec2(0.0f, 0.0f);

	style.Colors[ImGuiCol_Text] = ImVec4(0.98039216f, 0.95686275f, 0.92156863f, 1.0f);
	style.Colors[ImGuiCol_TextDisabled] = ImVec4(0.98039216f, 0.95686275f, 0.92156863f, 0.5064378f);
	style.Colors[ImGuiCol_WindowBg] = ImVec4(0.039215688f, 0.039215688f, 0.039215688f, 1.0f);
	style.Colors[ImGuiCol_ChildBg] = ImVec4(0.039215688f, 0.039215688f, 0.039215688f, 1.0f);
	style.Colors[ImGuiCol_PopupBg] = ImVec4(0.039215688f, 0.039215688f, 0.039215688f, 1.0f);
	style.Colors[ImGuiCol_Border] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_BorderShadow] = ImVec4(0.039215688f, 0.039215688f, 0.039215688f, 1.0f);
	style.Colors[ImGuiCol_FrameBg] = ImVec4(0.12941177f, 0.12941177f, 0.12941177f, 1.0f);
	style.Colors[ImGuiCol_FrameBgHovered] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_FrameBgActive] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_TitleBg] = ImVec4(0.039215688f, 0.039215688f, 0.039215688f, 1.0f);
	style.Colors[ImGuiCol_TitleBgActive] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_TitleBgCollapsed] = ImVec4(0.0f, 0.0f, 0.0f, 0.51f);
	style.Colors[ImGuiCol_MenuBarBg] = ImVec4(0.12941177f, 0.12941177f, 0.12941177f, 1.0f);
	style.Colors[ImGuiCol_ScrollbarBg] = ImVec4(0.039215688f, 0.039215688f, 0.039215688f, 1.0f);
	style.Colors[ImGuiCol_ScrollbarGrab] = ImVec4(0.88235295f, 0.8f, 0.6784314f, 1.0f);
	style.Colors[ImGuiCol_ScrollbarGrabHovered] = ImVec4(0.9490196f, 0.9019608f, 0.8117647f, 1.0f);
	style.Colors[ImGuiCol_ScrollbarGrabActive] = ImVec4(0.9490196f, 0.9019608f, 0.8117647f, 1.0f);
	style.Colors[ImGuiCol_CheckMark] = ImVec4(0.9490196f, 0.9019608f, 0.8117647f, 1.0f);
	style.Colors[ImGuiCol_SliderGrab] = ImVec4(0.21568628f, 0.5686275f, 0.8235294f, 1.0f);
	style.Colors[ImGuiCol_SliderGrabActive] = ImVec4(0.21568628f, 0.5686275f, 0.8235294f, 1.0f);
	style.Colors[ImGuiCol_Button] = ImVec4(0.16470589f, 0.4862745f, 0.7176471f, 1.0f);
	style.Colors[ImGuiCol_ButtonHovered] = ImVec4(0.21568628f, 0.5686275f, 0.8235294f, 1.0f);
	style.Colors[ImGuiCol_ButtonActive] = ImVec4(0.21568628f, 0.5686275f, 0.8235294f, 1.0f);
	style.Colors[ImGuiCol_Header] = ImVec4(0.12941177f, 0.12941177f, 0.12941177f, 1.0f);
	style.Colors[ImGuiCol_HeaderHovered] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_HeaderActive] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_Separator] = ImVec4(0.12941177f, 0.12941177f, 0.12941177f, 1.0f);
	style.Colors[ImGuiCol_SeparatorHovered] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_SeparatorActive] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_ResizeGrip] = ImVec4(0.12941177f, 0.12941177f, 0.12941177f, 1.0f);
	style.Colors[ImGuiCol_ResizeGripHovered] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_ResizeGripActive] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_Tab] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_TabHovered] = ImVec4(0.21568628f, 0.5686275f, 0.8235294f, 1.0f);
	style.Colors[ImGuiCol_TabActive] = ImVec4(0.16470589f, 0.4862745f, 0.7176471f, 1.0f);
	style.Colors[ImGuiCol_TabUnfocused] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_TabUnfocusedActive] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_PlotLines] = ImVec4(0.88235295f, 0.8f, 0.6784314f, 1.0f);
	style.Colors[ImGuiCol_PlotLinesHovered] = ImVec4(0.21568628f, 0.5686275f, 0.8235294f, 1.0f);
	style.Colors[ImGuiCol_PlotHistogram] = ImVec4(0.88235295f, 0.8f, 0.6784314f, 1.0f);
	style.Colors[ImGuiCol_PlotHistogramHovered] = ImVec4(0.21568628f, 0.5686275f, 0.8235294f, 1.0f);
	style.Colors[ImGuiCol_TableHeaderBg] = ImVec4(0.12941177f, 0.12941177f, 0.12941177f, 1.0f);
	style.Colors[ImGuiCol_TableBorderStrong] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_TableBorderLight] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_TableRowBg] = ImVec4(0.039215688f, 0.039215688f, 0.039215688f, 1.0f);
	style.Colors[ImGuiCol_TableRowBgAlt] = ImVec4(1.0f, 0.99999f, 0.99999f, 0.06f);
	style.Colors[ImGuiCol_TextSelectedBg] = ImVec4(0.21176471f, 0.21176471f, 0.21176471f, 1.0f);
	style.Colors[ImGuiCol_DragDropTarget] = ImVec4(0.21568628f, 0.5686275f, 0.8235294f, 1.0f);
	style.Colors[ImGuiCol_NavHighlight] = ImVec4(0.21568628f, 0.5686275f, 0.8235294f, 1.0f);
	style.Colors[ImGuiCol_NavWindowingHighlight] = ImVec4(0.98039216f, 0.95686275f, 0.92156863f, 0.19607843f);
	style.Colors[ImGuiCol_NavWindowingDimBg] = ImVec4(0.98039216f, 0.95686275f, 0.92156863f, 0.19742489f);
	style.Colors[ImGuiCol_ModalWindowDimBg] = ImVec4(0.98039216f, 0.95686275f, 0.92156863f, 0.19742489f);
}
```
