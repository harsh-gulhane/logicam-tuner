#!/bin/sh
# Builds CamDial.app into ./build and signs it ad hoc for local use.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
version=${CAMDIAL_VERSION:-0.2.0}
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

# App icon, rendered from an SF Symbol so the repository needs no binary assets.
work="$root/build/icon"
rm -rf "$work" && mkdir -p "$work/CamDial.iconset"
swiftc -O "$root/scripts/make-icon.swift" -o "$work/make-icon"
"$work/make-icon" "$work/icon.png"
for px in 16 32 128 256 512; do
  sips -z $px $px "$work/icon.png" --out "$work/CamDial.iconset/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) "$work/icon.png" --out "$work/CamDial.iconset/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$work/CamDial.iconset" -o "$app/Contents/Resources/CamDial.icns"

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
  <key>CFBundleIconFile</key><string>CamDial</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSCameraUsageDescription</key><string>CamDial analyses video on this Mac to run Smart Auto exposure and white balance, and shows a live preview. Video is never recorded or sent anywhere.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --options runtime --entitlements "$root/scripts/CamDial.entitlements" "$app"
echo "built $app"
