# Launch posts — ready-to-paste drafts (v0.2.0)

Pick a venue, copy the block, post when ready. **Don't post the same thing simultaneously to multiple Reddit subs** — looks spammy. Stagger by a day; see `LAUNCH-SCHEDULE.md` for timing.

**Why v0.2 not v0.1:** v0.1.0-beta shipped to GitHub but was never posted anywhere. v0.2.0 is the genuine first launch — same scope but with a dedicated MLX provider, OSLog viewer, privacy-scrubbed diagnostic-bundle export, and 50+ rounds of security/correctness hardening behind it. Better launch moment.

---

## r/LocalLLaMA  ← post here FIRST (Tue 10am ET)

**Title** (Reddit-native bracket prefix, fits in 300-char limit):

> [Tool] ModelStatus — macOS menu bar app for monitoring multiple local LLM servers at once (Ollama / LM Studio / vLLM / MLX / llama.cpp)

**Body**:

```
I run Ollama on my Mac Studio, MLX on a Mac mini, and a vLLM box behind Tailscale. Wanted one place to see what's loaded where, how much VRAM is in use, who's hitting each server, and whether anything is generating right now. Nothing existed that did multi-instance + multi-backend, so I built it.

ModelStatus lives in your menu bar. One colored dot per server:
- 🟢 active (models loaded)
- 🔵 generating (only for Ollama — it's the only backend that exposes that)
- 🟡 idle (reachable, nothing loaded)
- 🔴 unreachable

Click for the full per-server view: model names, VRAM, eject/load from the menu (Ollama + LM Studio supported), CPU/memory of the local server process, which process is currently talking to it (Python? curl? Claude?), last-active time, request latency.

Network discovery: click a button, scans your LAN /24 + Tailscale peers for common model-server ports (11434, 1234, 8080, 8000), shows you a list with checkboxes.

MLX support is first-class as of v0.2: dedicated provider with HuggingFace cache enumeration, scheme-aware default port (https://localhost works), local-process argv verification so a non-MLX endpoint on the same port can't accidentally expose your MLX cache.

Open source, MIT, Swift/AppKit. No telemetry, no analytics, no cloud, no account. macOS 13+. Built for myself; sharing because every time I described it people asked where to get it.

  brew tap lucasmullikin/tap
  brew install --cask modelstatus
  # Then once:
  xattr -dr com.apple.quarantine /Applications/ModelStatus.app

Source + releases: https://github.com/lucasmullikin/ModelStatus

v0.2.0. Built on macOS, runs on Apple Silicon. Bug reports very welcome.
```

---

## Show HN  ← post Wed (after r/LocalLLaMA settles)

**Title** (≤80 chars):

> Show HN: ModelStatus – macOS menu bar app for monitoring local LLM servers

**Body**:

```
Built this because I have Ollama on my laptop, MLX on a Mac mini, and a remote vLLM box behind Tailscale — and there's no single tool that shows me what's loaded on each, how much VRAM is in use, and who's actually hitting them right now.

ModelStatus puts a 🧠 in your menu bar with one colored dot per server (active / generating / idle / unreachable). Click for details: loaded models, VRAM, CPU, who's connected (via lsof for local instances), last-active time, response latency.

Auto-detects which kind of backend each URL is (Ollama → /api/ps, LM Studio → /api/v0/models, vLLM → /metrics, MLX → /v1/models + argv inspection, anything else → /v1/models). Eject + load models from the menu where the backend supports it. Network discovery scans your /24 and Tailscale peers for known model-server ports.

A few things worth mentioning for HN:

- Swift, AppKit, no dependencies (no Sparkle, no Alamofire — Foundation only)
- All polling is async/await against an actor-isolated `Monitor`; @MainActor `ConfigManager` for UI safety
- Diagnostic bundle export with salted-SHA-256 hostname anonymization (salt in Keychain), URL/credential redaction, symlink-resistant zip staging
- URL validator canonicalizes octal/hex/decimal/shortened IPv4 + compressed IPv6, blocks cloud metadata endpoints, link-local, Tailscale CGNAT, RFC 1918
- DNS-rebinding pre-resolution guard via getaddrinfo, no-redirect URLSession delegate, 4 MB streaming response cap
- Unsandboxed by default because the local telemetry needs lsof/ps; v0.2 introduced a LocalSystemAccess protocol so a future App Store sandboxed target degrades gracefully (HTTP polling continues, local-process inspection returns nil)
- Adhoc-signed for now; Apple Developer enrollment is next

50+ rounds of Codex audit-fix iteration + 1 architect outside-review pass behind v0.2. The code's been hardened more than the surface area would suggest.

MIT, no telemetry, no account, no cloud:

  brew tap lucasmullikin/tap
  brew install --cask modelstatus
  xattr -dr com.apple.quarantine /Applications/ModelStatus.app

Source: https://github.com/lucasmullikin/ModelStatus
```

---

## r/macapps  ← post Thu (after Show HN settles)

**Title**:

> ModelStatus — Free menu bar app for monitoring local AI model servers (Ollama, LM Studio, vLLM, MLX)

**Body**:

```
Quick share. I built ModelStatus because I run multiple local AI model servers — Ollama on the Mac Studio, MLX on a Mac mini, sometimes vLLM on a Linux box behind Tailscale — and I wanted one place to see what's loaded where, how much memory is being used, and whether anything is actively running.

It's a menu bar app. One colored dot per server: green = active with models loaded, blue = generating right now (Ollama only — others don't expose that state), yellow = reachable but idle, red = down. Click to see model names, VRAM, CPU, and what process is currently hitting each local server.

Some indie-Mac-tool-specific notes:
- Pure Swift / AppKit. No Catalyst, no Electron, no SwiftUI workarounds. 1.4 MB binary.
- No telemetry, no analytics, no account, no cloud.
- macOS 13+ (Ventura). Apple Silicon native arm64.
- MIT license. Forever free for direct download; future paid App Store version planned to fund development but the source stays free.
- Currently unsigned (Apple Developer enrollment in progress). You'll need to run `xattr -dr com.apple.quarantine /Applications/ModelStatus.app` once after install.

Install:

  brew tap lucasmullikin/tap && brew install --cask modelstatus

Source + releases: https://github.com/lucasmullikin/ModelStatus

v0.2.0. Built it for myself; sharing because friends kept asking where to get it.
```

---

## Twitter / X thread  ← optional, post Tue evening alongside Reddit

**Tweet 1** (hook):

> Just shipped ModelStatus v0.2 🧠
>
> macOS menu bar app for monitoring every local LLM server you're running at once — Ollama, LM Studio, vLLM, MLX, llama.cpp.
>
> Free, MIT, no telemetry.
>
> brew tap lucasmullikin/tap && brew install --cask modelstatus
>
> https://github.com/lucasmullikin/ModelStatus

**Tweet 2** (screenshot):

> One brain 🧠, one colored dot per server. Green = active, blue = generating (Ollama only — it's the only backend that exposes generation state), yellow = idle, red = down. Click to see what's loaded, how much VRAM, who's hitting it.
>
> [attach docs/screenshots/dropdown.png]

**Tweet 3** (network discovery + MLX):

> Built-in LAN + Tailscale peer discovery scans for common model-server ports (11434, 1234, 8080, 8000). v0.2 adds a dedicated MLX provider with HuggingFace cache enumeration + argv-based local-process verification.

**Tweet 4** (privacy + open source):

> No telemetry, no account, no cloud. Diagnostic bundle export is salted-SHA-256-anonymized — hostnames and credentials never leave your machine unscrambled. Auth headers live in Keychain only.
>
> 50+ rounds of audit-fix iteration before v0.2. Source: https://github.com/lucasmullikin/ModelStatus

**Tweet 5** (tagging — last reply so it doesn't dominate the thread):

> Works with @ollama, @LMStudioAI, @vllm_project, llama.cpp, MLX, and anything else that speaks `/v1/models`. Auto-detects the backend type per URL.
>
> Bug reports → GitHub issues.

---

## Ollama community integrations PR (status: ALREADY OPEN)

**PR**: https://github.com/ollama/ollama/pull/16291 — opened 2026-05-25, still pending merge.
**v0.2 refinement comment added**: 2026-05-26.

No further action needed unless the maintainers respond.

---

## Awesome-list submissions

PR target list:
- https://github.com/jaywcjlove/awesome-mac → "Applications" → "Menu Bar Tools" (or "AI" if it exists)
- https://github.com/iCHAIT/awesome-macOS → "Productivity" or "Utilities"
- https://github.com/Hannibal046/Awesome-LLM → "Tooling" or "UI / GUI"
- (if it exists) any awesome-ollama list — search GitHub

**Shared blurb** (alphabetize in target list):

```
- [ModelStatus](https://github.com/lucasmullikin/ModelStatus) — Free, open-source macOS menu bar app for monitoring multiple local LLM servers (Ollama, LM Studio, vLLM, MLX, llama.cpp). Multi-instance, auto-provider-detect, LAN + Tailscale discovery, no telemetry.
```

**PR title pattern**:

> Add ModelStatus to <section name>

**PR body template**:

```
Adds ModelStatus to <section>.

ModelStatus is a free, open-source (MIT) macOS menu bar app for monitoring multiple local LLM servers — Ollama, LM Studio, vLLM, MLX, llama.cpp, and any OpenAI-compatible API. Multi-instance, auto-provider-detect, LAN + Tailscale discovery. Pure Swift/AppKit, no dependencies, no telemetry, no account.

- Source: https://github.com/lucasmullikin/ModelStatus
- Install: `brew tap lucasmullikin/tap && brew install --cask modelstatus`

No code change to the awesome-list itself beyond the one-line addition.
```
