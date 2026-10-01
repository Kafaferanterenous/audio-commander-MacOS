/*
 * config.h for vendored libFLAC 1.4.3 in AudioCommander (goal #15, Ogg FLAC).
 *
 * libFLAC's private headers do `#include <config.h>`, which upstream generates
 * from config.h.in with autotools or CMake. AudioCommander builds every C file
 * with one hand-rolled loop (build.sh), so the handful of macros that matter
 * are written out here instead. Only a static, macOS, C99 build with the Ogg
 * mapping enabled is supported; nothing here is used on other platforms.
 *
 * Notes:
 *  - FLAC__NO_DLL: we link libFLAC statically (libtool -static), so the Windows
 *    dllimport/export dance in FLAC/export.h must be off. On non-Windows
 *    FLAC_API expands to visibility attributes unless this is defined.
 *  - FLAC__HAS_OGG: enables libFLAC's Ogg support (ogg_decoder_aspect.c), which
 *    is what lets FLAC__stream_decoder_init_ogg_* open FLAC-in-Ogg. libogg must
 *    be on the include path and linked in.
 *  - HAVE_LROUND: share/compat.h falls back to its own static lround when this
 *    is undefined, which then collides with <math.h>'s declaration.
 *  - SSE2 is baseline on x86_64 and NEON is always present on arm64, so those
 *    two intrinsic sets are enabled with no extra compiler flags. SSSE3/SSE4/
 *    AVX2/FMA would each need their own -m flag per file, so they stay off and
 *    their translation units compile to empty objects (pure-C fallbacks).
 *
 * Copied into vendored/flac/config.h by tools/vendor_flac.sh.
 */
#ifndef AC_LIBFLAC_CONFIG_H
#define AC_LIBFLAC_CONFIG_H

#define PACKAGE_NAME "FLAC"
#define PACKAGE_VERSION "1.4.3"
#define VERSION "1.4.3"

#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LROUND 1
/* HAVE_SYS_AUXV_H is deliberately NOT defined: there is no <sys/auxv.h> on
 * Darwin (it is Linux-only) and cpu.c includes it unconditionally when set.
 * HAVE_CPUID_H / HAVE_XMMINTRIN_H are x86-only (clang's <cpuid.h> #errors on
 * arm64), so they live in the arch branch below. */

#define FLAC__NO_DLL 1
#define FLAC__HAS_OGG_VORBIS_COMMENT 1
#define FLAC__HAS_OGG 1

#if defined(__x86_64__) || defined(__i386__)
#define FLAC__CPU_X86_64 1
#define FLAC__HAS_X86INTRIN 1
#define FLAC__SSE2_SUPPORTED 1
#define HAVE_CPUID_H 1
#define HAVE_XMMINTRIN_H 1
#elif defined(__arm64__) || defined(__aarch64__)
#define FLAC__CPU_ARM64 1
#define FLAC__HAS_NEONINTRIN 1
#endif

#endif /* AC_LIBFLAC_CONFIG_H */