# Launch posts — ready-to-paste drafts (v1.0.0)

Pick a venue, copy the block, post when ready. **Don't post the same thing simultaneously to multiple Reddit subs** — looks spammy. Stagger by a day; see `LAUNCH-SCHEDULE.md` for timing.

**Context:** ModelStatus v1.0.0 was approved by Apple App Store Review on 2026-05-29. Three install paths:

- **Mac App Store** ($6.99, sandboxed, auto-updates): https://apps.apple.com/app/modelstatus/id6774341064
- **Homebrew tap** (free, unsandboxed direct download with Start/Stop Local Ollama + Diagnostic Bundle export): `brew tap lucasmullikin/tap && brew install --cask modelstatus`
- **Source** (MIT): https://github.com/lucasmullikin/ModelStatus

Pricing is split because Apple's sandbox forbids local-process inspection (lsof/ps/shell exec). App Store users get sandboxed-safe HTTP polling + LAN discovery + auto-updates; direct-download users get the full feature set free. Same source tree, two compile-time targets.

---

## r/LocalLLaMA  ← post here FIRST (Tue 10am ET)

**Title** (Reddit-native bracket prefix, fits in 300-char limit):

> [Tool] ModelStatus — macOS menu bar app for monitoring multiple local LLM servers at once (Ollama / LM Studio / vLLM / MLX / llama.cpp). Now on the Mac App Store.

**Body**:

```
I run Ollama on my Mac Studio, MLX on a Mac mini, and a vLLM box behind Tailscale. Wanted one place to see what's loaded where, how much VRAM is in use, who's hitting each server, and whether anything is generating right now. Nothing existed that did multi-instance + multi-backend, so I built it.

ModelStatus lives in your menu bar. One colored dot per server:

  🟢 active — model loaded, ready to serve
  🔵 generating — actively producing tokens right now (vLLM /metrics-driven)
  🟡 idle — server up but no model loaded in RAM
  🔴 unreachable — server down or unreachable

Click the brain icon to see per-server detail: model name, VRAM, latency, last-active timestamp, client process. Eject or load models from the menu — no terminal needed.

Backends supported:
  • Ollama
  • LM Studio
  • vLLM (with /metrics-driven Generating state detection)
  • MLX (mlx_lm.server, mlx-omni-server)
  • llama.cpp
  • Any OpenAI-compatible HTTP API

Two paths to install:

  Mac App Store ($6.99, sandboxed, auto-updates):
  https://apps.apple.com/app/modelstatus/id6774341064

  Homebrew (free, MIT, unsandboxed, full feature set):
  brew tap lucasmullikin/tap && brew install --cask modelstatus

Source: https://github.com/lucasmullikin/ModelStatus

Privacy: zero telemetry, zero analytics, zero crash reporters. The only outbound network is to the model servers you configure yourself + once-per-launch GitHub releases check (sandboxed build skips this). Privacy manifest declares Data Not Collected for all 14 Apple categories.

v1.0.0. Built on macOS, runs on Apple Silicon. Bug reports welcome.
```

---

## r/macapps  ← post Wed 10am ET (24h after r/LocalLLaMA)

**Title**:

> ModelStatus — menu bar app for monitoring local AI model servers (Ollama, LM Studio, vLLM, MLX). $6.99 on the Mac App Store.

**Body**:

```
Just shipped v1.0.0 to the Mac App Store after a couple of months of polish. Built it for myself because I was tab-switching constantly between three Macs to see which models were loaded where.

What it does:
  • Multi-server monitoring from one menu bar icon
  • Per-server state (active, generating, idle, unreachable)
  • Live VRAM, latency, last-active timestamp
  • Discover button auto-finds servers on your local network + Tailscale peers
  • Authorization headers stored in Keychain (for tunneled/remote servers)
  • Notifications when a server goes down or comes back

Two builds, same source:

  Mac App Store — $6.99, sandboxed, auto-updates via App Store:
  https://apps.apple.com/app/modelstatus/id6774341064

  Direct download via Homebrew — free, MIT, unsandboxed, keeps the
  Start/Stop Local Ollama + Diagnostic Bundle export features that
  sandbox forbids:
  brew tap lucasmullikin/tap && brew install --cask modelstatus

Source: https://github.com/lucasmullikin/ModelStatus

Privacy: ModelStatus collects nothing. No telemetry, no analytics, no crash reports. Privacy manifest matches. Privacy policy: https://github.com/lucasmullikin/ModelStatus/blob/main/docs/PRIVACY.md

Why $6.99 on App Store but free direct download:
- Apple's sandbox forbids the lsof/ps process inspection features (clientProcess display, CPU/RSS readout, Start/Stop Local Ollama)
- The sandboxed App Store build degrades gracefully — HTTP polling, model lists, eject/load, LAN discovery all work; the local-process-inspection features are hidden
- For users who want the full feature set, the direct-download build is forever free
- For everyone else (auto-updates, sandbox isolation, no Gatekeeper friction), App Store at $6.99
```

---

## Hacker News (Show HN)

**Title** (Show HN format, ≤80 chars):

> Show HN: ModelStatus – macOS menu bar app for monitoring local LLM servers

**Body**:

```
ModelStatus is a macOS menu bar utility for monitoring local AI model servers — Ollama, LM Studio, vLLM, MLX, llama.cpp, anything OpenAI-compatible. One server icon per instance with colored-dot state at a glance, per-server detail when you click in.

I run Ollama on my Mac Studio, MLX on a Mac mini, and a vLLM box behind Tailscale. Wanted one place to see what's loaded where. Built this for myself, sharing because friends kept asking.

Pricing & licensing is split deliberately:

- $6.99 on the Mac App Store: https://apps.apple.com/app/modelstatus/id6774341064 — sandboxed, auto-updates, less feature-rich (sandbox forbids lsof/ps for process inspection)
- Free direct download via Homebrew: `brew tap lucasmullikin/tap && brew install --cask modelstatus` — Developer ID signed + notarized, full feature set, MIT source

Same codebase, two compile-time targets (`MODELSTATUS_APP_STORE` flag swaps in a sandboxed `LocalSystemAccess` provider that returns nil for syscall-based inspection).

Source: https://github.com/lucasmullikin/ModelStatus
Privacy policy: https://github.com/lucasmullikin/ModelStatus/blob/main/docs/PRIVACY.md (zero data collection, no telemetry, full CCPA/CPRA + GDPR + 8 US state law compliance)

Stack: Swift 5.9, AppKit, Foundation, CryptoKit, OSLog. Audited by Codex + Claude Code's `architect` and `security-reviewer` agents.

Happy to answer questions about the App Store sandbox dance, the dual-build setup, or the Discovery LAN-scan implementation.
```

---

## Twitter / X

```
Just shipped ModelStatus v1.0 to the Mac App Store.

Menu bar app for monitoring local AI servers — Ollama, LM Studio, vLLM, MLX, llama.cpp. One colored dot per instance with VRAM, latency, generating-now state.

App Store: $6.99 sandboxed + auto-updates
Homebrew: free, full feature set, MIT

apps.apple.com/app/modelstatus/id6774341064
github.com/lucasmullikin/ModelStatus
```

---

## Mastodon / Bluesky

(Same as Twitter but break into thread because of post-length limits)

**Post 1**:

```
Shipped ModelStatus v1.0 to the Mac App Store today 🎉

Menu bar utility for monitoring local AI model servers — Ollama, LM Studio, vLLM, MLX, llama.cpp, any OpenAI-compatible HTTP API.

apps.apple.com/app/modelstatus/id6774341064
```

**Post 2** (reply to Post 1):

```
Two install paths, same source:

📱 Mac App Store ($6.99, sandboxed, auto-updates)
🍺 brew tap lucasmullikin/tap && brew install --cask modelstatus (free, MIT, full feature set)

Privacy: zero telemetry, zero analytics, manifest matches. Source: github.com/lucasmullikin/ModelStatus
```

**Post 3** (reply to Post 2):

```
Why I split it:

Apple's sandbox forbids lsof/ps. The sandboxed App Store build degrades gracefully (HTTP polling + model lists + eject/load all work). For users who want process inspection + Start/Stop Local Ollama + Diagnostic Bundle export, the direct-download Homebrew build keeps everything, free.
```

---

## Awesome lists (PRs)

For each awesome-list PR, the listing line should be a single bullet pointing at the GitHub repo (NOT the App Store URL — awesome lists are for tools, not products).

### `awesome-ollama`

Add under "Tools" or "Monitoring":

```markdown
- [ModelStatus](https://github.com/lucasmullikin/ModelStatus) - macOS menu bar app for monitoring multiple local LLM servers at once (Ollama, LM Studio, vLLM, MLX, llama.cpp). One status dot per server with live VRAM, latency, and generating-now state. Also on the [Mac App Store](https://apps.apple.com/app/modelstatus/id6774341064).
```

### `awesome-llm-tools` / `awesome-local-llm`

```markdown
- [ModelStatus](https://github.com/lucasmullikin/ModelStatus) — macOS menu bar app for monitoring multiple local AI model servers (Ollama, vLLM, MLX, etc.). MIT + Mac App Store.
```

### `awesome-macos`

```markdown
- [ModelStatus](https://github.com/lucasmullikin/ModelStatus) - Menu bar app for monitoring local AI model servers (Ollama, LM Studio, vLLM, MLX, llama.cpp). Mac App Store + free Homebrew.
```

---

## Press / blog reach-outs (optional, lower priority than community posts)

Post the community channels first, see organic traction, only reach out to publications if there's something interesting to write about (e.g. a particularly clever sandbox dance, or an unusual privacy story).

- daringfireball.net — link-list culture, send Markdown summary with one-line pitch
- macstories.net — full reviews, send the App Store link + a paragraph + 2 screenshots
- 9to5mac.com / appleinsider.com — AI-on-Mac angle, mention price + sandbox split
- macworld.com — review queue

---

## Anti-patterns — what NOT to do

- **Don't** post the same thread simultaneously to 3 subreddits + Show HN + Twitter. Stagger.
- **Don't** rewrite history about "v1 launch" if v0.2.0 already shipped through Homebrew. Be honest: "v1 = first App Store release, source available since v0.1."
- **Don't** ask for upvotes. Reddit + HN will detect and remove. Just post.
- **Don't** respond defensively to "why $6.99 for a menu bar app?" — explain the value (auto-updates + sandbox + Apple's payment infrastructure) and remind them the source is free.
- **Don't** promise an Android/iOS/Windows/Linux version unless you're committed. Easier to add later than walk back.
- **Don't** post on a Friday afternoon. Tuesday or Wednesday morning ET catches the best US + EU window.
