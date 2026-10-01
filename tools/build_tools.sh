#!/bin/sh
# Builds the host-side decoder tools (fixture generator + verification harness)
# against the same vendored sources the app links.
#
#   tools/build_tools.sh          normal build
#   tools/build_tools.sh asan     AddressSanitizer build (same binaries + asan)
#
# The vendored FLAC *encoder* objects (stream_encoder.c, ogg_encoder_aspect.c)
# live in the same archive as the app's; because they are a static archive the
# app binary never pulls them in, so fixture tooling costs the app nothing.
set -e
cd "$(dirname "$0")/.."

OUT="build/tools"
SAN=""
SUF=""
for arg in "$@"; do
    case "$arg" in
        asan) SAN="-fsanitize=address -fno-omit-frame-pointer"; SUF="_asan" ;;
        *) echo "usage: $0 [asan]" >&2; exit 2 ;;
    esac
done

CFLAGS="-std=c11 -O2 -g -Wall -Wextra -Wno-unused-parameter -DHAVE_CONFIG_H=1 -DNDEBUG -DFLAC__OVERFLOW_DETECT $SAN \
  -I vendored/dumb/include -I vendored/stb -I vendored/decoders -I tools \
  -I vendored/wavpack/include -I vendored/wavpack/src \
  -I vendored/flac/include -I vendored/flac/src/libFLAC/include \
  -I vendored/flac -I vendored/ogg/include"

OBJ="$OUT/obj"
[ -n "$SAN" ] && OBJ="$OUT/obj-asan"
mkdir -p "$OBJ"

CSRCS=$(find vendored -name '*.c' -not -path '*/deduplication/*')
for s in $CSRCS; do
    o="$OBJ/$(echo "$s" | tr '/' '_').o"
    if [ ! -f "$o" ] || [ "$s" -nt "$o" ] || [ "$0" -nt "$o" ]; then
        xcrun cc $CFLAGS -c "$s" -o "$o"
    fi
done
LIB="$OUT/libdecoders_tools.a"
[ -n "$SAN" ] && LIB="$OUT/libdecoders_tools_asan.a"
rm -f "$LIB"
libtool -static -o "$LIB" "$OBJ"/*.o

xcrun cc $CFLAGS tools/flacgen.c -o "$OUT/flacgen$SUF" "$LIB" -lm
xcrun cc $CFLAGS tools/test_oggflac.c -o "$OUT/test_oggflac$SUF" "$LIB" -lm
xcrun cc $CFLAGS tools/test_decoders.c -o "$OUT/test_decoders$SUF" "$LIB" -lm

# Spectrum harness (#16): compiles the production src/Spectrum.swift alongside
# the test, so the FFT and band mapping under test are literally the shipping
# code rather than a copy. Needs a main.swift (top-level code) and AVFoundation.
xcrun swiftc -O -o "$OUT/test_spectrum$SUF" src/Spectrum.swift tools/test_spectrum/main.swift

echo "--- tools built: $OUT (flacgen$SUF, test_oggflac$SUF, test_decoders$SUF, test_spectrum$SUF) ---"
