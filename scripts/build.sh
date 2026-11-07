#!/bin/zsh
# Builds Murmur.app into build.noindex/ (the ".noindex" keeps this copy out of Spotlight). Pass --install to copy it to /Applications and open it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64

APP=build.noindex/Murmur.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/Murmur" "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Signing with your own certificate keeps macOS permissions (Accessibility, Microphone) across rebuilds.
# Put its name or SHA-1 in .signing-identity (not committed) or MURMUR_SIGN_IDENTITY.
# Without one the app is signed ad hoc, and macOS asks for permissions again after each rebuild.
IDENTITY="${MURMUR_SIGN_IDENTITY:-$(cat .signing-identity 2>/dev/null || true)}"
if [[ -z "$IDENTITY" ]]; then
    echo "No signing identity set. Signing ad hoc."
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Murmur || true
    rm -rf /Applications/Murmur.app
    cp -R "$APP" /Applications/
    # Tell macOS about the new icon right away, so Spotlight and Finder show it.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Murmur.app
    touch /Applications/Murmur.app
    open /Applications/Murmur.app
    echo "Installed /Applications/Murmur.app"
fi
