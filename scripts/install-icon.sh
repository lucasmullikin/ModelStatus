#!/usr/bin/env bash
# Install a new app icon from a single 1024×1024 PNG.
#
# Usage:
#   ./scripts/install-icon.sh path/to/icon-1024.png
#   ./scripts/install-icon.sh path/to/icon-1024.png --no-relaunch
#
# What it does:
#  1. Validates input is a 1024×1024 PNG
#  2. Generates the full .iconset (10 files: 16, 32, 64, 128, 256, 512 + @2x for each)
#     using `sips` (built into macOS)
#  3. Compiles to AppIcon.icns via `iconutil`
#  4. Copies into ModelStatus/Resources/ for source-tree builds AND directly
#     into build/ModelStatus.app/Contents/Resources/ for the running build
#  5. Updates Info.plist CFBundleIconFile if not already set
#  6. Re-signs the .app (Developer ID Application) so the icon takes effect
#     without quarantine drama
#  7. Relaunches the app (unless --no-relaunch)

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <path-to-1024-png> [--no-relaunch]" >&2
    exit 1
fi

SRC="$1"
shift || true
RELAUNCH=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-relaunch) RELAUNCH=0; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[33m!\033[0m %s\n" "$*"; }
die()  { printf "\033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }

# ─── 1. validate input ────────────────────────────────────────────────
bold "→ Validating $SRC"
[[ -f "$SRC" ]] || die "Source PNG not found: $SRC"
DIMS=$(sips -g pixelWidth -g pixelHeight "$SRC" 2>/dev/null | awk '/pixelWidth|pixelHeight/ {print $2}' | tr '\n' 'x' | sed 's/x$//')
if [[ "$DIMS" != "1024x1024" ]]; then
    warn "Source is $DIMS, not 1024x1024 — will resize. Best quality is to provide native 1024."
fi
ok "$SRC ($DIMS)"

# ─── 2. build iconset ─────────────────────────────────────────────────
bold "→ Generating .iconset (10 files)"
WORK=$(mktemp -d)
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
# Standard macOS iconset filenames Apple's iconutil expects.
# At each logical size, @1x and @2x variants.
declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)
for entry in "${SIZES[@]}"; do
    px="${entry%%:*}"
    name="${entry##*:}"
    sips -z "$px" "$px" "$SRC" --out "$ICONSET/$name" >/dev/null
done
ok "iconset built"

# ─── 3. compile .icns ────────────────────────────────────────────────
bold "→ Compiling AppIcon.icns"
ICNS="$WORK/AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$ICNS"
ICNS_SIZE=$(stat -f%z "$ICNS")
ok "AppIcon.icns ($(printf '%d KB' $((ICNS_SIZE / 1024))))"

# ─── 4. install ───────────────────────────────────────────────────────
bold "→ Installing into source tree + running build"
SRC_DEST="ModelStatus/Resources"
mkdir -p "$SRC_DEST"
cp "$ICNS" "$SRC_DEST/AppIcon.icns"
ok "ModelStatus/Resources/AppIcon.icns"

APP_DEST="build/ModelStatus.app/Contents/Resources"
if [[ -d "build/ModelStatus.app/Contents" ]]; then
    mkdir -p "$APP_DEST"
    cp "$ICNS" "$APP_DEST/AppIcon.icns"
    ok "build/ModelStatus.app/Contents/Resources/AppIcon.icns"
else
    warn "build/ModelStatus.app not present — skipping live-bundle install (run ./scripts/build-app.sh first)"
fi

# Also preserve the master 1024 PNG so we can regenerate later
MASTER_DEST="ModelStatus/Resources/AppIcon-master-1024.png"
sips -z 1024 1024 "$SRC" --out "$MASTER_DEST" >/dev/null
ok "$MASTER_DEST (master)"

# ─── 5. patch Info.plist ──────────────────────────────────────────────
bold "→ Patching Info.plist"
PLIST="ModelStatus/Info.plist"
if /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$PLIST" >/dev/null 2>&1; then
    CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$PLIST")
    if [[ "$CURRENT" != "AppIcon" ]]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$PLIST"
        ok "CFBundleIconFile updated to AppIcon (was: $CURRENT)"
    else
        ok "CFBundleIconFile already AppIcon"
    fi
else
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"
    ok "CFBundleIconFile = AppIcon added"
fi
# Also keep the running .app Info.plist in sync
if [[ -f "build/ModelStatus.app/Contents/Info.plist" ]]; then
    cp "$PLIST" "build/ModelStatus.app/Contents/Info.plist"
    ok "build/ModelStatus.app/Contents/Info.plist refreshed"
fi

# ─── 6. re-sign ──────────────────────────────────────────────────────
if [[ -d "build/ModelStatus.app" ]]; then
    bold "→ Re-signing build/ModelStatus.app"
    # Use whatever Developer ID Application identity is installed; fall back
    # to adhoc if none. The icon update doesn't strictly require re-signing
    # in dev, but macOS sometimes caches the old icon until the signature
    # rev matches the modified bundle.
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application: Lucas Mullikin"; then
        codesign --force --options runtime --timestamp \
            --entitlements ModelStatus/ModelStatus.entitlements \
            --sign "Developer ID Application: Lucas Mullikin (ZFXWBW78LZ)" \
            build/ModelStatus.app >/dev/null 2>&1
        ok "signed with Developer ID Application"
    else
        codesign --force --sign - build/ModelStatus.app >/dev/null 2>&1
        warn "no Developer ID found — adhoc-signed instead"
    fi
fi

# ─── 7. flush macOS icon cache + relaunch ─────────────────────────────
if [[ $RELAUNCH -eq 1 && -d "build/ModelStatus.app" ]]; then
    bold "→ Relaunching ModelStatus"
    for pid in $(pgrep -f "build/ModelStatus.app" 2>/dev/null); do
        kill "$pid" 2>/dev/null || true
    done
    sleep 1
    # Touch the .app to bump its mtime — sometimes macOS caches icons by mtime
    touch "build/ModelStatus.app"
    open build/ModelStatus.app
    sleep 3
    PID=$(pgrep -f "build/ModelStatus.app" | head -1)
    if [[ -n "$PID" ]]; then
        ok "relaunched, PID $PID"
    else
        warn "process not visible — check Console.app for crash"
    fi
fi

bold "→ Done"
echo
echo "Where the new icon will appear:"
echo "  • Finder (open /Applications then drag in or just navigate to build/)"
echo "  • Spotlight (Cmd-Space → type ModelStatus)"
echo "  • Cmd-Tab switcher (during app launch)"
echo "  • App Store Connect when uploaded"
echo
echo "NOT in the menu bar — that's a separate template image."
echo "NOT in the Dock — ModelStatus is LSUIElement=true, no Dock presence."
echo
echo "To preview at all sizes side-by-side:"
echo "  ./scripts/preview-icon.sh \"$SRC\""
