#!/bin/sh
# Builds Orchard.app: native chat, Rewrite Selection (⌃⌥R), menu-bar item, and
# the bundled Go server/CLI (web Tasks UI, `orchard run`, fm serve supervision).
# Needs Go and the Xcode Command Line Tools (full Xcode not required).
set -e
cd "$(dirname "$0")"
APP=Orchard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
go build -o "$APP/Contents/Resources/orchard" .
swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos26.4 \
  -o "$APP/Contents/MacOS/Orchard" mac/*.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Orchard</string>
  <key>CFBundleDisplayName</key><string>Orchard</string>
  <key>CFBundleIdentifier</key><string>local.orchard</string>
  <key>CFBundleExecutable</key><string>Orchard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>LSMinimumSystemVersion</key><string>26.4</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"
