{
  lib,
  stdenv,
  zig_0_17,
  shaderc,
  nasm,
  pkg-config,
  autoPatchelfHook,
  vulkan-loader,
  glibWithOverrides,
  gtk3WithOverrides,
  zlib,
  libayatana-appindicator,
  wayland,
  libxkbcommon,
  src,
  version,
}: let
  spacecapDeps = zig_0_17.fetchDeps {
    pname = "spacecap";
    inherit version;
    inherit src;
    fetchAll = true;
    hash = "sha256-YdiGQDBjXEKmglunpH8f5tFqFpYu1hsqKxi669GInSE=";
  };
in
  stdenv.mkDerivation {
    pname = "spacecap";
    inherit version src;
    nativeBuildInputs = [zig_0_17 shaderc nasm pkg-config autoPatchelfHook];
    buildInputs = [
      vulkan-loader
      glibWithOverrides
      gtk3WithOverrides
      zlib
      libayatana-appindicator
      wayland
      libxkbcommon
    ];
    # We need to define these extra run time dependencies because they can't be
    # inferred at build time.
    runtimeDependencies = map lib.getLib [gtk3WithOverrides libayatana-appindicator];
    # SDL advertises optional integrations that we don't use.
    autoPatchelfIgnoreMissingDeps = [
      "libdecor-0.so.0"
      "libXss.so.1"
      "libXtst.so.6"
      "libsteam_api.so"
    ];
    # Preserve debug information for crash logs.
    dontStrip = true;
    dontSetZigDefaultFlags = true;
    zigBuildFlags = [
      "-Drelease-target"
      "-Dplatform=linux"
      "-Doptimize=ReleaseSafe"
    ];
    postConfigure = ''
      ln -s ${spacecapDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
    '';

    installPhase = ''
      runHook preInstall
      install -Dm755 zig-out/linux/spacecap "$out/bin/spacecap"
      install -Dm644 packaging/linux/org.spacecap.spacecap.desktop "$out/share/applications/org.spacecap.spacecap.desktop"
      install -Dm644 packaging/spacecap.svg "$out/share/icons/hicolor/scalable/apps/spacecap.svg"
      runHook postInstall
    '';

    meta = {
      description = "High performance screen recording software for Linux";
      homepage = "https://spacecap.org";
      license = lib.licenses.gpl3Only;
      mainProgram = "spacecap";
      platforms = ["x86_64-linux"];
    };
  }
