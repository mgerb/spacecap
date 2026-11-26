{
  description = "Spacecap screen recorder and development environment";

  inputs = {
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = {
    self,
    nixpkgs-unstable,
    nixpkgs-stable,
    ...
  }: let
    system = "x86_64-linux";
    pkgs-stable = import nixpkgs-stable {
      inherit system;
    };
    pkgs-unstable = import nixpkgs-unstable {
      inherit system;
    };
    # NOTE: This can be removed with: https://github.com/mgerb/spacecap/issues/144
    # GTK's optional file-search integration pulls TinySPARQL into the
    # AppImage, which then tries to link sqlite3. This can be avoided
    # by disabling it here.
    gtk3WithOverrides = pkgs-stable.gtk3.override {trackerSupport = false;};
    # The Portal does not need GIO SELinux or libmount support. Disable them
    # to drop libselinux, libmount, and libblkid runtime dependencies.
    glibWithOverrides = pkgs-stable.glib.overrideAttrs (old: {
      mesonFlags =
        (old.mesonFlags or [])
        ++ [
          "-Dselinux=disabled"
          "-Dlibmount=disabled"
        ];
    });
    spacecap = pkgs-stable.callPackage ./package.nix {
      zig_0_17 = pkgs-unstable.zig_0_17;
      glibWithOverrides = glibWithOverrides;
      gtk3WithOverrides = gtk3WithOverrides;
      src = pkgs-stable.lib.cleanSource self;
      version = builtins.head (builtins.elemAt (builtins.split ''\.version = "([^"]+)",'' (builtins.readFile ./build.zig.zon)) 1);
    };
  in {
    packages.${system} = {
      inherit spacecap;
      default = spacecap;

      zls-custom = pkgs-stable.stdenv.mkDerivation {
        pname = "zls";
        version = "0.17.0";
        src = pkgs-stable.fetchurl {
          url = "https://builds.zigtools.org/zls-x86_64-linux-0.17.0.tar.xz";
          sha256 = "sha256-36RRThhogD/fKuVoMsiLnUAAlNcOprsTa1e8yRrxAlg=";
        };
        sourceRoot = ".";
        installPhase = ''
          mkdir -p $out/bin
          mv zls $out/bin/
        '';
      };
      linuxdeploy = pkgs-stable.stdenv.mkDerivation {
        pname = "linuxdeploy";
        version = "continuous";
        src = pkgs-stable.fetchurl {
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
            exec ${pkgs-stable.appimage-run}/bin/appimage-run "\$appimage" "\$@"
          fi
          exec "\$appimage" "\$@"
          EOF
          chmod +x "$out/bin/linuxdeploy"
        '';
      };
      appimagetool = pkgs-stable.stdenv.mkDerivation {
        pname = "appimagetool";
        version = "1.9.1";
        src = pkgs-stable.fetchurl {
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
            exec ${pkgs-stable.appimage-run}/bin/appimage-run "\$appimage" "\$@"
          fi
          exec "\$appimage" "\$@"
          EOF
          chmod +x "$out/bin/appimagetool"
        '';
      };
    };

    devShells.${system}.default = pkgs-stable.mkShell {
      buildInputs = with pkgs-stable; [
        pkgs-unstable.zig_0_17
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
        glibWithOverrides

        # Required for unit tests. Tests need to run on
        # Github action servers, which don't have
        # graphics. We can use lavapipe. Tests are
        # configured to use it in build.zig. This means
        # all tests use software decoding. See
        # LAVAPIPE_ICD below.
        mesa

        # Required for linux tray icon.
        gtk3WithOverrides
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

      VK_LAYER_PATH = "${pkgs-stable.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
      LAVAPIPE_ICD = "${pkgs-stable.mesa}/share/vulkan/icd.d/lvp_icd.x86_64.json";
      VULKAN_SDK_PATH_WINDOWS = "${pkgs-stable.pkgsCross.mingwW64.vulkan-loader}/bin";
      MINGW_ZLIB_PATH = "${pkgs-stable.pkgsCross.mingwW64.zlib}";
      GTK3_LIB = "${gtk3WithOverrides}/lib/libgtk-3.so.0";
      APPINDICATOR_LIB = "${pkgs-stable.libayatana-appindicator}/lib/libayatana-appindicator3.so.1";

      # Required for Github actions or non-NixOS machines.
      LD_LIBRARY_PATH = pkgs-stable.lib.makeLibraryPath [
        pkgs-stable.vulkan-loader
        glibWithOverrides
        pkgs-stable.zlib

        # Required for linux tray icon.
        gtk3WithOverrides
        pkgs-stable.libayatana-appindicator

        # SDL runtime libs
        pkgs-stable.wayland
        pkgs-stable.libxkbcommon
      ];
    };
  };
}
