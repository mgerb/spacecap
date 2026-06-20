<p align="center">
    <img align="center" src="./packaging/logo_blue.png"/>
</p>
<h1 align="center">Spacecap</h1>

A hardware accelerated screen recording tool for Linux. _Still in development
(see features/roadmap below)_.

- Written in [Zig](https://ziglang.org/) (0.16.0).
- Video encoding with Vulkan Video ([vulkan-zig](https://github.com/Snektron/vulkan-zig)).
- UI built with [imgui](https://github.com/ocornut/imgui)/[SDL3](https://github.com/allyourcodebase/SDL3).
- Muxing/Audio encoding with [FFmpeg](https://www.ffmpeg.org/).

![screenshot2](./docs/screenshot_4.png)

## Installation

```sh
# Spacecap will be installed to ~/.local/bin/spacecap

# Install
curl -LsSf https://spacecap.org/install | sh

# Uninstall
curl -LsSf https://spacecap.org/install | sh -s -- --uninstall
```

## Features

- Desktop/window capture.
- Screen recording.
- Replay buffer - save last n seconds of video (buffered in memory).
- Capture preview.
- Global keybinds.

## Roadmap

- Screenshots.
- Video player/editor.
  - Simple video editor (trim start/end).
  - File browser to select videos to edit.
- Windows support.

## Requirements

- A GPU that supports Vulkan Video encoding.

**NOTE:** So far this has only been tested on an Nvidia GPU (RTX 3080). AMD will
be supported, I just have no way of testing at this time.

### Linux

- Wayland
- Pipewire

### Windows

- Windows is not yet supported. Spacecap is architected in such a way that it
  can be cross platform. For Windows support, the audio/video capture interfaces
  need to be implemented. It's on the roadmap, but is not currently a priority.

## Global Keybinds

### Linux

[xdg-desktop-portal global
shortcuts](https://wiki.archlinux.org/title/XDG_Desktop_Portal#List_of_backends_and_interfaces)
can be used if your desktop environment supports it, otherwise the Spacecap CLI
can be used to send commands.

e.g.

```sh
# Save replay
spacecap -s save-replay

# List available commands
spacecap -h
```

For example, here is what a config in [niri](https://github.com/YaLTeR/niri) would look like:

```kdl
binds {
    Mod+Shift+R hotkey-overlay-title="Spacecap: save replay" { spawn-sh "spacecap -s save-replay && notify-send 'Spacecap' 'Replay saved'"; }
}
```

## Development

[Nix](https://nixos.org/download/#download-nix) is required for development.

```sh
# Build
nix develop -c zig build -Dnix

# Run
nix develop -c zig build run -Dnix

# Test
nix develop -c zig build test -Dnix
```

## Logging

By default, Spacecap only writes error logs to `error.log`. Set the
`SPACECAP_LOG_LEVEL` environment variable to `debug`, `info`, `warning`, or
`error`.

Crash logs are written to `crash.log`, which happens when a panic occurs.

#### Log Location

- **Linux**: `$XDG_CONFIG_HOME/spacecap`, or `$HOME/.config/spacecap`
- **Windows**: `%APPDATA%\spacecap`.

## Troubleshooting

### Linux restore capture source stops working

Spacecap uses the XDG desktop portal screencast permission store to restore the
previous capture source. If the portal permission database gets corrupted,
restore may stop working even after selecting a source again. This has happened
to me after my main disk filled up unexpectedly.

To reset only the screencast portal permissions, delete the database and then
reboot.

```sh
# Delete
rm ~/.local/share/flatpak/db/screencast ~/.local/share/flatpak/db/screencast.bak

# OR move it to a backup
mv ~/.local/share/flatpak/db/screencast ~/.local/share/flatpak/db/screencast.bak

reboot
```
