#!/usr/bin/env bash
# Build an unsigned ModelStatus.app in build/.
#
# Usage:
#   ./scripts/build-app.sh                              # direct-download build (default)
#   ./scripts/build-app.sh --app-store                  # sandboxed App Store build
#   ./scripts/build-app.sh --sign "Developer ID …"       # codesign with the given identity
#   ./scripts/build-app.sh --debug                      # debug config (vs default release)
#
# `--app-store` defines `MODELSTATUS_APP_STORE=1` at compile time, which:
#   - flips `LocalSystemAccessProvider`'s default to `SandboxedLocalSystemAccess`
#   - hides the "Start/Stop Local Ollama" menu item (sandbox can't exec brew/pkill)
#   - enables release-only OSLog fault if `configure(_:)` is missed at launch
#   - degrades Tailscale discovery + diagnostic-bundle telemetry gracefully (HTTP
#     polling continues; local-process inspection returns nil)
#
# For actual App Store submission, this script's output is the unsandboxed
# binary skeleton — the real upload happens via an Xcode project (or xcrun
# xcodebuild + altool/notarytool) with a Distribution certificate from the
# Apple Developer Program. See RELEASE-PLAN.md → v1.0 checklist.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SIGN_IDENTITY=""
APP_STORE_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) SIGN_IDENTITY="$2"; shift 2 ;;
        --debug) CONFIG="debug"; shift ;;
        --app-store) APP_STORE_MODE=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

SWIFT_FLAGS=()
ENTITLEMENTS_FILE="ModelStatus/ModelStatus.entitlements"
if [[ $APP_STORE_MODE -eq 1 ]]; then
    SWIFT_FLAGS+=("-Xswiftc" "-DMODELSTATUS_APP_STORE")
    ENTITLEMENTS_FILE="ModelStatus/ModelStatus-AppStore.entitlements"
    echo "→ App Store / sandboxed build (MODELSTATUS_APP_STORE=1, entitlements=$ENTITLEMENTS_FILE)"
fi

echo "→ swift build -c $CONFIG ${SWIFT_FLAGS[*]:-}"
swift build -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}

BIN_PATH="$(swift build -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)"
APP="build/ModelStatus.app"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/ModelStatus" "$APP/Contents/MacOS/ModelStatus"
cp "ModelStatus/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "→ codesign with: $SIGN_IDENTITY (entitlements: $ENTITLEMENTS_FILE)"
    codesign --deep --force --options runtime \
        --entitlements "$ENTITLEMENTS_FILE" \
        --sign "$SIGN_IDENTITY" \
        "$APP"
fi

echo "✓ built $APP"
if [[ $APP_STORE_MODE -eq 1 ]]; then
    echo "  (App Store / sandboxed configuration)"
fi
echo
echo "Try it:"
echo "    open $APP"
echo
echo "Install to /Applications:"
echo "    cp -R $APP /Applications/"
