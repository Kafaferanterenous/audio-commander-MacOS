#!/bin/sh
set -e
cd "$(dirname "$0")"

APP_NAME="AudioCommander"
APP="dist/${APP_NAME}.app"
BUILD="build"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/x86_64" "$BUILD/arm64" \
         "$BUILD/x86_64/obj" "$BUILD/arm64/obj"

CC="xcrun cc"
CFLAGS="-O2 -w -mmacosx-version-min=13.0 -I vendored/dumb/include -I vendored/stb -I vendored/decoders"
CSRCS=$(find vendored -name '*.c')

for ARCH in x86_64 arm64; do
    OBJDIR="$BUILD/$ARCH/obj"
    REBUILD=0
    for s in $CSRCS; do
        o="$OBJDIR/$(echo "$s" | tr '/' '_').o"
        if [ ! -f "$o" ] || [ "$s" -nt "$o" ]; then
            $CC $CFLAGS -arch $ARCH -c "$s" -o "$o"
            REBUILD=1
        fi
    done
    libtool -static -o "$BUILD/$ARCH/libdecoders.a" "$OBJDIR"/*.o

    swiftc -O -parse-as-library -target ${ARCH}-apple-macos13.0 \
        -import-objc-header src/Bridge.h \
        src/*.swift -o "$BUILD/$ARCH/${APP_NAME}" \
        -L"$BUILD/$ARCH" -ldecoders

    lipo -remove "$BUILD/$ARCH/libdecoders.a" 2>/dev/null >/dev/null || true
done

lipo -create "$BUILD/x86_64/${APP_NAME}" "$BUILD/arm64/${APP_NAME}" \
     -output "$APP/Contents/MacOS/${APP_NAME}"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
codesign --force --sign - "$APP" 2>/dev/null || true

echo "--- Build complete: $APP ---"
lipo -info "$APP/Contents/MacOS/${APP_NAME}" | sed 's/^/Architectures: /'
du -sh "$APP" | cut -f1 | xargs -I{} echo "App size: {}"
df -h / | tail -1 | awk '{print "Disk free: " $4 " of " $2}'