#!/bin/sh
# Builds Orchard.app and publishes it as a GitHub release with install.sh.
#
#   ./release.sh v0.2.0             # build, zip, tag, publish
#   ./release.sh v0.2.0 --dry-run   # build and zip into dist/ only
#
# Releases must be signed with the same identity every time so users keep their
# Accessibility grant and the in-app updater accepts the update (see build.sh /
# ORCHARD_SIGN_ID). The build is refused unless it's signed by RELEASE_CERT.
RELEASE_CERT=fa647bcca20380f71f82b87e670e5a31ea1bc447 # SHA-1 of the signing certificate
set -eu
cd "$(dirname "$0")"

VERSION=${1:-}
DRY=${2:-}
case "$VERSION" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "usage: ./release.sh vMAJOR.MINOR.PATCH [--dry-run]" >&2; exit 2 ;;
esac

if [ "$DRY" != "--dry-run" ]; then
  [ -z "$(git status --porcelain)" ] || { echo "Commit your changes first." >&2; exit 1; }
  git fetch -q origin
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "Push main first (HEAD must match origin/main)." >&2; exit 1; }
  ! git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null || { echo "Tag $VERSION already exists." >&2; exit 1; }
fi

ORCHARD_VERSION=${VERSION#v} ./build.sh
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Orchard.app/Contents/Info.plist)
[ "$BUILT_VERSION" = "${VERSION#v}" ] || {
  echo "Orchard.app is version $BUILT_VERSION, expected ${VERSION#v}. Refusing to package the wrong version." >&2
  exit 1
}
codesign -d -r- Orchard.app 2>&1 | grep -q "certificate leaf = H\"$RELEASE_CERT\"" || {
  echo "Orchard.app isn't signed by the release certificate ($RELEASE_CERT)." >&2
  echo "Existing users couldn't update to it. Import the release identity and rebuild." >&2
  exit 1
}

rm -rf dist && mkdir dist
ditto -c -k --keepParent Orchard.app dist/Orchard.zip
# Drag-to-Applications disk image for browser downloads. Left unsigned on purpose:
# Gatekeeper blocks a downloaded DMG signed with our self-signed cert ("Not Opened").
# The app inside is still signed, which is what the updater checks.
STAGE=$(mktemp -d)
ditto Orchard.app "$STAGE/Orchard.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Orchard -srcfolder "$STAGE" -fs APFS -format ULFO -ov dist/Orchard.dmg
rm -rf "$STAGE"
cp install.sh dist/install.sh
(cd dist && shasum -a 256 Orchard.zip Orchard.dmg install.sh > SHA256SUMS)
echo "Packaged:"; ls -lh dist | tail -n +2

[ "$DRY" = "--dry-run" ] && { echo "Dry run: not publishing."; exit 0; }

gh release create "$VERSION" dist/Orchard.zip dist/Orchard.dmg dist/install.sh dist/SHA256SUMS \
  --target main --title "Orchard $VERSION" --generate-notes \
  --notes "$(cat <<EOF
## Install

\`\`\`sh
curl -fsSL https://github.com/iraosandeep/Orchard/releases/latest/download/install.sh | sh
\`\`\`

Or download **Orchard.dmg**, open it, and drag Orchard to Applications.

Requires an Apple Silicon Mac on macOS 26.4+ with Apple Intelligence turned on.
Not notarized: the command above is the smoothest install. A browser download needs
System Settings › Privacy & Security › **Open Anyway** on first launch.
EOF
)"
