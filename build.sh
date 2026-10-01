#!/bin/bash
# Builds build/Video1Cam.app. Options: --install (copy to /Applications), --test (run pipeline tests first)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Video1Cam.app
if [[ " $* " == *" --test "* ]]; then
  swift build -c release --product CoreTests
  .build/release/CoreTests
fi

# Universal binary (Apple Silicon + Intel): build each arch, then merge with lipo.
swift build -c release --product Video1Cam --triple arm64-apple-macosx15.0
swift build -c release --product Video1Cam --triple x86_64-apple-macosx15.0
BIN=$(mktemp -d)/Video1Cam
lipo -create .build/arm64-apple-macosx/release/Video1Cam .build/x86_64-apple-macosx/release/Video1Cam -output "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Video1Cam"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon
ICON_TMP=$(mktemp -d)
swift scripts/make-icon.swift "$ICON_TMP/icon.png"
mkdir "$ICON_TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_TMP/icon.png" --out "$ICON_TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICON_TMP/icon.png" --out "$ICON_TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

# Ad-hoc signature (required for camera/mic/screen permissions to stick).
codesign --force --sign - --identifier coop.up.video1cam "$APP"
codesign --verify --verbose=1 "$APP"
echo "✓ $APP ($(lipo -archs "$APP/Contents/MacOS/Video1Cam"))"

if [[ " $* " == *" --install "* ]]; then
  osascript -e 'quit app "Video1Cam"' 2>/dev/null || true
  rm -rf /Applications/Video1Cam.app
  cp -R "$APP" /Applications/
  echo "✓ installé dans /Applications/Video1Cam.app"
fi
