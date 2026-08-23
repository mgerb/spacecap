#ifdef __MINGW32__
// Zig 0.17 Translate-C emits unused local declarations for MinGW's fortified
// wcscat/wcscpy wrappers, which makes the generated bindings fail to compile.
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#endif

#include <errno.h>
#include <libavutil/opt.h>
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
