# Making a release

## 1. Bump the version

Edit `VERSION` (e.g. `1.0.1`) and add an entry to `CHANGELOG.md`.

## 2. Test

```bash
scripts/build.sh
mkdir -p /tmp/rd-test
open build/RetroDrop.app --args --start -saveFolder /tmp/rd-test
python3 tests/test_servers.py "$(build/RetroDrop.app/Contents/MacOS/RetroDrop --print-ip)" /tmp/rd-test
# quit that copy, then:
python3 tests/test_network.py
```

All tests should pass. Then quit that copy and try a real phone if you can.

## 3. Build and publish

`scripts/build.sh` creates, in `dist/`:

- `RetroDrop-<version>.dmg`: the disk image with the drag-to-Applications window
- `RetroDrop.dmg`: the same file under a version-free name
- `RetroDrop-<version>.zip`: the plain app, for people who prefer a zip

Create a GitHub release tagged `v<version>`, paste the changelog entry, and attach all three.
The README's download button links to `releases/latest/download/RetroDrop.dmg`, so it only keeps
working if **every release includes `RetroDrop.dmg`**.

The disk image needs dmgbuild (`python3 -m venv .venv && .venv/bin/pip install dmgbuild`).
To change the window's look, edit `scripts/make-dmg-background.swift` and run it. Icon positions
live in `scripts/dmg-settings.py`.

```bash
git tag v$(cat VERSION) && git push --tags
gh release create v$(cat VERSION) dist/RetroDrop-$(cat VERSION).dmg dist/RetroDrop.dmg dist/RetroDrop-$(cat VERSION).zip --notes-file <(sed -n '/^## /,$p' CHANGELOG.md | awk 'NR>1 && /^## /{exit} 1')
```

## Optional: sign and notarize

By default the app is *ad-hoc signed*, so users see a one-time "Apple could not verify…" message and
must click **Open Anyway** (documented in the README). To remove that step you need a paid
[Apple Developer Program](https://developer.apple.com/programs/) membership:

```bash
# One-time: store notarization credentials in the keychain
xcrun notarytool store-credentials retrodrop --apple-id you@example.com --team-id TEAMID

# Build signed with your Developer ID and the hardened runtime
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build.sh

# Notarize and staple
xcrun notarytool submit dist/RetroDrop-$(cat VERSION).zip --keychain-profile retrodrop --wait
xcrun stapler staple build/RetroDrop.app
ditto -c -k --norsrc --noextattr --keepParent build/RetroDrop.app dist/RetroDrop-$(cat VERSION).zip   # re-zip the stapled app
# Rebuild the disk image from the stapled app, then notarize and staple it too:
.venv/bin/dmgbuild -s scripts/dmg-settings.py -D app=build/RetroDrop.app RetroDrop dist/RetroDrop-$(cat VERSION).dmg
codesign --force --timestamp --sign "$SIGN_IDENTITY" dist/RetroDrop-$(cat VERSION).dmg
xcrun notarytool submit dist/RetroDrop-$(cat VERSION).dmg --keychain-profile retrodrop --wait
xcrun stapler staple dist/RetroDrop-$(cat VERSION).dmg
cp dist/RetroDrop-$(cat VERSION).dmg dist/RetroDrop.dmg
```

If you do this, update the Install section of the README. The Open Anyway step is no longer needed.

## Website

The website lives in `website/` (plain HTML and CSS, no build step) and is served by GitHub Pages
from the `gh-pages` branch. After committing changes to `website/`, publish with:

```bash
scripts/publish-site.sh
```

The download buttons link to `releases/latest/download/RetroDrop.dmg`, so the site needs no changes
for new releases.
