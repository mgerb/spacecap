#ifdef __MINGW32__
// Zig 0.17 Translate-C emits unused local declarations for MinGW's fortified
// wcscat/wcscpy wrappers and does not support some builtins in x86intrin.h,
// which makes the generated bindings fail to compile.
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#define __X86INTRIN_H 1
#endif

#include <errno.h>
#include <libavutil/opt.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixfmt.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vulkan.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
