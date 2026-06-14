#!/bin/sh

set -eu

APP_NAME="spacecap"
ARTIFACT_NAME="spacecap-linux-x86_64.AppImage"
CHECKSUMS_NAME="SHA256SUMS.txt"
RELEASES_URL="https://github.com/mgerb/spacecap/releases"
RAW_URL="https://raw.githubusercontent.com/mgerb/spacecap/main"
DESKTOP_URL="$RAW_URL/packaging/linux/spacecap.desktop"
ICON_URL="$RAW_URL/packaging/spacecap.png"
CHANNEL="stable"

err() {
    echo "Error: $1" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || err "The required command '$1' was not found."
}

download() {
    url="$1"
    dest="$2"

    curl -fL "$url" -o "$dest"
}

verify_checksum() {
    expected="$(awk -v artifact="$ARTIFACT_NAME" '$0 ~ artifact { print $1; found = 1 } END { if (!found) exit 1 }' "$CHECKSUMS_TMP")" \
        || err "The checksum file does not contain $ARTIFACT_NAME."
    actual="$(sha256sum "$APPIMAGE_TMP" | awk '{ print $1 }')"

    if [ "$actual" != "$expected" ]; then
        err "The checksum for $ARTIFACT_NAME does not match."
    fi
}

for arg in "$@"; do
    case "$arg" in
        --nightly)
            CHANNEL="nightly"
            ;;
        *)
            err "Unknown option: $arg"
            ;;
    esac
done

case "$CHANNEL" in
    stable)
        DOWNLOAD_URL="$RELEASES_URL/latest/download/$ARTIFACT_NAME"
        CHECKSUMS_URL="$RELEASES_URL/latest/download/$CHECKSUMS_NAME"
        ;;
    nightly)
        DOWNLOAD_URL="$RELEASES_URL/download/nightly/$ARTIFACT_NAME"
        CHECKSUMS_URL="$RELEASES_URL/download/nightly/$CHECKSUMS_NAME"
        ;;
esac

[ -n "${HOME:-}" ] || err "HOME is not set."

INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
DESKTOP_DIR="$DATA_DIR/applications"
DESKTOP_PATH="$DESKTOP_DIR/$APP_NAME.desktop"
ICON_DIR="$DATA_DIR/icons/hicolor/256x256/apps"
ICON_PATH="$ICON_DIR/$APP_NAME.png"

if [ "$(uname -s)" != "Linux" ]; then
    err "This installer only supports Linux."
fi

if [ "$(uname -m)" != "x86_64" ]; then
    err "This installer only supports Linux x86_64."
fi

need_cmd curl
need_cmd chmod
need_cmd mkdir
need_cmd mktemp
need_cmd mv
need_cmd rm
need_cmd awk
need_cmd sha256sum

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
APPIMAGE_TMP="$TMP_DIR/$ARTIFACT_NAME"
CHECKSUMS_TMP="$TMP_DIR/$CHECKSUMS_NAME"
DESKTOP_TMP="$TMP_DIR/$APP_NAME.desktop"
ICON_TMP="$TMP_DIR/$APP_NAME.png"

echo "Downloading $APP_NAME ($CHANNEL) from $DOWNLOAD_URL."
download "$DOWNLOAD_URL" "$APPIMAGE_TMP"

echo "Downloading checksums."
download "$CHECKSUMS_URL" "$CHECKSUMS_TMP"
verify_checksum

echo "Downloading the desktop entry."
download "$DESKTOP_URL" "$DESKTOP_TMP"

echo "Downloading the app icon."
download "$ICON_URL" "$ICON_TMP"

chmod +x "$APPIMAGE_TMP"
mkdir -p "$INSTALL_DIR" "$DESKTOP_DIR" "$ICON_DIR"
mv "$APPIMAGE_TMP" "$INSTALL_PATH"
mv "$DESKTOP_TMP" "$DESKTOP_PATH"
mv "$ICON_TMP" "$ICON_PATH"
trap - EXIT INT TERM

echo "Installed $APP_NAME to $INSTALL_PATH."
echo "Installed the desktop entry to $DESKTOP_PATH."
echo "Installed the app icon to $ICON_PATH."

case ":$PATH:" in
    *:"$INSTALL_DIR":*)
        ;;
    *)
        echo
        echo "$INSTALL_DIR is not on your PATH."
        echo "Add it to your shell profile, then restart your shell:"
        echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
        ;;
esac
