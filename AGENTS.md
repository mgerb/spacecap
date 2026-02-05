# AGENTS.md

## Purpose

This repository contains **Spacecap**, a cross-platform (Linux/Windows) screen recording app written in Zig.
Current day-to-day development is Linux-first.

## Build And Test Commands

- Build only:
  ```sh
  nix develop -c zig build -Dnix
  ```
- Run app:
  ```sh
  nix develop -c zig build run -Dnix
  ```
- Run unit tests:

  ```sh
  nix develop -c zig build test -Dnix
  ```

- Build release appimage
  ```sh
  nix develop -c zig build -Dappimage -Doptimize=ReleaseFast
  ```

Don't worry about running zig fmt.

Use `-Doptimize=ReleaseFast` when explicitly validating release behavior.

## Repo Map

- `src/main.zig`: app entrypoint and top-level wiring.
- `src/ui/`: ImGui-based UI.
- `src/vulkan/`: Vulkan + video encoding/rendering code.
- `src/capture/video/`: platform-specific video capture.
- `src/capture/audio/`: platform-specific audio capture.
- `src/global_shortcuts/`: platform shortcut integrations.
- `build.zig`: build graph, shared deps, platform linkage, run/test steps.
- `common/shaders/`: shader sources compiled during build.

## Agent Workflow Expectations

- Keep changes focused and minimal; avoid broad refactors unless requested.
- Prefer fixing root causes over adding local workarounds.
- Match existing Zig style and naming in touched files.
- After code changes, run at least relevant tests or build steps.
- If you encounter a nix build error involving sqlite wait for the user to fix
  the issue before proceeding. Do not try to change the XDG_CACHE_HOME.

## Platform And Dependency Notes

- Linux builds rely on Nix-provided env vars and libraries (SDL3, PipeWire, Vulkan, FFmpeg, GLib/libportal).
- Shader compilation uses `glslc` from the environment.
- Windows build targets exist in `build.zig`, but feature completeness is behind Linux.
- `build.zig` currently forces LLVM backend for Linux executable builds (`.use_llvm = true`). Do not change this unless specifically working on linker/toolchain issues.

## Misc docs

Enable pipewire debug logs.

```sh
export PIPEWIRE_DEBUG=4
```
