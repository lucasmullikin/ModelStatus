#!/usr/bin/env bash
# Install ModelStatus LaunchAgent so it starts at login.
# Idempotent — safe to re-run.

set -euo pipefail

BUNDLE_ID="com.lucrativepictures.ModelStatus"
DST="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
ok()    { printf "\033[32m✓\033[0m %s\n" "$*"; }
warn()  { printf "\033[33m!\033[0m %s\n" "$*"; }
die()   { printf "\033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }

# Find the plist source — prefer brew cask install, fall back to repo
SRC=""
if command -v brew >/dev/null 2>&1; then
    BREW_PREFIX="$(brew --prefix)"
    VERSION="$(ls "${BREW_PREFIX}/Caskroom/modelstatus/" 2>/dev/null | grep -E '^[0-9]' | sort -V | tail -1 || true)"
    if [[ -n "$VERSION" ]]; then
        CANDIDATE="${BREW_PREFIX}/Caskroom/modelstatus/${VERSION}/LaunchAgent/${BUNDLE_ID}.plist"
        [[ -f "$CANDIDATE" ]] && SRC="$CANDIDATE"
    fi
fi
if [[ -z "$SRC" ]]; then
    REPO_CANDIDATE="$(dirname "$0")/../LaunchAgent/${BUNDLE_ID}.plist"
    [[ -f "$REPO_CANDIDATE" ]] && SRC="$REPO_CANDIDATE"
fi
[[ -n "$SRC" ]] || die "Could not find ${BUNDLE_ID}.plist. Install via: brew install --cask modelstatus"

bold "→ Source plist: $SRC"

# Make sure target dir exists
mkdir -p "$HOME/Library/LaunchAgents"

# If already loaded, unload first so the bootstrap doesn't fail with "Service already loaded"
if launchctl print "gui/$UID/${BUNDLE_ID}" >/dev/null 2>&1; then
    warn "Existing LaunchAgent loaded — unloading first"
    launchctl bootout "gui/$UID" "$DST" 2>/dev/null || true
fi

cp "$SRC" "$DST"
ok "Copied plist → $DST"

# Bootstrap (modern) with fallback to legacy load (older macOS)
if launchctl bootstrap "gui/$UID" "$DST" 2>/dev/null; then
    ok "Loaded via launchctl bootstrap"
elif launchctl load "$DST" 2>/dev/null; then
    ok "Loaded via launchctl load (legacy)"
else
    die "launchctl bootstrap and load both failed"
fi

ok "ModelStatus will now start at login"
echo
echo "To disable later:"
echo "    launchctl bootout gui/\$UID $DST"
echo "    rm $DST"
