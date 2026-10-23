#!/bin/sh
# Builds "Orchard Chat.app": the native chat window plus Rewrite Selection (⌃⌥R).
# Needs only the Command Line Tools (no Xcode). Usage: mac/build.sh
set -e
cd "$(dirname "$0")/.."
APP="Orchard Chat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos26.4 \
  -o "$APP/Contents/MacOS/OrchardChat" mac/*.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Orchard Chat</string>
  <key>CFBundleDisplayName</key><string>Orchard Chat</string>
  <key>CFBundleIdentifier</key><string>local.orchard.chat</string>
  <key>CFBundleExecutable</key><string>OrchardChat</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.4</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"
