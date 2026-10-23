#!/bin/sh
# Installs Orchard.app from the latest GitHub release.
#
#   curl -fsSL https://github.com/iraosandeep/Orchard/releases/latest/download/install.sh | sh
#
# Files fetched with curl aren't quarantined, so Gatekeeper doesn't block the
# (not notarized) app on first launch.
#
# Env overrides: ORCHARD_VERSION (e.g. v0.2.0, default latest),
# ORCHARD_APP_DIR (default /Applications, else ~/Applications),
# ORCHARD_NO_CLI=1 (skip the `orchard` command), ORCHARD_NO_OPEN=1.
set -eu

REPO="iraosandeep/Orchard"
say() { printf '\033[32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Requirements: Apple Silicon Mac on macOS 26.4+ (Apple Intelligence).
[ "$(uname -s)" = Darwin ] || die "Orchard runs on macOS only."
[ "$(uname -m)" = arm64 ] || die "Orchard needs an Apple Silicon Mac (Apple Intelligence)."
OS=$(sw_vers -productVersion)
MAJOR=${OS%%.*}; REST=${OS#*.}; MINOR=${REST%%.*}
[ "$MAJOR" = "$OS" ] && MINOR=0
if [ "$MAJOR" -lt 26 ] || { [ "$MAJOR" -eq 26 ] && [ "$MINOR" -lt 4 ]; }; then
  die "Orchard needs macOS 26.4 or later (you have $OS)."
fi

if [ -n "${ORCHARD_ZIP_URL:-}" ]; then
  URL=$ORCHARD_ZIP_URL
elif [ -n "${ORCHARD_VERSION:-}" ]; then
  URL="https://github.com/$REPO/releases/download/$ORCHARD_VERSION/Orchard.zip"
else
  URL="https://github.com/$REPO/releases/latest/download/Orchard.zip"
fi

DIR=${ORCHARD_APP_DIR:-/Applications}
if [ ! -w "$DIR" ]; then
  DIR="$HOME/Applications"
  mkdir -p "$DIR"
fi
APP="$DIR/Orchard.app"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "Downloading $URL"
curl -fL --progress-bar -o "$TMP/Orchard.zip" "$URL" || die "Download failed."
ditto -x -k "$TMP/Orchard.zip" "$TMP" || die "Couldn't unzip the download."
[ -d "$TMP/Orchard.app" ] || die "Orchard.app not found in the download."
codesign --verify --deep "$TMP/Orchard.app" 2>/dev/null || die "Downloaded app failed its code-signature check."

if pgrep -f "Orchard.app/Contents/MacOS/Orchard" >/dev/null 2>&1; then
  say "Quitting the running Orchard"
  osascript -e 'quit app "Orchard"' >/dev/null 2>&1 || true
  sleep 2
fi

say "Installing to $APP"
rm -rf "$APP"
ditto "$TMP/Orchard.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

# Command-line tool: link into the first writable bin directory on PATH.
if [ "${ORCHARD_NO_CLI:-0}" != 1 ]; then
  BIN=""
  for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    if [ -d "$d" ] && [ -w "$d" ]; then BIN=$d; break; fi
  done
  if [ -z "$BIN" ]; then BIN="$HOME/.local/bin"; mkdir -p "$BIN"; fi
  ln -sf "$APP/Contents/Resources/orchard" "$BIN/orchard"
  say "Linked the orchard command into $BIN"
  case ":$PATH:" in
    *":$BIN:"*) ;;
    *) printf '    Add it to your PATH:  echo '\''export PATH="%s:$PATH"'\'' >> ~/.zshrc\n' "$BIN" ;;
  esac
fi

say "Installed Orchard $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo)"
if [ "${ORCHARD_NO_OPEN:-0}" != 1 ]; then
  open "$APP"
  echo "    Orchard is in your menu bar (leaf icon). Setup & Status (⌘,) shows anything left to enable."
fi
