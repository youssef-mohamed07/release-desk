#!/bin/zsh
# Builds a universal (Apple silicon + Intel) "Release Desk.app" for other
# people, signs it ad hoc (no personal certificate inside), and zips it.
#   scripts/package.sh   →  build/dist/ReleaseDesk-<version>.zip
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
OUT=build/dist
APP="$OUT/Release Desk.app"

swift build -c release --product ReleaseDesk --arch arm64 --arch x86_64 2>&1 | grep -E "error|Compiling|Build complete" | grep -v Compiling || true
BIN=$(swift build -c release --product ReleaseDesk --arch arm64 --arch x86_64 --show-bin-path)/ReleaseDesk
lipo -info "$BIN"

rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Release Desk"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign -f -s - --entitlements Resources/ReleaseDesk.entitlements "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Signature|Identifier"

ditto -c -k --keepParent "$APP" "$OUT/ReleaseDesk-$VERSION.zip"
shasum -a 256 "$OUT/ReleaseDesk-$VERSION.zip"
ls -la "$OUT"
