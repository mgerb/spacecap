#ifdef __MINGW32__
// Zig's translate-c has trouble on some things. We may find out that
// we need these when this is actually implemented for Windows.
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
