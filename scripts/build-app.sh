#!/bin/sh
# Builds "LogiCam Tuner.app" (universal, with the `logicam` CLI inside) into ./build and signs it ad hoc.
# With --zip, also writes build/LogiCam-Tuner-<version>.zip for a release.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
version=${LOGICAM_VERSION:-$(cat "$root/VERSION")}
app="$root/build/LogiCam Tuner.app"

# Build each architecture separately: multi-arch `swift build` needs Xcode's build system.
apps="" clis=""
for arch in arm64 x86_64; do
  triple="$arch-apple-macosx14.0"
  swift build --package-path "$root" -c release --product LogiCamTunerApp --triple "$triple"
  swift build --package-path "$root" -c release --product logicam --triple "$triple"
  bin=$(swift build --package-path "$root" -c release --triple "$triple" --show-bin-path)
  apps="$apps $bin/LogiCamTunerApp"
  clis="$clis $bin/logicam"
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# shellcheck disable=SC2086
lipo -create $apps -output "$app/Contents/MacOS/LogiCamTuner"
# The CLI lives inside the bundle so one download (and the Homebrew cask) provides both.
# shellcheck disable=SC2086
lipo -create $clis -output "$app/Contents/MacOS/logicam"

# App icon, rendered from an SF Symbol so the repository needs no binary assets.
work="$root/build/icon"
rm -rf "$work" && mkdir -p "$work/LogiCamTuner.iconset"
swiftc -O "$root/scripts/make-icon.swift" -o "$work/make-icon"
"$work/make-icon" "$work/icon.png"
for px in 16 32 128 256 512; do
  sips -z $px $px "$work/icon.png" --out "$work/LogiCamTuner.iconset/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) "$work/icon.png" --out "$work/LogiCamTuner.iconset/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$work/LogiCamTuner.iconset" -o "$app/Contents/Resources/LogiCamTuner.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LogiCam Tuner</string>
  <key>CFBundleDisplayName</key><string>LogiCam Tuner</string>
  <key>CFBundleIdentifier</key><string>io.github.logicamtuner</string>
  <key>CFBundleExecutable</key><string>LogiCamTuner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>LogiCamTuner</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSCameraUsageDescription</key><string>LogiCam Tuner analyses video on this Mac to run Smart Auto exposure and white balance, and shows a live preview. Video is never recorded or sent anywhere.</string>
</dict>
</plist>
PLIST

# Nested executables are signed before the bundle that seals them.
codesign --force --sign - --options runtime "$app/Contents/MacOS/logicam"
codesign --force --sign - --options runtime --entitlements "$root/scripts/LogiCamTuner.entitlements" "$app"
echo "built $app ($version)"

if [ "${1:-}" = "--zip" ]; then
  zip="$root/build/LogiCam-Tuner-$version.zip"
  rm -f "$zip"
  # ditto keeps the bundle's symlinks, permissions and signature intact.
  ditto -c -k --keepParent "$app" "$zip"
  shasum -a 256 "$zip" | awk '{print $1}' > "$zip.sha256"
  echo "zipped $zip"
fi
