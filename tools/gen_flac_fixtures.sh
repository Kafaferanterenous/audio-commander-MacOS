#!/bin/sh
# Regenerates the Ogg FLAC decoder fixtures.
#
#   tools/gen_flac_fixtures.sh              committed fixtures (tools/fixtures)
#   tools/gen_flac_fixtures.sh --check      regenerate into a temp dir and
#                                           byte-compare with what is committed
#
# The committed *.oga files are written by the *vendored* libFLAC encoder, so
# they are the reference our own decoder must read back bit for bit. When a
# reference flac(1) CLI is installed, the same signal is additionally encoded by
# that third-party encoder into build/tools/ref/, and tools/test_oggflac.c runs
# the same checks against those files too.
set -e
cd "$(dirname "$0")/.."

CHECK=0
[ "$1" = "--check" ] && CHECK=1

[ -x build/tools/flacgen ] || tools/build_tools.sh

# name              rate  ch  bps  seconds
SPECS="s16_44100_stereo 44100 2 16 1.0
s24_44100_stereo 44100 2 24 0.5
s8_44100_stereo  44100 2 8  0.5
s16_44100_mono  44100 1 16 0.5
s16_44100_5ch   44100 5 16 0.5
s16_22050_mono  22050 1 16 0.5
s24_48000_stereo 48000 2 24 0.5
s24_96000_stereo 96000 2 24 0.5
s32_44100_stereo 44100 2 32 0.25"

if [ "$CHECK" = 1 ]; then
    OUT=$(mktemp -d)
    trap 'rm -rf "$OUT"' EXIT
else
    OUT=tools/fixtures
fi

echo "$SPECS" | while read -r name rate ch bps secs; do
    [ -n "$name" ] || continue
    build/tools/flacgen "$OUT/$name.oga" "$rate" "$ch" "$bps" "$secs" 5
done

if [ "$CHECK" = 1 ]; then
    fail=0
    echo "$SPECS" | while read -r name rate ch bps secs; do
        [ -n "$name" ] || continue
        if ! cmp -s "$OUT/$name.oga" "tools/fixtures/$name.oga"; then
            echo "MISMATCH: tools/fixtures/$name.oga"
            fail=1
        fi
    done
    exit $fail
fi

# Cross-check copies written by the reference flac CLI, if one is installed.
if command -v flac >/dev/null 2>&1; then
    mkdir -p build/tools/ref
    flac --version | head -1
    for spec in "r16_44100_2 44100 2 16 1.0" "r24_48000_2 48000 2 24 0.5" \
                "r16_22050_1 22050 1 16 1.0"; do
        set -- $spec
        build/tools/flacgen "build/tools/ref/$1.raw" "$2" "$3" "$4" "$5" >/dev/null
        flac --ogg -8 -f -s \
            --endian=little --sign=signed --channels="$3" --bps="$4" --sample-rate="$2" \
            -o "build/tools/ref/$1.oga" "build/tools/ref/$1.raw"
        echo "wrote build/tools/ref/$1.oga (reference flac CLI, -8 --ogg)"
    done
else
    echo "note: no 'flac' CLI on PATH, skipping the third-party cross-check files"
fi
