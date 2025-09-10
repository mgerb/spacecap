{
  description = "DevShell using nixpkgs-unstable";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [];
        };
        zigpkgs = zig.packages.${system};
      in {
        packages = {
          zls-custom = pkgs.stdenv.mkDerivation {
            pname = "zls";
            version = "0.15.0";
            src = pkgs.fetchurl {
              url = "https://builds.zigtools.org/zls-x86_64-linux-0.15.0.tar.xz";
              sha256 = "sha256-UIv+P9Y30qAvB/P8faiQA1H0BxFrA2hcXa4mtPAaMN4=";
            };
            sourceRoot = ".";
            installPhase = ''
              mkdir -p $out/bin
              mv zls $out/bin/
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zigpkgs."0.15.1"
            self.packages.${system}.zls-custom

            shaderc
            sdl3
            libxkbcommon
            vulkan-loader
            vulkan-validation-layers
            vulkan-tools
            pipewire
            glib
            libdrm
            wayland

            # For configuring ffmpeg headers
            nasm
            pkg-config
            ffmpeg

            # Windows
            pkgsCross.mingwW64.vulkan-loader
            pkgsCross.mingwW64.sdl3

            # NOTE: no longer needed since switching build target - may be needed if changing zig build to explicitly target linux
            # glibc
          ];

          # include paths
          LIBDRM_DEV = "${pkgs.libdrm.dev}/include";
          GLIB_OUT = "${pkgs.glib.out}/lib/glib-2.0/include";
          GLIB_DEV = "${pkgs.glib.dev}/include/glib-2.0";
          PIPEWIRE_DEV = "${pkgs.pipewire.dev}/include";
          SDL3_DEV = "${pkgs.sdl3.dev}/include";
          SDL3_WINDOWS = "${pkgs.pkgsCross.mingwW64.sdl3.out}/bin";
          LIBXKBCOMMON = "${pkgs.libxkbcommon}/lib";

          # library paths
          PIPEWIRE_LIB = "${pkgs.pipewire}";
          SDL3 = "${pkgs.sdl3}/lib";
          GLIB = "${pkgs.glib.out}/lib";
          LIBDRM = "${pkgs.libdrm}/lib";

          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
          VULKAN_SDK_PATH = "${pkgs.vulkan-loader}/lib";
          VULKAN_SDK_PATH_WINDOWS = "${pkgs.pkgsCross.mingwW64.vulkan-loader}/bin";

          LD_LIBRARY_PATH = "${pkgs.wayland}/lib:$LD_LIBRARY_PATH";
        };
      }
    );
}
