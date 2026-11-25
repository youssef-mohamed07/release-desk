#!/bin/zsh
# Builds "Release Desk.app" into ./build and signs it.
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --open     …and open it
# Signing: $SIGN_IDENTITY if set, else the first "Apple Development" identity
# in your keychain, else ad-hoc. A stable identity keeps Keychain access
# granted across rebuilds.
set -euo pipefail
cd "${0:A:h}/.."

APP="build/Release Desk.app"
swift build -c release --product ReleaseDesk 2>&1 | grep -vE "^(\[|Building|Compiling|Write)" || true
BIN=$(swift build -c release --product ReleaseDesk --show-bin-path)/ReleaseDesk
[[ -x $BIN ]] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Release Desk"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
codesign -f -s "${IDENTITY:--}" --entitlements Resources/ReleaseDesk.entitlements "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

[[ ${1:-} == --open ]] && open "$APP"
exit 0
