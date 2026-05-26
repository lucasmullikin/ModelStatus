# Changelog

All notable changes to ModelStatus.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0] — TBD

Mac App Store release.

### Added
- **Sandboxed build** — App Sandbox enabled; `LocalSystemAccess` protocol gates all process-inspection calls behind `SandboxedLocalSystemAccess` (HTTP-only polling; CPU/RSS/client-process/Tailscale discovery degrade to "unavailable" gracefully).
- **SMAppService start-at-login** — Settings → "Start ModelStatus at login" checkbox replaces manual LaunchAgent installation.
- **Capability gating** — `LocalSystemAccess.configure()` rejects `DirectLocalSystemAccess` under the `MODELSTATUS_APP_STORE` compile flag; sandbox builds always receive `SandboxedLocalSystemAccess`.
- **App Store distribution** — $6.99 one-time purchase, free updates forever.

---

## [0.2.1] — 2026-05-26

### Changed
- **Bundle ID renamed**: `com.lucrativepictures.ModelStatus` → `com.lucasmullikin.ModelStatus` (Individual Apple Developer enrollment; LLC dropped from bundle ID, copyright, and About panel). Legacy migration in `ConfigManager` automatically carries forward user state from v0.2.0 on first launch.
- **4 architectural refactors** (deferred post-v0.2): Anonymizer `ParsedAuthority` struct consolidating 3 URL-parsing pipelines; `Monitor` rewritten to deliver events via `AsyncStream` (`statusEvents` / `reachabilityEvents`) replacing closure callbacks; `Provider.swift` split into `Provider.swift` / `HTTPHelpers.swift` / `LocalProbe.swift` / `Shell.swift`; MLX `argv` hoisted from inline probe logic.

### Added
- **Logging audit** — ~15 new `.notice`-level `OSLog` entries covering poll cycles, reachability transitions, auto-detection, discovery scans, settings actions, and app lifecycle events.
- **`LocalSystemAccess` trust boundary** — `LocalSystemAccess.configure()` now explicitly rejects `DirectLocalSystemAccess` when `MODELSTATUS_APP_STORE` is set at compile time, making sandbox enforcement a hard compile-time gate rather than a runtime convention.

### Fixed
- **LogViewer**: `OSLogStore.local()` replaces `OSLogStore(scope: .currentProcessIdentifier)`, which returned 0 entries on hardened-runtime signed builds.
- **Anonymizer IPv6 parsing**: `fe80::1` was mis-parsed as host `fe80:` / port `:1` due to incorrect unbracketed colon-count logic. Now correctly identified as a bare IPv6 address with no port.
- **Anonymizer bracket stripping**: `straddledCredHostPattern` now strips brackets before hashing the host, preventing `[fe80::1]` from being hashed differently than `fe80::1`.
- **MLXProvider HTTP-fallback**: sandbox builds where `localProcessInfo` is nil now consistently fall back through `probe()` → `check()` → `availableModels()` with the MLX-shape model-ID gate applied at each step.

### Security / Review
- Architect + Codex hard-mode gate review completed prior to release.

---

## [0.1.1-beta] — 2026-05-25

Hours after v0.1.0-beta shipped, a post-release Codex 5.5 audit caught two
URL-validator bypasses. Plus polish from the launch-prep work that didn't
make the v0.1.0 cut.

### Security
- **URLValidator**: explicit non-http schemes (`file://`, `ftp://`, `mailto:`, `javascript:`, etc.) were getting `http://` prepended and silently passing validation. Now detected via RFC-3986 scheme regex and rejected with `unsupportedScheme`.
- **URLValidator**: cloud-metadata blocklist match was exact-string. Now lowercases + strips trailing dot before compare, and adds the `metadata` GCP shortcut. `metadata.google.internal.` (trailing dot) and `metadata` (bare hostname) no longer bypass.
- 6 new XCTest cases covering the bypass vectors.

### Added
- README: build / release / downloads / license / macOS / Swift badges.
- README: real screenshot of the menu dropdown (was placeholder).
- `.github/FUNDING.yml` — GitHub Sponsors button enabled.
- `docs/launch-posts.md` — drafts for HN / Reddit / Twitter / Mastodon / awesome-lists.
- `scripts/launch.sh` — one-shot helper to push the Ollama community-integrations PR.
- `scripts/install-launchagent.sh` — idempotent start-at-login installer (cask caveats only printed instructions; this script actually does it).
- `scripts/release.sh` — now takes a `TAG` argument (defaults to `v$Info.plist-beta`); stale-tag cleanup is opt-in via env var.
- GitHub Discussions enabled.
- 10 repo topics for discovery (`menu-bar-app`, `ollama`, `lm-studio`, `vllm`, `mlx`, `local-llm`, `swift`, `apple-silicon`, `macos`, `llm`).
- 11 launch issues created on the repo with pre-written copy.

### Misc
- Repo description set, homepage URL set.
- Confirmed CI build + tests green on `macos-14` with full Xcode (XCTest unavailable locally with CLT-only).

## [0.1.0-beta] — 2026-05-25

First public beta of **ModelStatus**. Evolved from the private OllamaStatus experiment into a multi-provider menu bar app for local LLM servers.

### Update notifications (new in 0.1)
- Lightweight GitHub Releases poller (`UpdateChecker.swift`). Checks at most once per 24h. When a newer tag is published, fires a macOS notification — tap to open the release page. No auto-install, no Sparkle dependency. "Check for Updates…" menu item also exposes manual checks.
- Semver-aware pre-release comparison: a `v0.1.0-beta` install correctly sees `v0.1.0` stable as an update.

### Tooltips
- Every info row in the menu dropdown (📡 client process, ⚡/💤 CPU%, 💾 memory, 🕐 last active, 📊 latency, 📦 no models loaded, 📋 N models available, ⏏︎ loaded model) has a hover tooltip explaining what it shows and where the data comes from.

### Audit-pass hardening
Pre-release audit by Codex 5.5 + code-reviewer surfaced 20 findings. Addressed:
- **Provider probes** are now strict — require `models` / `data` key present, no longer match an empty `{}` JSON body as a valid backend.
- **vLLM memory parser** matches `vllm:gpu_memory_usage_bytes` specifically (was summing every line containing both "vllm" and "memory" → double-counted cache + allocator).
- **`clientIP` → `clientProcess`** rename: the menu's 📡 line actually shows the process name (e.g. "python", "Claude"), not an IP. Field renamed everywhere to match.
- **`HTTPHelpers.post`** propagates `JSONSerialization` errors instead of silently sending no body (would have caused eject/load to fail silently).
- **`HTTPHelpers.get`** pre-checks `Content-Length` header before parsing.
- **`Monitor.startPolling`** resets `lastExpiresAt` so a poll-cycle restart can't spuriously mark `.generating`.
- **`pollInterval`** clamped to `[1, 600]` with NaN/Inf guard to prevent `Task.sleep` trap.
- **`shellMetricDouble`** rejects empty keyword (was matching every process line for OpenAI-compat providers with no process binding).
- **`Discovery.currentSubnetBase`** nil-checks `ifa_addr` (was crashing on interfaces with null sockaddr).
- **IPv6 hosts** now bracketed in discovery URLs (`http://[fd7a:...]:11434`).
- **Discovery concurrency** capped at 64 simultaneous probes (was launching 1,270 unbounded).
- **`menuNeedsUpdate`** is synchronous and mutates the AppKit-passed menu in place — the stale-menu fix actually works now (was being defeated by async rebuild via `Task`).
- **`welcomeWindowRequestedSettings`** observer added — "Open Settings…" from the Welcome window was a no-op.
- **`applicationShouldTerminate`** uses the `.terminateLater` reply pattern to actually await `Monitor.stopPolling()` before quitting.
- **Lazy notification permission**: macOS prompt only fires when we first attempt to post a notification, not unconditionally at launch.
- **`UpdateChecker` throttle/lastSeen** keys are written AFTER a successful HTTP 200 + notification schedule, so transient failures don't lock out checks for 24h.
- **`isLocal`** recognizes `::1` IPv6 loopback.
- **`shellMetricDouble`** normalizes both keyword and process line to lowercase.
- **`Formatters.compactLine`** returns `""` for zero VRAM instead of `"0 MB"`.

### Renamed
- **Project**: OllamaStatus → ModelStatus
- **Bundle identifier**: `com.lucrativepictures.OllamaStatus` → `com.lucrativepictures.ModelStatus`
- **Config file**: `com.lucrativepictures.OllamaStatus.json` → `com.lucrativepictures.ModelStatus.json` (migrated automatically from both v2.x and v1.x `com.local.ollamastatus.json` paths)
- **LaunchAgent label**: matches the new bundle id

### Added
- **Multi-provider architecture** with auto-detection. New `Provider` protocol + four concrete implementations:
  - `OllamaProvider` — `/api/ps` + `/api/tags`, eject (`keep_alive: 0`), load (`keep_alive: -1`), VRAM, generating-state detection via lsof.
  - `LMStudioProvider` — `/api/v0/models`, unload via `/api/v0/models/unload`, load via `/api/v0/models/load`.
  - `VLLMProvider` — `/v1/models` + Prometheus `/metrics` for GPU memory.
  - `OpenAIProvider` — catch-all for llama.cpp, MLX, LocalAI, Text-Gen-WebUI, and any other OpenAI-compatible server.
- **Capability flags** (`canEject`, `canLoadModel`, `canListAvailable`, `reportsVRAM`, `reportsGenerating`) drive the menu — actions only appear for providers that support them.
- **Network discovery** (Settings → Discover…) scans the local /24 and Tailscale peers concurrently for known model-server ports. On-demand only.
- **Poll-interval popup** — 2s / 5s / 10s / 30s / 1m / 3m (default 5s, was 2s).
- **Compact mode toggle** — one line per server in the menu, format: `🟢 Name · model · vram` / `🟡 Name · idle` / `🔴 Name · unreachable`.
- **Kind column** in Settings — double-click to override Auto detection with a specific provider.
- **🧠 brain icon** replaces 🦙 llama in the menu bar (provider-neutral).
- **DESIGN.md** — comprehensive architecture + customization guide.
- **RELEASE-PLAN.md** — release ticket + roadmap.
- **homebrew-tap/** — Cask formula for `brew install --cask modelstatus` via `lucasmullikin/tap`.
- **`detectedKind`** field in `ServerStatus` so UI can apply provider-specific rules even when user set `kind = .auto`.
- **Response latency** captured per poll (visible in expanded menu).

### Changed
- **Default poll interval**: 2s → 5s (kinder to battery with multi-instance setups).
- **Default config**: now `[Instance(name: "Local", url: "http://127.0.0.1:11434", kind: .ollama)]` — single localhost instance only.
- **Generating dot** is shown **only for Ollama** instances. Other providers collapse `.generating` → `.active` in the indicator so the blue dot never lies.
- **Welcome panel** rewritten for multi-provider scope.
- **Settings window** layout updated: poll slider → popup, added Compact-mode + Discover button.
- **URL validator** is now exposed publicly so add/edit + discovery share validation logic.

### Removed
- `OllamaInstance.authHeader` JSON field (auth has been Keychain-only since v2.0; this strips the dead field).
- The `showURLs` config flag (was unused).

### Security
- Same hardened posture as v2.x: response size cap (4 MB), URL scheme allowlist + cloud-metadata blocklist, 0600 config perms, Keychain-stored auth headers with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

## [2.0.0] — 2026-05-25 (OllamaStatus, superseded)

First public-release prep under the OllamaStatus name. Multi-instance, Ollama-only, Keychain auth, on-demand notifications, build CI. Superseded same day by 3.0.0.

## [1.0-beta] — 2026-03-20

Initial private build. Unified menu bar app with `/api/ps`-based loaded-model detection and `lsof`-based client/CPU/memory telemetry for the local Ollama instance.
