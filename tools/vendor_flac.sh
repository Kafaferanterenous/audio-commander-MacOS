#!/bin/sh
# Vendor libogg 1.3.5 + libFLAC 1.4.3 for goal #15 (Ogg FLAC playback).
#
# Both projects are Xiph.Org, BSD-3-Clause ("Xiph license"), which satisfies
# the project's permissive-only dependency policy (MIT/Apache/BSD/MPL).
#
# Only the pieces the app needs are copied:
#   libogg  -> framing.c + bitwise.c and the public headers.
#   libFLAC -> the whole libFLAC library (decoder + encoder, the encoder comes
#              along because stream_decoder/metadata share its helpers) minus
#              the Win32 resource file, plus a hand-written config.h.
# The AVX2/FMA/SSSE3/SSE4 intrinsics translation units self-guard on
# FLAC__AVX2_SUPPORTED & friends, so they compile to empty objects here: the
# build enables only SSE2 (baseline on x86_64) and NEON (always present on
# arm64). Correctness is unaffected - only speed.
#
# Usage:  sh tools/vendor_flac.sh [src-dir]
# The source dir must contain flac-1.4.3.tar.xz and libogg-1.3.5.tar.gz. It
# defaults to $FLAC_VENDOR_SRC, else ~/Downloads/ac-vendor, else ./build/vendor.
# The tarballs are not committed (12 MB); fetch them from downloads.xiph.org:
#   curl -O https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz
#   curl -O https://downloads.xiph.org/releases/flac/flac-1.4.3.tar.xz
# then verify against the SHA-256 sums recorded below.
set -e
cd "$(dirname "$0")/.."

FLAC_TAR="flac-1.4.3.tar.xz"
OGG_TAR="libogg-1.3.5.tar.gz"

# First argument wins, then $FLAC_VENDOR_SRC, then a few conventional spots.
SRC=""
for cand in "$1" "${FLAC_VENDOR_SRC:-}" "$HOME/Downloads/ac-vendor" build/vendor; do
    [ -n "$cand" ] || continue
    if [ -f "$cand/$FLAC_TAR" ] && [ -f "$cand/$OGG_TAR" ]; then
        SRC="$cand"
        break
    fi
done
if [ -z "$SRC" ]; then
    echo "error: could not find $FLAC_TAR and $OGG_TAR." >&2
    echo "  looked in: \$1, \$FLAC_VENDOR_SRC, $HOME/Downloads/ac-vendor, build/vendor" >&2
    echo "  fetch them from downloads.xiph.org (see the header of this script)" >&2
    exit 1
fi
echo "--- sourcing tarballs from $SRC"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "--- SHA-256 as downloaded 2026-09-30 from downloads.xiph.org ---"
echo "  (recorded for reproducibility; xiph.org publishes no signed manifest"
echo "   here, so these are NOT an independent integrity proof)"
echo "  $FLAC_TAR  6c58e69cd22348f441b861092b825e591d0b822e106de6eb0ee4d05d27205b70"
echo "  $OGG_TAR   0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664"
shasum -a 256 "$SRC/$FLAC_TAR" "$SRC/$OGG_TAR"

tar xf "$SRC/$FLAC_TAR" -C "$WORK"
tar xf "$SRC/$OGG_TAR" -C "$WORK"

rm -rf vendored/flac vendored/ogg
mkdir -p vendored/flac/include/FLAC \
         vendored/flac/include/share \
         vendored/flac/src/libFLAC/include/private \
         vendored/flac/src/libFLAC/include/protected \
         vendored/ogg/include/ogg \
         vendored/ogg/src

# --- libFLAC -----------------------------------------------------------------
cp "$WORK/flac-1.4.3/include/FLAC/"*.h vendored/flac/include/FLAC/
# libFLAC's sources include "share/<x>.h" (alloc, compat, endswap, macros,
# private) and "private/<x>.h"; both live under include/ in the tarball.
cp "$WORK/flac-1.4.3/include/share/"*.h vendored/flac/include/share/
cp "$WORK/flac-1.4.3/src/libFLAC/"*.c vendored/flac/src/libFLAC/
cp "$WORK/flac-1.4.3/src/libFLAC/include/private/"*.h \
   vendored/flac/src/libFLAC/include/private/
cp "$WORK/flac-1.4.3/src/libFLAC/include/protected/"*.h \
   vendored/flac/src/libFLAC/include/protected/
# deduplication/*.c are #included FUNCTION-BODY FRAGMENTS (bitreader.c and
# lpc.c pull them in), not translation units - they must never be compiled on
# their own, which is why build.sh filters that directory out.
mkdir -p vendored/flac/src/libFLAC/deduplication
cp "$WORK/flac-1.4.3/src/libFLAC/deduplication/"*.c \
   vendored/flac/src/libFLAC/deduplication/
cp "$WORK/flac-1.4.3/COPYING.Xiph" vendored/flac/
# The hand-written replacement for autotools' generated config.h (see the file
# itself for why each macro is set the way it is).
cp tools/flac_config.h vendored/flac/config.h

# --- libogg ------------------------------------------------------------------
cp "$WORK/libogg-1.3.5/include/ogg/"*.h vendored/ogg/include/ogg/
cp "$WORK/libogg-1.3.5/src/"*.c "$WORK/libogg-1.3.5/src/crctable.h" \
   vendored/ogg/src/
cp "$WORK/libogg-1.3.5/COPYING" vendored/ogg/

echo "--- vendored ---"
echo "libFLAC 1.4.3: $(ls vendored/flac/src/libFLAC/*.c | wc -l | tr -d ' ') C files," \
     "$(ls vendored/flac/include/FLAC/*.h | wc -l | tr -d ' ') headers"
echo "libogg  1.3.5: $(ls vendored/ogg/src/*.c | wc -l | tr -d ' ') C files," \
     "$(ls vendored/ogg/include/ogg/*.h | wc -l | tr -d ' ') headers"