#!/bin/bash
# Build Memory Advisor: swiftc -> .app -> ad-hoc signature -> (optional) install / DMG.
#
#   ./build.sh              build build/MemoryAdvisor.app (universal: arm64 + x86_64)
#   ./build.sh --install    ...and copy it to /Applications
#   ./build.sh --dmg        ...and create build/MemoryAdvisor-<version>.dmg
#
# Requirements: Xcode or Command Line Tools with Swift 5.9+, macOS 14+.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Memory Advisor"
EXEC="MemoryAdvisor"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
APP="build/${EXEC}.app"
MIN_MACOS="14.0"

rm -rf "$APP" build/arm64 build/x86_64 build/AppIcon.iconset build/stage
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/arm64 build/x86_64

echo "-> compiling (arm64 + x86_64)"
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "${ARCH}-apple-macos${MIN_MACOS}" \
    Sources/*.swift -o "build/${ARCH}/${EXEC}"
done
lipo -create "build/arm64/${EXEC}" "build/x86_64/${EXEC}" -output "$APP/Contents/MacOS/${EXEC}"

echo "-> icon"
swift Resources/make_icon.swift build/AppIcon.iconset >/dev/null
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "-> localizations"
for L in en ru; do cp -R "Resources/${L}.lproj" "$APP/Contents/Resources/"; done

cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>&1 | tail -n 1
echo "-> built: $APP ($(lipo -archs "$APP/Contents/MacOS/${EXEC}"))"

case "${1:-}" in
  --install)
    rm -rf "/Applications/${NAME}.app"
    cp -R "$APP" "/Applications/${NAME}.app"
    echo "-> installed: /Applications/${NAME}.app"
    ;;
  --dmg)
    DMG="build/${EXEC}-${VERSION}.dmg"
    mkdir -p build/stage && cp -R "$APP" "build/stage/${NAME}.app"
    ln -s /Applications build/stage/Applications
    rm -f "$DMG"
    hdiutil create -volname "${NAME}" -srcfolder build/stage -ov -format UDZO "$DMG" >/dev/null
    echo "-> DMG: $DMG"
    shasum -a 256 "$DMG"
    ;;
esac
