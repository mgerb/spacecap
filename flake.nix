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
          overlays = [
            (_final: prev: {
              # NOTE: This can be removed with: https://github.com/mgerb/spacecap/issues/144
              # GTK's optional file-search integration pulls TinySPARQL into the
              # AppImage, which then tries to link sqlite3. This can be avoided
              # by disabling it here.
              gtk3 = prev.gtk3.override {trackerSupport = false;};
            })
          ];
        };
        zigpkgs = zig.packages.${system};
      in {
        packages = {
          zls-custom = pkgs.stdenv.mkDerivation {
            pname = "zls";
            version = "0.17.0-dev.44+8da87d4f";
            src = pkgs.fetchurl {
              url = "https://builds.zigtools.org/zls-x86_64-linux-0.17.0-dev.44+8da87d4f.tar.xz";
              sha256 = "sha256-nqIj+ohCRnFVWRG+ul1okZGuCApOgn71x2yPZOOf8pY=";
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
              url = "https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage";
              sha256 = "sha256-wgzXHjpOO4DDSDzveTzaP06ZCsoUAU0jxUTKPOEnC00=";
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
            zigpkgs.master
            self.packages.${system}.zls-custom
            self.packages.${system}.linuxdeploy
            self.packages.${system}.appimagetool

            shaderc
            vulkan-loader
            vulkan-validation-layers
            vulkan-tools
            wayland
            libxkbcommon
            zlib
            glib

            # Required for unit tests. Tests need to run on
            # Github action servers, which don't have
            # graphics. We can use lavapipe. Tests are
            # configured to use it in build.zig. This means
            # all tests use software decoding. See
            # LAVAPIPE_ICD below.
            mesa

            # Required for linux tray icon.
            gtk3
            libayatana-appindicator

            appimage-run

            # For configuring ffmpeg headers
            nasm
            pkg-config

            # Windows
            pkgsCross.mingwW64.vulkan-loader
            pkgsCross.mingwW64.zlib
            pkgsCross.mingwW64.stdenv.cc
          ];

          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
          LAVAPIPE_ICD = "${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.x86_64.json";
          VULKAN_SDK_PATH_WINDOWS = "${pkgs.pkgsCross.mingwW64.vulkan-loader}/bin";
          MINGW_ZLIB_PATH = "${pkgs.pkgsCross.mingwW64.zlib}";
          GTK3_LIB = "${pkgs.gtk3}/lib/libgtk-3.so.0";
          APPINDICATOR_LIB = "${pkgs.libayatana-appindicator}/lib/libayatana-appindicator3.so.1";

          # Required for Github actions or non-NixOS machines.
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.vulkan-loader
            pkgs.glib
            pkgs.zlib

            # Required for linux tray icon.
            pkgs.gtk3
            pkgs.libayatana-appindicator

            # SDL runtime libs
            pkgs.wayland
            pkgs.libxkbcommon
          ];
        };
      }
    );
}
