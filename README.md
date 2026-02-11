# Spacecap

A hardware accelerated replay capture tool focused on performance. Currently
only supports Linux.

This is currently in the very early stages of development.

- Written in [Zig](https://ziglang.org/).
- Hardware accelerated encoding with Vulkan Video ([vulkan-zig](https://github.com/Snektron/vulkan-zig)).
- UI built with [imgui](https://github.com/ocornut/imgui)/[SDL3](https://github.com/allyourcodebase/SDL3).

## Why you might want to use this?

You play games on Linux and are looking for a light weight and performant
alternative to OBS for capturing video replays.

## What currently is working?

- Linux
  - Select desktop/window.
  - Video capture preview on UI.
  - Replay buffer with last n seconds of video/audio.
  - Output to .mp4 file.
  - Global keybinds via desktop portal.
- Windows
  - Binaries are built for Windows, but capture has not been implemented yet.

**NOTE:** I'm testing with an RTX 3080 GPU. I have no idea if AMD works. I don't have one to test on.

## Linux Requirements

- vulkan (and related graphics drivers)
- pipewire
- pipewire-pulse

### Installation

**NOTE:** A reboot may be required.

#### NixOS

There is currently not a Nix package published, but for now you can use
`appimage-run` to execute the appimage.

TODO: Add vulkan instructions.

```nix
{...}: {
  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = false;
    pulse.enable = true;
    wireplumber.enable = true;
  };

  environment.systemPackages = with pkgs; [
    appimage-run
  ];
}
```

#### Arch

TODO: Add vulkan instructions.

```sh
sudo pacman -S --needed wireplumber pipewire pipewire-pulse pipewire-alsa fuse3
systemctl --user --now enable pipewire pipewire-pulse wireplumber
```

#### Ubuntu

TODO: Add vulkan instructions.

```sh
sudo apt update
sudo apt install wireplumber pipewire pipewire-pulse pipewire-alsa fuse3
systemctl --user --now enable pipewire pipewire-pulse wireplumber
```

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

## Early Screenshot

![screenshot2](./screenshots/screenshot_3.png)

## Roadmap

- Set up pipeline to build and distribute binaries (appimage).
- ~~Audio recording.~~
- ~~Global keybinds~~
- Screenshots.
- ~~Show video preview on UI~~ - #9
- Video Player.
  - Simple video editor (trim start/end).
- Convert video output (mp4, gif, etc.).
- ~~Linux capture.~~
- Windows capture.
