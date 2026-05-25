#!/usr/bin/env bash
# Launch script — push the pre-prepared ollama/ollama Community Integrations PR.
# The fork + branch + commit are already set up at ~/Documents/ollama.
# This script just pushes + opens the PR.

set -euo pipefail

FORK_DIR="$HOME/Documents/ollama"
BRANCH="add-modelstatus"
UPSTREAM="ollama/ollama"
PR_TITLE="readme: add ModelStatus to community integrations"
PR_BODY='Adds ModelStatus to the Desktop subsection of Community Integrations.

ModelStatus is a free, open-source (MIT) macOS menu bar app that monitors Ollama (and other local LLM servers — LM Studio, vLLM, llama.cpp, MLX, anything OpenAI-compatible) at a glance. It auto-detects the backend type from the URL, supports eject/load from the menu, includes LAN + Tailscale-peer discovery, no telemetry, no account.

- Source: https://github.com/lucasmullikin/ModelStatus
- Install: `brew tap lucasmullikin/tap && brew install --cask modelstatus`

No code change to ollama itself — single README line addition.'

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$*"; }
die()  { printf "\033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }

[[ -d "$FORK_DIR/.git" ]] || die "Fork dir $FORK_DIR not found. Run 'gh repo fork ollama/ollama --clone' first."
command -v gh >/dev/null || die "gh CLI not installed"
gh auth status --hostname github.com >/dev/null 2>&1 || die "Not authed: run 'gh auth login'"

cd "$FORK_DIR"
bold "→ In $FORK_DIR"
git checkout "$BRANCH" 2>/dev/null || die "Branch $BRANCH not found locally"
echo "Pending commit:"
git log -1 --oneline
echo
echo "Diff:"
git show --stat HEAD
echo
read -r -p "Push this to your fork and open PR against $UPSTREAM? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || die "aborted"

bold "→ Pushing branch to fork"
git push -u origin "$BRANCH"
ok "pushed"

bold "→ Opening PR against $UPSTREAM"
PR_URL=$(gh pr create \
    --repo "$UPSTREAM" \
    --head "lucasmullikin:$BRANCH" \
    --title "$PR_TITLE" \
    --body "$PR_BODY" 2>&1 | tail -1)
ok "PR opened: $PR_URL"

cat <<EOF

$(bold "Done.")
Watch the PR:   gh pr view --repo $UPSTREAM --web $(basename "$PR_URL" 2>/dev/null || echo "")
Check status:   gh pr status

Maintainer review typically takes a few days for single-line README additions.
EOF
