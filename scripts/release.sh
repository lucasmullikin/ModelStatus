#!/usr/bin/env bash
# Single-shot release: push, tag, wait for CI, fetch sha256, update cask, ship tap.
# Idempotent where it can be. Stops on first error.
#
# Usage: ./scripts/release.sh [TAG]
#   TAG defaults to whatever's in Info.plist as v<CFBundleShortVersionString>-beta
#   Or pass explicitly: ./scripts/release.sh v0.1.1-beta

set -euo pipefail
cd "$(dirname "$0")/.."

REPO="lucasmullikin/ModelStatus"
TAP_REPO="lucasmullikin/homebrew-tap"

# Derive default tag from Info.plist if not supplied
if [[ $# -ge 1 ]]; then
    TAG="$1"
else
    PLIST_VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" ModelStatus/Info.plist)
    TAG="v${PLIST_VER}-beta"
fi

ASSET="ModelStatus-${TAG}.zip"
STALE_TAG="${STALE_TAG:-}"   # No stale-tag cleanup by default; set env var if needed

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[33m!\033[0m %s\n" "$*"; }
die()  { printf "\033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }

# ─── 0. preflight ──────────────────────────────────────────────────────────
bold "→ Preflight"
command -v gh >/dev/null || die "gh CLI not installed"
gh auth status --hostname github.com >/dev/null 2>&1 || die "Not authed: run 'gh auth login'"
ACTIVE_USER=$(gh api user --jq '.login')
[[ "$ACTIVE_USER" == "lucasmullikin" ]] || die "gh authed as '$ACTIVE_USER', need 'lucasmullikin'"
ok "gh authed as lucasmullikin"

# Security preflight: refuse to release if anything secret-shaped is staged
# or in the working tree. Catches accidental `.env` / `*.pem` / credentials
# being included in a release commit.
SUSPECT=$(git status --porcelain | awk '{print $2}' | grep -E '(^|/)\.env(\..*)?$|\.pem$|_key$|secret|credential|password' || true)
if [[ -n "$SUSPECT" ]]; then
    die "Refusing to release — secret-shaped files staged or untracked:
$SUSPECT"
fi
ok "no secret-shaped files in working tree"

# ─── 1. push main ──────────────────────────────────────────────────────────
bold "→ Pushing main"
git push origin main
ok "main pushed"

# ─── 2. delete stale tag (only if STALE_TAG env var set) ───────────────────
if [[ -n "$STALE_TAG" ]]; then
    bold "→ Cleaning up stale ${STALE_TAG} tag"
    git tag -d "$STALE_TAG" 2>/dev/null || true
    git push origin ":refs/tags/${STALE_TAG}" 2>/dev/null || warn "no remote ${STALE_TAG} tag (already gone)"
    ok "${STALE_TAG} tag removed"
fi

# ─── 3. tag v0.1.0-beta and push ───────────────────────────────────────────
bold "→ Tagging ${TAG}"
if git rev-parse "$TAG" >/dev/null 2>&1; then
    warn "local tag ${TAG} already exists, leaving alone"
else
    git tag -a "$TAG" -m "${TAG} — first public release of ModelStatus"
    ok "local tag created"
fi
git push origin "$TAG"
ok "${TAG} pushed → Release workflow triggered"

# ─── 4. wait for Release workflow ──────────────────────────────────────────
bold "→ Waiting for Release workflow to complete (this builds + uploads the .zip; ~2-3 min)"
sleep 5
RUN_ID=$(gh run list --repo "$REPO" --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')
[[ -n "$RUN_ID" ]] || die "no Release workflow run found"
ok "watching run ${RUN_ID}"
gh run watch "$RUN_ID" --repo "$REPO" --exit-status

# ─── 5. fetch artifact sha256 ──────────────────────────────────────────────
bold "→ Fetching release artifact and computing sha256"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ZIP_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
curl -fsSL "$ZIP_URL" -o "${TMP}/${ASSET}" || die "couldn't download ${ZIP_URL}"
SHA256=$(shasum -a 256 "${TMP}/${ASSET}" | awk '{print $1}')
ok "sha256=${SHA256}"

# ─── 6. update homebrew-tap cask ───────────────────────────────────────────
bold "→ Updating homebrew-tap/Casks/modelstatus.rb"
# Match any sha256 line (whether :no_check sentinel or previous real hash) and rewrite.
sed -i '' -E "s|sha256[[:space:]]+(\":no_check.*\"|\"[a-f0-9]{64}\")|sha256 \"${SHA256}\"|" homebrew-tap/Casks/modelstatus.rb
# Match `sha256 :no_check` (no quotes) too for first-run case.
sed -i '' "s|sha256 :no_check.*|sha256 \"${SHA256}\"|" homebrew-tap/Casks/modelstatus.rb
sed -i '' "s|version \".*\"|version \"${TAG#v}\"|" homebrew-tap/Casks/modelstatus.rb
grep -E "version|sha256" homebrew-tap/Casks/modelstatus.rb | head -2

# Audit-round-D6: trust-boundary check for the tap. If someone gains push
# access to the tap repo and rewrites the cask `url` to point at a malicious
# host, sha256 won't help — the hash would still match THEIR binary. Refuse
# to release unless the cask still points at GitHub Releases at the expected
# repo. Sha256 in this run will then bind the user to our binary, not theirs.
EXPECTED_URL_PREFIX="https://github.com/${REPO}/releases/download/"
if ! grep -F "$EXPECTED_URL_PREFIX" homebrew-tap/Casks/modelstatus.rb >/dev/null; then
    die "Cask download URL no longer points at ${EXPECTED_URL_PREFIX}. Refusing to release."
fi
ok "cask updated; download URL trust-boundary check passed"

# ─── 7. publish homebrew tap as its own repo ───────────────────────────────
bold "→ Publishing ${TAP_REPO}"
if gh repo view "$TAP_REPO" >/dev/null 2>&1; then
    warn "${TAP_REPO} already exists, just pushing updated cask"
    cd homebrew-tap
    if [[ ! -d .git ]]; then
        git init -q
        git remote add origin "https://github.com/${TAP_REPO}.git"
    fi
    git add -A
    git commit -m "Update modelstatus cask to ${TAG}" 2>/dev/null || warn "nothing to commit"
    git branch -M main
    # Plain push — refuse rather than overwrite if the remote diverged. The
    # tap is single-purpose, so divergence means a human edited it out of
    # band and deserves a manual look. Audit-round-D5.
    git push -u origin main
    cd ..
else
    cd homebrew-tap
    git init -q
    git branch -M main
    git add -A
    git commit -q -m "Initial tap with modelstatus ${TAG}"
    gh repo create "$TAP_REPO" --public \
        --description "Homebrew tap for ModelStatus and other Lucrative Pictures tools" \
        --source=. --remote=origin --push
    cd ..
fi
ok "${TAP_REPO} live"

# ─── 8. final verification ─────────────────────────────────────────────────
bold "→ Final verification"
gh release view "$TAG" --repo "$REPO" --json tagName,assets -q '"release \(.tagName) — assets: " + (.assets | map(.name) | join(", "))'

cat <<EOF

$(bold "✓ Release complete.")

Install one-liner for users:
    brew tap lucasmullikin/tap && brew install --cask modelstatus
    xattr -dr com.apple.quarantine /Applications/ModelStatus.app
    open /Applications/ModelStatus.app

Release page:
    https://github.com/${REPO}/releases/tag/${TAG}
EOF
