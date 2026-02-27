#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <linux|windows> <build_dir> <install_prefix> <ffmpeg_src_dir>" >&2
  exit 2
fi

target="$1"
build_dir="$2"
install_prefix="$3"
ffmpeg_src_dir="$4"

rm -rf "$build_dir/src" "$install_prefix"
mkdir -p "$build_dir/src"
cp -a "$ffmpeg_src_dir"/. "$build_dir/src"
cd "$build_dir/src"
make distclean >/dev/null 2>&1 || true

case "$target" in
  linux)
    ;;
  windows)
    ;;
  *)
    echo "unknown target '$target', expected linux or windows" >&2
    exit 2
    ;;
esac

# NOTE: If more ffmpeg features are required they must be included here.
common_configure_flags=(
  --disable-all
  --disable-debug
  --disable-autodetect
  --disable-doc
  --disable-network
  --disable-programs
  --disable-shared
  --enable-static
  --enable-avutil
  --enable-avcodec
  --enable-avformat
  --enable-avdevice
  --enable-avfilter
  --enable-swresample
  --enable-swscale
  --enable-small
  --disable-runtime-cpudetect
  --enable-protocol=file
  --enable-muxer=mov,mp4,wav
  --enable-encoder=aac,pcm_f32le
)

target_configure_flags=()
case "$target" in
  linux)
    target_configure_flags=()
    ;;
  windows)
    target_configure_flags=(
      --disable-x86asm
      --disable-pthreads
      --disable-w32threads
      --disable-os2threads
      --enable-cross-compile
      --target-os=mingw32
      --arch=x86_64
      --cross-prefix=x86_64-w64-mingw32-
      --pkg-config=false
    )
    ;;
esac

./configure \
  --prefix="$install_prefix" \
  "${common_configure_flags[@]}" \
  "${target_configure_flags[@]}"

make -j
make install
