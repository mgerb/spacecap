# Requires appimagetool and linuxdeploy.

set -euo pipefail

# Get page-aligned errors on some dynamic libs without this.
export NO_STRIP=1

rm -rf AppDir
rm -f zig-out/linux/spacecap-linux-x86_64.AppImage

# NOTE: Vulkan is excluded because system libraries should be used.
LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" linuxdeploy \
  --appdir AppDir \
  --executable zig-out/linux/spacecap \
  --desktop-file packaging/linux/spacecap.desktop \
  --icon-file packaging/logo_blue.png \
  --exclude-library libvulkan.so.1 \
  --library "$GTK3_LIB" \
  --library "$APPINDICATOR_LIB"

# NOTE: These extra libs are required for the tray icon functionality.
# Unfortunately we have to pull in gtk, which increases app size by 50% :(


env -u SOURCE_DATE_EPOCH APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 appimagetool AppDir zig-out/linux/spacecap-linux-x86_64.AppImage
rm -rf AppDir
