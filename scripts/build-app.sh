#!/usr/bin/env bash
# Build an unsigned ModelStatus.app in build/.
# Pass --sign "Developer ID Application: ..." to codesign.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SIGN_IDENTITY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) SIGN_IDENTITY="$2"; shift 2 ;;
        --debug) CONFIG="debug"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/ModelStatus.app"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/ModelStatus" "$APP/Contents/MacOS/ModelStatus"
cp "ModelStatus/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "→ codesign with: $SIGN_IDENTITY"
    codesign --deep --force --options runtime \
        --entitlements ModelStatus/ModelStatus.entitlements \
        --sign "$SIGN_IDENTITY" \
        "$APP"
fi

echo "✓ built $APP"
echo
echo "Try it:"
echo "    open $APP"
echo
echo "Install to /Applications:"
echo "    cp -R $APP /Applications/"
