#!/usr/bin/env bash
# Single-shot v0.1.0-beta release: push, tag, wait, fetch sha256, update cask, ship tap.
# Idempotent where it can be. Stops on first error.

set -euo pipefail
cd "$(dirname "$0")/.."

REPO="lucasmullikin/ModelStatus"
TAP_REPO="lucasmullikin/homebrew-tap"
TAG="v0.1.0-beta"
ASSET="ModelStatus-${TAG}.zip"
STALE_TAG="v3.0.0"

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

# ─── 1. push main ──────────────────────────────────────────────────────────
bold "→ Pushing main"
git push origin main
ok "main pushed"

# ─── 2. delete stale v3.0.0 tag ────────────────────────────────────────────
bold "→ Cleaning up stale ${STALE_TAG} tag"
git tag -d "$STALE_TAG" 2>/dev/null || true
git push origin ":refs/tags/${STALE_TAG}" 2>/dev/null || warn "no remote ${STALE_TAG} tag (already gone)"
ok "${STALE_TAG} tag removed"

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
sed -i '' "s|sha256 :no_check.*|sha256 \"${SHA256}\"|" homebrew-tap/Casks/modelstatus.rb
sed -i '' "s|version \".*\"|version \"${TAG#v}\"|" homebrew-tap/Casks/modelstatus.rb
grep -E "version|sha256" homebrew-tap/Casks/modelstatus.rb | head -2
ok "cask updated"

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
    git push -u origin main --force-with-lease
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
