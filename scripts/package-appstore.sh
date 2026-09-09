#!/usr/bin/env bash
# Package the sandboxed App Store build into an uploadable, signed .pkg.
#
# Pipeline (matches the v1.0.0 submission that passed Apple's validation):
#   1. build sandboxed .app           (build-app.sh --app-store)
#   2. embed the App Store provisioning profile
#   3. codesign the .app              (Apple Distribution, hardened runtime, timestamp)
#   4. productbuild → .pkg            (3rd Party Mac Developer Installer)
#   5. (optional) validate/upload     (xcrun altool — API key or app password)
#
# Usage:
#   ./scripts/package-appstore.sh [--profile PATH] [--validate] [--upload]
#
#   --profile PATH   OPTIONAL App Store distribution .provisionprofile for
#                    com.lucasmullikin.ModelStatus. The v1.0.0 build that
#                    PASSED Apple's validation (2026-06-01) had NO embedded
#                    profile — a sandboxed app whose only entitlements are
#                    app-sandbox + network.client + user-selected files does
#                    not need one for the MAS upload. Pass this only if a
#                    future entitlement (e.g. an App Group or a capability)
#                    starts requiring it.
#   --validate       Run `altool --validate-app` after building the .pkg.
#   --upload         Run `altool --upload-app` after building the .pkg.
#
# For --validate / --upload you must export the credentials first so the
# app-specific password never lands in shell history or this file:
#   PREFERRED — App Store Connect API key (Developer role):
#     ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8   (chmod 600)
#     ~/.appstoreconnect/issuer_id                          (or export ASC_ISSUER_ID)
#   The key id is read from the filename; nothing secret goes in the environment.
#
#   FALLBACK — app-specific password:
#     export ASC_APPLE_ID="lucasstuff@protonmail.com"
#     export ASC_APP_PASSWORD="<app-specific-password>"   # from account.apple.com
#
# The .app, Distribution cert, and Installer cert are all team ZFXWBW78LZ.

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=""
DO_VALIDATE=0
DO_UPLOAD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)  PROFILE="$2"; shift 2 ;;
        --validate) DO_VALIDATE=1; shift ;;
        --upload)   DO_UPLOAD=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

APP_CERT="Apple Distribution: Lucas Mullikin (ZFXWBW78LZ)"
INSTALLER_CERT="3rd Party Mac Developer Installer: Lucas Mullikin (ZFXWBW78LZ)"
ENTITLEMENTS="ModelStatus/ModelStatus-AppStore.entitlements"
# The bundle filename of the proven 2026-06-01 upload. build-app.sh emits
# build/ModelStatus.app; we rename to match the artifact Apple already accepted.
APP="build/ModelStatus-AppStore.app"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$*"; }
die()  { printf "\033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }

[[ -z "$PROFILE" || -f "$PROFILE" ]] || die "profile not found: $PROFILE"

# ─── 1. build sandboxed .app ────────────────────────────────────────────────
bold "→ Building sandboxed App Store binary"
./scripts/build-app.sh --app-store >/dev/null
rm -rf "$APP"
mv build/ModelStatus.app "$APP"
ok "built $APP"

VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
ok "version $VER (build $BUILD)"

# ─── 2. embed provisioning profile (only if supplied) ───────────────────────
if [[ -n "$PROFILE" ]]; then
    bold "→ Embedding provisioning profile"
    PROFILE_PLIST=$(security cms -D -i "$PROFILE" 2>/dev/null) || die "couldn't decode profile"
    PROFILE_APPID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" /dev/stdin <<<"$PROFILE_PLIST" 2>/dev/null || true)
    PROFILE_EXP=$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" /dev/stdin <<<"$PROFILE_PLIST" 2>/dev/null || true)
    echo "  profile app-id:  ${PROFILE_APPID:-<unknown>}"
    echo "  profile expires: ${PROFILE_EXP:-<unknown>}"
    case "$PROFILE_APPID" in
        *com.lucasmullikin.ModelStatus) ok "profile matches bundle id" ;;
        "") echo "  ! couldn't read app-id from profile — continuing, but verify it's correct" ;;
        *) die "profile app-id ($PROFILE_APPID) does not match com.lucasmullikin.ModelStatus" ;;
    esac
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    ok "embedded.provisionprofile in place"
else
    bold "→ No provisioning profile (matches the proven v1.0.0 upload)"
    ok "skipping embed — sandboxed app with basic entitlements needs none"
fi

# ─── 3. codesign the .app ───────────────────────────────────────────────────
bold "→ Codesigning (Apple Distribution, hardened runtime, timestamp)"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$APP_CERT" \
    "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -2
ok "signed $APP"

# ─── 4. productbuild → .pkg ─────────────────────────────────────────────────
PKG="build/ModelStatus-v${VER}-${BUILD}.pkg"
bold "→ Building installer .pkg → $PKG"
productbuild --component "$APP" /Applications \
    --sign "$INSTALLER_CERT" \
    "$PKG"
ok "built $PKG ($(du -h "$PKG" | cut -f1))"

# ─── 5. optional validate / upload ──────────────────────────────────────────
# Two auth paths, API key preferred. The 2026-06-09 resubmit died here on a
# 401 from the app-specific-password path (the password had almost certainly
# been minted under a different Apple ID than the one that owns the app), and
# that single failure is why the fixed build never shipped. An API key has no
# secret in the environment, does not expire with the Apple ID password, and
# works unattended.
ASC_KEY_DIR="${ASC_KEY_DIR:-$HOME/.appstoreconnect/private_keys}"
AUTH_ARGS=()
AUTH_KIND=""

if [[ $DO_VALIDATE -eq 1 || $DO_UPLOAD -eq 1 ]]; then
    # Derive the key id from the filename when exactly one key is installed —
    # altool wants the bare KEYID from AuthKey_<KEYID>.p8.
    if [[ -z "${ASC_KEY_ID:-}" && -d "$ASC_KEY_DIR" ]]; then
        shopt -s nullglob
        _keys=("$ASC_KEY_DIR"/AuthKey_*.p8)
        shopt -u nullglob
        if [[ ${#_keys[@]} -eq 1 ]]; then
            _base="$(basename "${_keys[0]}" .p8)"
            ASC_KEY_ID="${_base#AuthKey_}"
        elif [[ ${#_keys[@]} -gt 1 ]]; then
            die "multiple keys in $ASC_KEY_DIR — set ASC_KEY_ID to pick one"
        fi
    fi
    # Issuer id from the environment, or a one-line file beside the keys.
    if [[ -z "${ASC_ISSUER_ID:-}" && -f "$HOME/.appstoreconnect/issuer_id" ]]; then
        ASC_ISSUER_ID="$(tr -d '[:space:]' < "$HOME/.appstoreconnect/issuer_id")"
    fi

    if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
        AUTH_ARGS=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
        AUTH_KIND="API key $ASC_KEY_ID"
    elif [[ -n "${ASC_APPLE_ID:-}" && -n "${ASC_APP_PASSWORD:-}" ]]; then
        AUTH_ARGS=(-u "$ASC_APPLE_ID" -p "$ASC_APP_PASSWORD")
        AUTH_KIND="app-specific password for $ASC_APPLE_ID"
    else
        die "no upload credentials. Use either:
  API key  — put AuthKey_<KEYID>.p8 in $ASC_KEY_DIR, then set ASC_ISSUER_ID
             (or write it to ~/.appstoreconnect/issuer_id)
  password — export ASC_APPLE_ID and ASC_APP_PASSWORD"
    fi
    bold "→ auth: $AUTH_KIND"
fi
if [[ $DO_VALIDATE -eq 1 ]]; then
    bold "→ Validating with altool"
    xcrun altool --validate-app -f "$PKG" -t macos "${AUTH_ARGS[@]}"
    ok "validation passed"
fi
if [[ $DO_UPLOAD -eq 1 ]]; then
    bold "→ Uploading with altool"
    xcrun altool --upload-app -f "$PKG" -t macos "${AUTH_ARGS[@]}"
    ok "uploaded — check App Store Connect → TestFlight/Activity for processing"
fi

echo
bold "Done."
echo "  Signed package: $PKG"
if [[ $DO_UPLOAD -eq 0 ]]; then
    echo
    echo "Next — validate then upload:"
    echo "    # API key path (preferred): AuthKey_<KEYID>.p8 in ~/.appstoreconnect/private_keys/"
    echo "    #                           plus ASC_ISSUER_ID or ~/.appstoreconnect/issuer_id"
    echo "    # password path:            export ASC_APPLE_ID and ASC_APP_PASSWORD"
    echo "    ./scripts/package-appstore.sh --profile \"$PROFILE\" --validate"
    echo "    ./scripts/package-appstore.sh --profile \"$PROFILE\" --upload"
fi
