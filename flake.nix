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
            version = "0.15.1";
            src = pkgs.fetchurl {
              url = "https://builds.zigtools.org/zls-x86_64-linux-0.15.1.tar.xz";
              sha256 = "sha256-O7OPUiyyMhPowHWsaxcCc/5JtCdLjBKwNMxJZAdAAGc=";
            };
            sourceRoot = ".";
            installPhase = ''
              mkdir -p $out/bin
              mv zls $out/bin/
            '';
          };
          linuxdeploy = pkgs.stdenv.mkDerivation {
            pname = "linuxdeploy";
            version = "continuous";
            src = pkgs.fetchurl {
              url = "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage";
              sha256 = "sha256-nFCMLLcA+ExmAufWDpnxgGodn5Doomw8nrvHxiu5UFs=";
            };
            dontUnpack = true;
            dontFixup = true;
            dontStrip = true;
            installPhase = ''
              mkdir -p $out/bin $out/libexec
              cp "$src" "$out/libexec/linuxdeploy-x86_64.AppImage"
              chmod +x "$out/libexec/linuxdeploy-x86_64.AppImage"
              cat > "$out/bin/linuxdeploy" <<EOF
              #!/usr/bin/env bash
              set -e
              appimage="$out/libexec/linuxdeploy-x86_64.AppImage"
              if [ -r /etc/os-release ] && grep -Eq '(^ID=nixos$|^ID_LIKE=.*nixos)' /etc/os-release; then
                exec ${pkgs.appimage-run}/bin/appimage-run "\$appimage" "\$@"
              fi
              exec "\$appimage" "\$@"
              EOF
              chmod +x "$out/bin/linuxdeploy"
            '';
          };
          appimagetool = pkgs.stdenv.mkDerivation {
            pname = "appimagetool";
            version = "1.9.1";
            src = pkgs.fetchurl {
              url = "https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage";
              sha256 = "sha256-7UzoTw2cr/ZvULzKb/bzWq5UzoE1QIs/ozq/w8s4TrA=";
            };
            dontUnpack = true;
            dontFixup = true;
            dontStrip = true;
            installPhase = ''
              mkdir -p $out/bin $out/libexec
              cp "$src" "$out/libexec/appimagetool-x86_64.AppImage"
              chmod +x "$out/libexec/appimagetool-x86_64.AppImage"
              cat > "$out/bin/appimagetool" <<EOF
              #!/usr/bin/env bash
              set -e
              appimage="$out/libexec/appimagetool-x86_64.AppImage"
              if [ -r /etc/os-release ] && grep -Eq '(^ID=nixos$|^ID_LIKE=.*nixos)' /etc/os-release; then
                exec ${pkgs.appimage-run}/bin/appimage-run "\$appimage" "\$@"
              fi
              exec "\$appimage" "\$@"
              EOF
              chmod +x "$out/bin/appimagetool"
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zigpkgs."0.15.2"
            self.packages.${system}.zls-custom
            self.packages.${system}.linuxdeploy
            self.packages.${system}.appimagetool

            shaderc
            vulkan-loader
            vulkan-validation-layers
            vulkan-tools
            wayland
            libportal
            zlib
            glib
            appimage-run

            # For configuring ffmpeg headers
            nasm
            pkg-config
            ffmpeg

            # Windows
            pkgsCross.mingwW64.vulkan-loader
          ];

          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
          VULKAN_SDK_PATH_WINDOWS = "${pkgs.pkgsCross.mingwW64.vulkan-loader}/bin";
          GLIB = "${pkgs.glib.out}/lib";
          LIBPORTAL = "${pkgs.libportal}/lib";

          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            # Required for Github actions. The runners don't provide fuse.
            pkgs.vulkan-loader
            pkgs.glib
            pkgs.libportal
            pkgs.ffmpeg
          ];
          # TODO: Separate devShell for building appimage.
        };
      }
    );
}
