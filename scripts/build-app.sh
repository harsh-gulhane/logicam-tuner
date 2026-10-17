#!/bin/sh
# Builds CamDial.app (menu-bar only) into ./build and signs it ad hoc for local use.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
version=${CAMDIAL_VERSION:-0.1.0}
app="$root/build/CamDial.app"

# Build each architecture separately: multi-arch `swift build` needs Xcode's build system.
binaries=""
for arch in arm64 x86_64; do
  swift build --package-path "$root" -c release --product CamDialApp --triple "$arch-apple-macosx14.0"
  binaries="$binaries $(swift build --package-path "$root" -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/CamDialApp"
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# shellcheck disable=SC2086
lipo -create $binaries -output "$app/Contents/MacOS/CamDial"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CamDial</string>
  <key>CFBundleDisplayName</key><string>CamDial</string>
  <key>CFBundleIdentifier</key><string>io.github.camdial</string>
  <key>CFBundleExecutable</key><string>CamDial</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key><string>CamDial shows a live preview so you can see the effect of camera settings.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --options runtime --entitlements "$root/scripts/CamDial.entitlements" "$app"
echo "built $app"
