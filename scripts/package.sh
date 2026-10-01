#!/bin/bash
# Builds the app and zips it for a GitHub Release: dist/Video1Cam-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh --test
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
mkdir -p dist
ZIP="dist/Video1Cam-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the bundle structure and code signature intact (plain zip can break them).
ditto -c -k --sequesterRsrc --keepParent build/Video1Cam.app "$ZIP"
echo "✓ $ZIP ($(du -h "$ZIP" | cut -f1))"
