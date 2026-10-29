#!/bin/sh
# Builds Hoverpad.app (universal arm64 + x86_64, macOS 13+) next to this script.
# Optional: VERSION=1.2.3 ./build.sh
set -e
cd "$(dirname "$0")"
APP=Hoverpad.app
VERSION="${VERSION:-1.0}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
T=$(mktemp -d)
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos13" Hoverpad.swift -o "$T/Hoverpad-$ARCH"
done
lipo -create "$T/Hoverpad-arm64" "$T/Hoverpad-x86_64" -output "$APP/Contents/MacOS/Hoverpad"
rm -rf "$T"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Hoverpad</string>
  <key>CFBundleIdentifier</key><string>local.hoverpad</string>
  <key>CFBundleExecutable</key><string>Hoverpad</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP $VERSION"
