// The one translation unit that compiles the vendored stb headers
// (stb_image, stb_image_resize2, stb_image_write; public domain, see
// LICENSE). Only the formats and features the codec layer uses are built,
// and every allocation goes through src/codec/budget.zig, which caps the
// bytes one decode may take so a lying header can't exhaust memory.

#include <stddef.h>

void *nomadfs_codec_malloc(size_t size);
void *nomadfs_codec_realloc(void *ptr, size_t size);
void nomadfs_codec_free(void *ptr);

// stb_image: decoders.
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_ONLY_GIF
#define STBI_ONLY_BMP
#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_NO_FAILURE_STRINGS
#define STBI_MAX_DIMENSIONS 16384
#if defined(__aarch64__)
#define STBI_NEON
#endif
#define STBI_MALLOC(sz) nomadfs_codec_malloc(sz)
#define STBI_REALLOC(p, newsz) nomadfs_codec_realloc(p, newsz)
#define STBI_FREE(p) nomadfs_codec_free(p)
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

// stb_image_resize2: downscaling.
#define STBIR_MALLOC(size, user_data) ((void)(user_data), nomadfs_codec_malloc(size))
#define STBIR_FREE(ptr, user_data) ((void)(user_data), nomadfs_codec_free(ptr))
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize2.h"

// stb_image_write: the JPEG encoder, writing through a callback.
#define STBI_WRITE_NO_STDIO
#define STBIW_MALLOC(sz) nomadfs_codec_malloc(sz)
#define STBIW_REALLOC(p, newsz) nomadfs_codec_realloc(p, newsz)
#define STBIW_FREE(p) nomadfs_codec_free(p)
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
