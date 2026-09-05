#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <linux|windows> <output_dir> <ffmpeg_src_dir> <vulkan_headers_dir>" >&2
  exit 2
fi

target="$1"
output_dir="$2"
ffmpeg_src_dir="$3"
vulkan_headers_dir="$4"
build_dir="$output_dir/build"
install_prefix="$output_dir/install"

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
  --enable-vulkan
  --enable-hwaccel=h264_vulkan,hevc_vulkan
  --disable-runtime-cpudetect
  --enable-protocol=file
  --enable-demuxer=avi,matroska,mov
  --enable-parser=av1,h264,hevc,opus,vorbis,vp8,vp9
  --enable-decoder=av1,h264,hevc,opus,vorbis,vp8,vp9,aac,mp3,msmpeg4v2
  --enable-muxer=3g2,3gp,avi,f4v,ipod,ismv,matroska,mov,mp4,psp,wav,webm
  --enable-encoder=aac,pcm_f32le,png
  --enable-zlib
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
      --enable-w32threads
      --disable-os2threads
      --enable-cross-compile
      --target-os=mingw32
      --arch=x86_64
      --cross-prefix=x86_64-w64-mingw32-
      --pkg-config=false
    )
    ;;
esac

# The extra flags are just to ignore compilation warnings.
CFLAGS="-I$vulkan_headers_dir/include -Wno-unused-function -Wno-unused-label" ./configure \
  --prefix="$install_prefix" \
  "${common_configure_flags[@]}" \
  "${target_configure_flags[@]}"

make -j ECFLAGS="-Wno-stack-usage"
make install ECFLAGS="-Wno-stack-usage"
