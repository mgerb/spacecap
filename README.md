# Spacecap

A hardware accelerated replay capture tool focused on performance. Currently
only supports Linux. Still in early development (see roadmap below).

![screenshot2](./screenshots/screenshot_3.png)

<p align="center">(very early screenshot - UI still in development)</p>

- Written in [Zig](https://ziglang.org/).
- Hardware accelerated encoding with Vulkan Video ([vulkan-zig](https://github.com/Snektron/vulkan-zig)).
- UI built with [imgui](https://github.com/ocornut/imgui)/[SDL3](https://github.com/allyourcodebase/SDL3).

## Features

- Desktop/window/region capture.
- Save last n seconds of video (video buffered in memory).
- Global keybinds.

## Roadmap

- Screenshots.
- Toggle recording (currently only replays are supported).
- Video player/editor.
  - Simple video editor (trim start/end).
  - File browser to select videos to edit.
- Additional video output formats (mp4, mov, mkv, gif, etc.).
- Windows capture.

## Why would you want to use this?

You're looking for a lightweight and performant way to capture video replays.
The goal of Spacecap is to be as fast and resource efficient as possible. To do
this, frame buffers stay on the GPU (via dma-buff) for the entire duration of
the encoding pipeline.

## Requirements

- A GPU that supports Vulkan Video.

**NOTE:** Only tested on an Nvidia GPU so far. AMD will be supported, I just
have no way of testing at this time.

### Linux

- vulkan
- pipewire
- pipewire-pulse

#### Global Keybinds

If your version of Linux supports [xdg-desktop-portal global shortcuts](https://wiki.archlinux.org/title/XDG_Desktop_Portal#List_of_backends_and_interfaces)
then they can be configured that way. Alternatively, Spacecap runs an IPC
server, which can be communicated with via Spacecap CLI.

For example, here is what a config in [niri](https://github.com/YaLTeR/niri) would look like:

```kdl
binds {
    Mod+Shift+R hotkey-overlay-title="Spacecap: save replay" { spawn-sh "spacecap -s save-replay && notify-send 'Spacecap' 'Replay saved'"; }
}
```

Use `spacecap -h` to see available commands.

### Windows

Windows is not yet supported. Spacecap is architected in such a way
that it can be cross platform. For Windows support, the audio/video capture
interfaces need to be implemented. It's on the roadmap, but is not currently
a priority.

## Development

[Nix](https://nixos.org/download/#download-nix) is required for development,
unless you want to install all dependencies manually. See `flake.nix` if you'd
like to do so.

```sh
# Build
nix develop -c zig build -Dnix

# Run
nix develop -c zig build run -Dnix

# Test
nix develop -c zig build test -Dnix
```
