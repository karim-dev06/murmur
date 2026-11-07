#!/bin/zsh
# Builds a disk image anyone can download and open: signed with a Developer ID certificate,
# checked by Apple (notarized), and stapled so it opens without a warning, even offline.
#
#   ./scripts/release.sh             build, sign, notarize -> dist/Murmur-<version>.dmg
#   ./scripts/release.sh --publish   ...then upload it as a GitHub release
#   ./scripts/release.sh --dry-run   sign with any certificate, skip Apple's check (for testing the packaging)
#
# One-time setup: a "Developer ID Application" certificate in your keychain, and notarization
# credentials saved with:  xcrun notarytool store-credentials murmur --apple-id <id> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
NOTARY_PROFILE="${MURMUR_NOTARY_PROFILE:-murmur}"
RELEASE_REPO="${MURMUR_RELEASE_REPO:-karim-dev06/murmur}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP=build.noindex/Murmur.app
DIST=dist
DMG="$DIST/Murmur-$VERSION.dmg"

if [[ "$MODE" == "--dry-run" ]]; then
    IDENTITY="${MURMUR_SIGN_IDENTITY:-$(cat .signing-identity 2>/dev/null || echo -)}"
else
    IDENTITY="${MURMUR_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
    if [[ -z "$IDENTITY" ]]; then
        echo "No 'Developer ID Application' certificate found. Create one in Xcode → Settings → Accounts → Manage Certificates." >&2
        exit 1
    fi
fi
echo "Murmur $VERSION, signing as: $IDENTITY"

# 1. Build the app bundle (unsigned signature is replaced below).
./scripts/build.sh >/dev/null

# 2. Sign with the hardened runtime, which notarization requires.
codesign --force --options runtime --timestamp --entitlements Resources/Murmur.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

# 2b. Have Apple check the app itself and attach the approval to it, so it opens without
#     going online even after it has been dragged out of the disk image.
if [[ "$MODE" != "--dry-run" ]]; then
    mkdir -p "$DIST"
    ditto -c -k --keepParent "$APP" "$DIST/Murmur-app.zip"
    xcrun notarytool submit "$DIST/Murmur-app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$DIST/Murmur-app.zip"
fi

# 3. Disk image: the app next to a shortcut to Applications, so installing is one drag.
rm -rf "$DIST/stage" "$DMG"
mkdir -p "$DIST/stage"
cp -R "$APP" "$DIST/stage/"
ln -s /Applications "$DIST/stage/Applications"
hdiutil create -volname "Murmur" -srcfolder "$DIST/stage" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DIST/stage"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ "$MODE" == "--dry-run" ]]; then
    echo "Dry run done: $DMG (not notarized, so other Macs will warn)"
    exit 0
fi

# 4. Apple's check of the disk image, then attach its approval to the file.
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
xcrun stapler validate "$APP"
echo "Ready: $DMG"

# 5. Optional: publish as a GitHub release.
if [[ "$MODE" == "--publish" ]]; then
    # A copy with a fixed name, so the README's Download button always gets the newest version.
    cp "$DMG" "$DIST/Murmur.dmg"
    NOTES="${MURMUR_RELEASE_NOTES:-Download Murmur.dmg, open it, and drag Murmur to Applications. Needs a Mac with Apple silicon on macOS 26 or later.}"
    gh release create "v$VERSION" "$DMG" "$DIST/Murmur.dmg" --repo "$RELEASE_REPO" --title "Murmur $VERSION" --notes "$NOTES"
fi
