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

`scripts/build.sh` creates `dist/RetroDrop-<version>.zip`. Create a GitHub release tagged `v<version>`,
paste the changelog entry, and attach the zip.

```bash
git tag v$(cat VERSION) && git push --tags
gh release create v$(cat VERSION) dist/RetroDrop-$(cat VERSION).zip --notes-file <(sed -n '/^## /,$p' CHANGELOG.md | awk 'NR>1 && /^## /{exit} 1')
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
ditto -c -k --keepParent build/RetroDrop.app dist/RetroDrop-$(cat VERSION).zip   # re-zip the stapled app
```

If you do this, update the Install section of the README. The Open Anyway step is no longer needed.
