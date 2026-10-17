#!/bin/bash
# Builds build/RetroDrop.app (universal: Apple Silicon + Intel) and dist/RetroDrop-<version>.zip.
#
#   scripts/build.sh                 # ad-hoc signed (fine for local use and unsigned releases)
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build.sh
#                                    # signed for notarization (see docs/RELEASING.md)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/RetroDrop.app"
MIN_MACOS="14.0"

echo "==> Building RetroDrop $VERSION ($BUILD)"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$arch-apple-macos$MIN_MACOS" \
    Sources/*.swift -o "build/obj/RetroDrop-$arch"
done
lipo -create build/obj/RetroDrop-arm64 build/obj/RetroDrop-x86_64 -output "$APP/Contents/MacOS/RetroDrop"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

# Icons (regenerate with: swift scripts/make-icons.swift)
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/MenuBar*.png "$APP/Contents/Resources/"

xattr -cr "$APP"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

mkdir -p dist
ZIP="dist/RetroDrop-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"  # no stray ._ metadata files

# Disk image with a drag-to-Applications window (what the README's download button serves).
# Needs dmgbuild:  python3 -m venv .venv && .venv/bin/pip install dmgbuild
# The window background comes from: swift scripts/make-dmg-background.swift
DMG="dist/RetroDrop-$VERSION.dmg"
if [[ -x .venv/bin/dmgbuild ]]; then
  rm -f "$DMG"
  .venv/bin/dmgbuild -s scripts/dmg-settings.py -D app="$APP" "RetroDrop" "$DMG" >/dev/null
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  fi
  # Same file under a version-free name, so the README's
  # releases/latest/download/RetroDrop.dmg link always serves the newest release.
  cp "$DMG" dist/RetroDrop.dmg
  echo "==> Packaged $DMG and dist/RetroDrop.dmg"
else
  echo "!!  Skipped the .dmg: dmgbuild not found (see the comment in scripts/build.sh)"
fi

echo "==> Built $APP"
echo "==> Packaged $ZIP"
lipo -archs "$APP/Contents/MacOS/RetroDrop"
