#!/bin/sh
# Builds Orchard.app: a menu-bar launcher with the orchard binary bundled inside.
# Usage: launcher/build.sh   then   open Orchard.app   (or copy it to /Applications)
set -e
cd "$(dirname "$0")/.."
APP=Orchard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
go build -o "$APP/Contents/Resources/orchard" .
swiftc -O -o "$APP/Contents/MacOS/OrchardBar" launcher/OrchardBar.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Orchard</string>
  <key>CFBundleIdentifier</key><string>local.orchard.bar</string>
  <key>CFBundleExecutable</key><string>OrchardBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "Built $APP"
