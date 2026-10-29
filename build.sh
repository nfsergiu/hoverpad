#!/bin/sh
# Builds Hoverpad.app next to this script.
set -e
cd "$(dirname "$0")"
APP=Hoverpad.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 Hoverpad.swift -o "$APP/Contents/MacOS/Hoverpad"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Hoverpad</string>
  <key>CFBundleIdentifier</key><string>local.hoverpad</string>
  <key>CFBundleExecutable</key><string>Hoverpad</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
