#!/bin/sh
# Builds Orchard.app: native chat, Rewrite Selection (⌃⌥R), menu-bar item, and
# the bundled Go server/CLI (web Tasks UI, `orchard run`, fm serve supervision).
# Needs Go and the Xcode Command Line Tools (full Xcode not required).
set -e
cd "$(dirname "$0")"
APP=Orchard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
go build -trimpath -ldflags "-s -w -X main.version=${ORCHARD_VERSION:-0.0.0-dev}" -o "$APP/Contents/Resources/orchard" .
cp mac/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${ORCHARD_VERSION:-0.0.0-dev}</string>
  <key>CFBundleVersion</key><string>${ORCHARD_VERSION:-0.0.0-dev}</string>
  <key>LSMinimumSystemVersion</key><string>26.4</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSServices</key><array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Rewrite with Orchard…</string></dict>
      <key>NSMessage</key><string>rewrite</string>
      <key>NSPortName</key><string>Orchard</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Fix Grammar with Orchard</string></dict>
      <key>NSMessage</key><string>fixGrammar</string>
      <key>NSPortName</key><string>Orchard</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Translate with Orchard</string></dict>
      <key>NSMessage</key><string>translate</string>
      <key>NSPortName</key><string>Orchard</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
  </array>
</dict></plist>
PLIST
# The server as a launchd agent (System Settings › Login Items), registered by
# the app with SMAppService so it runs in the background after the app quits.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/local.orchard.server.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.orchard.server</string>
  <key>BundleProgram</key><string>Contents/Resources/orchard</string>
  <key>ProgramArguments</key><array>
    <string>orchard</string><string>serve</string><string>-addr</string><string>127.0.0.1:1977</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string>
    <key>ORCHARD_LOG</key><string>orchard.log</string>
  </dict>
  <key>AssociatedBundleIdentifiers</key><array><string>local.orchard</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>2</integer>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
# Sign with a stable local identity so macOS keeps the Accessibility grant
# across rebuilds (an ad-hoc signature changes every build, which silently
# invalidates the grant). The certificate is created once in the login
# keychain; delete "Orchard Local Code Signing" in Keychain Access to remove it.
SIGN_ID="${ORCHARD_SIGN_ID:-Orchard Local Code Signing}"
if ! security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
  if [ "$SIGN_ID" = "Orchard Local Code Signing" ]; then
    echo "Creating local code-signing identity \"$SIGN_ID\" (one time)…"
    T=$(mktemp -d)
    printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$SIGN_ID" > "$T/cnf"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key" -out "$T/crt" -days 3650 -config "$T/cnf" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$T/key" -in "$T/crt" -out "$T/p12" -passout pass:orchard -name "$SIGN_ID" 2>/dev/null \
      || openssl pkcs12 -export -inkey "$T/key" -in "$T/crt" -out "$T/p12" -passout pass:orchard -name "$SIGN_ID"
    security import "$T/p12" -f pkcs12 -k ~/Library/Keychains/login.keychain-db -P orchard -T /usr/bin/codesign >/dev/null
    rm -rf "$T"
  else
    echo "Signing identity \"$SIGN_ID\" not found" >&2; exit 1
  fi
fi
codesign --force --deep --sign "$SIGN_ID" "$APP"
touch "$APP"  # refresh cached Dock/Finder icons
# Register with LaunchServices so tccutil (Reset Permission) can find the app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/$APP"
# Refresh the Services menu so right-click › Services picks up NSServices changes.
/System/Library/CoreServices/pbs -update 2>/dev/null || true
echo "Built $APP"
