# RELEASE-PLAN — ModelStatus v0.1.0-beta

**Project:** ModelStatus (formerly OllamaStatus, renamed 2026-05-25)
**Owner:** Lucrative Pictures LLC
**Repo:** https://github.com/lucasmullikin/ModelStatus
**Bundle ID:** com.lucrativepictures.ModelStatus
**License:** MIT
**Target:** macOS 13+
**Date:** 2026-05-25

---

## TL;DR

- **v0.1.0-beta:** Shipped 2026-05-25 — initial public release.
- **v0.2.0 (now):** Foundation hardening complete. Dedicated MLXProvider, OSLog viewer + diagnostic bundle export, salted-hash log scrubber, UpdateChecker snooze/dismiss, `@MainActor` ConfigManager, `LocalSystemAccess` abstraction for the future sandboxed App Store target, 50+ rounds of Codex 5.5 audit-fix iteration plus an architect outside-review pass.
- **Next milestones (unscheduled):** Apple Developer Program → codesign + notarize, official Homebrew Cask, optional auto-update mechanism.
- **Deferred to v0.2.1 / v0.3:** Anonymizer `ParsedAuthority` consolidation, staleness/cancellation unification, Provider.swift 4-way file split, MLX argv hoisted into `CheckRequest`.
- **Blocked:** Notarization and App Store are gated on Apple Developer enrollment. No work can proceed on those until the $99/yr account exists.

---

## v0.2 summary

**Shipped in v0.2.0:**

**Provider layer**
- `ProviderCapabilities` refactored to `OptionSet` with named presets (`.ollama`, `.lmStudio`, `.vllm`, `.openAI`, `.mlx`) — purely additive going forward.
- `CheckRequest` value type bundles all 7 per-check inputs into one Sendable struct.
- `PollContext` snapshot captures the config-era for an entire poll cycle.
- `InstanceState` consolidates per-instance memoized state (detectedKind, lastClient, lastActive, etc.) into a single struct owned by the Monitor actor.
- Dedicated `MLXProvider` with HuggingFace cache walk, scheme-aware default port (HTTPS = 443, HTTP = 8080), local-process argv verification, GGUF anti-detection gate.
- All 5 providers use path-preserving `endpoint(base:suffix:)` so reverse-proxied bases (`https://host/proxy/openai`) work correctly.
- OpenAIProvider's `modelsEndpoint(base:)` is idempotent for `/v1` and `/v1/models` suffixes.

**Concurrency model**
- `ConfigManager` migrated to `@MainActor` singleton; `nonisolated static` accessors for read-only metadata.
- Monitor's `pollGeneration` counter bumps on every config change; per-check generation re-checks before any state mutation; post-MainActor-hop re-check via `dispatchCallbacks` closes the cross-actor stale-callback window.
- `GenerationGuardedCache<Identifier, Value>` extracted from open-coded AppDelegate cache pattern; per-key fetch tokens prevent late-commit races after `finishFetch`.
- `runShell` rebuilt: streaming 4 MB cap, two-stage SIGTERM/SIGKILL escalation, dedicated cap-exceeded SIGKILL at +500 ms, single-fire continuation latch, idempotent handler detach under sync queue.

**Security & privacy**
- `URLValidator` canonicalization (octal/hex/decimal/shortened IPv4 + compressed IPv6 + host:port shorthand). 169.254/16, 100.64/10, RFC 1918, IPv6 ULA/site-local all blocked.
- HTTP transport: scheme allowlist, no-redirect session delegate, 4 MB streaming response cap, DNS-rebinding resolution guard via `getaddrinfo` pre-resolve.
- `Anonymizer` rebuilt: salted SHA-256 (salt in Keychain, `AfterFirstUnlockThisDeviceOnly`), `URLComponents`-based scrubber, regex fallback for malformed URLs with credential-straddling defense (handles credentials containing `/?#`), IPv6 zone + bracketed-host idempotency, query/fragment boundary so `?email=a@b` doesn't get over-anonymized.
- `Keychain` writes include accessibility on update (older items upgrade); `errSecDuplicateItem` race handled.
- `DiagnosticBundle` writes to a private 0700 staging dir, rejects symlink destinations via `destinationOfSymbolicLink` (handles dangling), `replaceItemAt` with `.usingNewMetadataOnly` + post-replace chmod 0600.
- Tailscale binary identity verified via `SecRequirementCreateWithString` against Team ID `W5364U7YZB` before exec.
- LogViewer's OSLog ring buffer drops `removeFirst()` overhead; cancellation checks every 50 entries.

**App Store readiness**
- `LocalSystemAccess` protocol abstracts `lsof`/`ps`/`pgrep`/shell — wired through Monitor's poll inner loop (cpu/mem/clientProcess), `toggleLocalOllama`, `isLocalOllamaRunning`, and Discovery's Tailscale scan.
- `MODELSTATUS_APP_STORE` compile flag selects `SandboxedLocalSystemAccess` as the fail-closed default; `configure(_:)` runtime injection is also supported for testing.
- DEBUG-assert + OSLog-fault paths scoped to the App Store target only — direct-download builds don't trip.

**UX / UI**
- OSLog viewer window with per-category filter (`provider.*` `BEGINSWITH` match) and progressive log-fallback windows (5min/1min/15s/1s).
- Diagnostic bundle export menu item with parent-window-or-modeless fallback for menu-bar-only state.
- UpdateChecker: snooze (7-day), dismiss-tag list (capped at 16), App Store install detection short-circuits both `check()` and `cachedAvailableUpdate()`.
- Settings hint UI for capabilities the UI gates on (`canEject`, `canLoadModel`, `reportsVRAM`, `reportsGenerating`).
- Notification-tap delegate uses `nonisolated static` `isSafeOpenURL` with an exact-host allowlist (github.com / apps.apple.com / objects.githubusercontent.com / support.apple.com).

**Release infrastructure**
- `SECURITY.md` published (vulnerability disclosure at `lucas@lucrativepictures.com`, 30-day window).
- `.github/workflows/{build,release}.yml` pinned to commit SHAs (no floating `@v4`-style tags).
- `scripts/release.sh` rejects secret-shaped files pre-push and validates the Homebrew tap download URL trust boundary.

**Process**
- 50+ Codex 5.5 audit-fix iteration rounds (45 standard + 4 hard-mode with `REASONING_EFFORT=high`).
- 1 outside-perspective architect review identifying 5 architectural smells (1 fixed: `LocalSystemAccess` actually wired through call sites; 4 deferred to post-v0.2 tickets).
- 41/41 tests passing throughout.
- Build clean at every commit.

---

## Tonight's checklist (v0.1.0-beta launch)

Complete steps in order. Do not skip ahead.

- [ ] Verify `swift build` succeeds (clean — no errors, no warnings treated as errors)
- [ ] Verify `./scripts/build-app.sh` produces `build/ModelStatus.app` (check file exists and is a valid app bundle)
- [ ] Rename parent directory: `mv ~/projects/OllamaStatus ~/projects/ModelStatus` (deferred until end of v0.1.0-beta work — do this as the final local step before or after push)
- [ ] `git add -A && git commit -m "feat!: v0.1.0-beta — multi-provider rename OllamaStatus→ModelStatus, Ollama + LM Studio + vLLM + OpenAI-compat, network discovery, capability-flag UX"`
- [ ] `git remote add origin https://github.com/lucasmullikin/ModelStatus.git` (if remote not set; if set use `git remote set-url origin https://github.com/lucasmullikin/ModelStatus.git`)
- [ ] `git push -u origin main`
- [ ] `git tag v0.1.0-beta && git push origin v0.1.0-beta` — this triggers the Release GitHub Action which builds the .zip, computes sha256, and attaches both to the GH Release
- [ ] Verify the `Release` GitHub Action ran green: `gh run list --repo lucasmullikin/ModelStatus --limit 5` and confirm the tag-triggered workflow shows `completed / success`
- [ ] Verify `.zip` and `.sha256` are attached to the release: `gh release view v0.1.0-beta --repo lucasmullikin/ModelStatus`
- [ ] (Optional tonight) Manually edit Release notes on GitHub to highlight key v0.1.0-beta features for visitors landing on the releases page
- [ ] (Optional tonight) Create `lucasmullikin/homebrew-tap` repo, push contents of `homebrew-tap/` subdirectory into it (enables `brew install --cask lucasmullikin/tap/modelstatus`)
- [ ] After `.zip` is confirmed uploaded, compute real sha256: `shasum -a 256 build/ModelStatus-v0.1.0-beta.zip` — update `homebrew-tap/Casks/modelstatus.rb` replacing `:no_check` with the real digest, commit, push
- [ ] (Post-launch, optional) Replace v1.0 install: `pkill OllamaStatus; cp -R build/ModelStatus.app /Applications/; open /Applications/ModelStatus.app`

---

## What's IN v0.1.0-beta

All of the following shipped in this release and are present in the binary and source tree:

- **Multi-provider abstraction** — unified `Provider` protocol with concrete implementations for Ollama, LM Studio, vLLM, and any generic OpenAI-compatible endpoint
- **Auto-detect provider on first poll** — app fingerprints the running server by probing well-known paths; user does not need to select a provider manually
- **Capability-flag-driven UI** — eject, load, VRAM, and other controls are shown or hidden based on what the detected provider actually supports; no dead buttons
- **VRAM bar** — displays live VRAM usage for Ollama (via `/api/ps`) and vLLM (via `/metrics` Prometheus scrape)
- **Load-model submenu** — pull and load a model by name via menu, supported on Ollama and LM Studio
- **Authorization headers via Keychain** — bearer token stored in macOS Keychain; never written to config file in plaintext
- **Reachability notifications** — opt-in system notification when a configured server goes offline or comes back online (UNUserNotificationCenter)
- **Network discovery** — Settings → Discover… scans the local /24 subnet and known Tailscale peer addresses for running LLM servers; on-demand only, never automatic
- **Compact mode toggle** — condensed menu layout for users with many instances configured
- **Welcome panel with status legend** — shown on first launch; explains icons and status colors
- **Brain 🧠 menu bar icon** — replaces the generic Ollama llama icon; consistent with the ModelStatus brand
- **Poll intervals: 2s / 5s / 10s / 30s / 1m / 3m** — default 5s; configurable per-app (per-instance overrides deferred)
- **URL validation** — scheme validation (http/https only) plus a cloud-metadata blocklist (169.254.169.254 and equivalents) to prevent SSRF-class misconfigs
- **4 MB response cap** — hard ceiling on provider API responses to prevent memory pressure from runaway servers
- **0600 config file permissions** — config written with owner-only perms; checked on load
- **`os.Logger` instrumentation** — structured logging throughout; visible in Console.app with subsystem `com.lucrativepictures.ModelStatus`
- **MIT LICENSE, README, CHANGELOG, CONTRIBUTING, DESIGN.md** — full documentation set in repo root
- **GitHub Actions** — CI build on push/PR (build + test) + release workflow triggered by `v*` tag (builds app, zips, computes sha256, attaches to GH Release)
- **XCTest scaffold** — tests for URLValidator, Formatters, and ConfigManager; not 80% coverage yet, scaffold is the baseline for future expansion
- **Homebrew Cask formula** — `homebrew-tap/Casks/modelstatus.rb` ready to push to own tap; sha256 is `:no_check` until release zip is live

---

## What's NOT in v0.1.0-beta (deferred)

| Feature | Reason deferred | Target |
|---|---|---|
| Notarized binary | Apple Developer Program not purchased yet; Gatekeeper quarantine workaround required for unsigned builds | next milestone |
| Mac App Store submission | Sandbox entitlements forbid `ps`, `lsof`, and raw socket scans needed by discovery and process detection | later (sandboxed degraded build) |
| Dedicated MLXProvider | `mlx_lm.server` exposes process args and log files, not a stable REST API; needs spec research and a log-file watcher | v0.2 (in progress) |
| Auto-updater (Sparkle or alternative) | Not worth the bundle complexity before notarization is in place | next milestone |
| Per-instance poll-interval overrides | Config schema design needed; app-wide interval is sufficient for now | later |
| Mass eject ("eject all loaded models") | Too easy to fire by accident; no undo; rejected after design review | Rejected — not planned |
| Config export/import UI | Users can hand-edit JSON; no urgency | later |
| Cloud APIs (OpenAI, Anthropic, Google) | ModelStatus is explicitly local-host focused; cloud APIs are out of scope by design | Never |
| Linux/Windows builds | SwiftUI/AppKit is macOS-only; a cross-platform version requires a full rewrite decision | eventually |
| Sandboxed Mac App Store version | Depends on resolving the ps/lsof/socket sandbox conflicts; requires sustained engineering effort | later |

---

## Roadmap

Specific version labels and dates aren't promised — what's listed below is the **order**, not a calendar. Scope and ordering may shift based on what real-world usage surfaces.

### In flight — v0.2

- [x] OptionSet `ProviderCapabilities` refactor (C1)
- [x] PollContext snapshot for actor boundary (C2)
- [x] Consolidated `InstanceState` (C3)
- [x] `@MainActor` ConfigManager + concurrency tests (B-1, B-2)
- [x] Hardened `runShell` with two-stage SIGTERM/SIGKILL + single-fire latch (D-revised)
- [ ] Dedicated MLXProvider — capability-flagged read-only telemetry; port-tied process detection
- [ ] OSLog viewer window + diagnostic bundle export (with anonymizer + sanitized URLs)
- [ ] UpdateChecker snooze / dismiss / Homebrew-aware upgrade hints
- [ ] Salted-hash anonymizer with salt in Keychain (security audit blocker)
- [ ] Bundle-wide URL redaction (sanitizeURL strips query params too)
- [ ] Final re-audit pass before tag

### Next milestone — packaging + signing

- [ ] Enroll in Apple Developer Program ($99/yr) — prerequisite for everything below
- [ ] Codesign the app bundle with Developer ID Application certificate
- [ ] Notarize via `notarytool` — eliminates `xattr -dr com.apple.quarantine` workaround for users
- [ ] Submit ModelStatus to official `homebrew/cask` tap (requires notarized binary; enables `brew install --cask modelstatus` with no custom tap)
- [ ] Auto-update mechanism (Sparkle or in-house) — point at GitHub Releases appcast; codesign the update package
- [ ] Per-instance poll-interval overrides — extend config schema, update Settings UI
- [ ] Discovery: add mDNS / Bonjour browse alongside port scan (passive, no packet injection)
- [ ] Latency-history sparkline in menu — rolling 60-sample buffer, rendered as NSImage

### Later — App Store + sync

- [ ] App Store TestFlight beta — sandboxed build with degraded telemetry (no process inspection, no raw scan); test with external beta users
- [ ] iCloud Drive sync of config (opt-in) — sync `instances` array only, never Keychain credentials
- [ ] Expand XCTest coverage toward 80% across all providers and discovery logic
- [ ] Sandboxed Mac App Store release (paid, suggested $4.99–$9.99 one-time); App Store funding sustains development; source-build path stays MIT/free

### Eventually

- [ ] Linux and/or Windows builds — decision gated on App Store revenue signal; likely a separate native implementation (GTK on Linux, Win32 or WinUI on Windows) rather than a Swift port
- [ ] Web companion view — `localhost:NNNN` serving the same model-status dashboard; useful when menu bar is hidden in fullscreen or on secondary displays
- [ ] Opt-in crash reporting — stack traces only, no analytics, reported to GitHub Releases issue tracker or a self-hosted endpoint; explicit user consent required

---

## Business model

- **GitHub source (MIT):** Free, build-from-source, always will be. No restrictions.
- **GitHub Releases unsigned binary:** Free. Tonight = this tier. Users run `xattr -dr com.apple.quarantine` once. No account required.
- **Homebrew Cask (own tap tonight, official cask later):** Free. Slightly smoother install. Still unsigned until notarization lands.
- **Mac App Store (future):** Paid one-time purchase (target $4.99–$9.99). Sandboxed, automatic updates, no Gatekeeper dialogs. Revenue funds ongoing development and the Developer Program fee. Source-builders remain free forever.
- **No subscriptions. No SaaS backend. No analytics. No cloud dependencies. No telemetry.**

---

## Risk register

- **macOS API churn (NSStatusItem, NSMenu, UNUserNotificationCenter across macOS 13–26)** — mitigated by conservative AppKit usage, no SwiftUI menu extras, tested against macOS 13 SDK minimum
- **Provider API churn (Ollama / LM Studio / vLLM breaking changes)** — mitigated by capability-flag fallback: unknown endpoints degrade gracefully to read-only mode; provider tests catch regressions
- **Discovery scan triggers user firewalls or IDS** — mitigated by on-demand only (user must tap Discover…), never runs automatically, documented prominently in README
- **Keychain prompts at runtime after app move** — expected macOS behavior when bundle path changes; document the `xattr` and first-launch Keychain prompt in README; not a bug
- **LaunchAgent silent failure if installed outside /Applications** — README warns that the optional LaunchAgent plist assumes `/Applications/ModelStatus.app`; users installing elsewhere must edit the plist manually
- **MIT liability exposure** — standard MIT disclaimer in LICENSE covers Lucrative Pictures LLC; no warranty, no liability. Documented.

---

## Marketing / launch (tonight is OPTIONAL)

These steps are deferrable. Do not block the tag push on them.

- [ ] Twitter/X post: _"Just shipped ModelStatus v0.1.0-beta — monitor any local LLM server from your menu bar. Ollama, LM Studio, vLLM, MLX, llama.cpp. Free, MIT, no telemetry. https://github.com/lucasmullikin/ModelStatus"_
- [ ] Hacker News Show HN — defer until polish, screenshots, and a demo GIF are ready; a bare-source drop without visuals underperforms on HN
- [ ] Reddit r/LocalLLaMA — strong audience for this tool; needs at minimum one real-world demo GIF and a screenshot of the menu bar in action before posting
- [ ] Add `menu-bar-app`, `ollama`, `lm-studio`, `local-llm` GitHub topics to the repo — these are indexed by GitHub Topics and surface the project automatically; add in repo Settings → Topics

---

## Verification checklist post-push

Run these after the tag is live and the Release Action completes:

- [ ] `gh repo view lucasmullikin/ModelStatus` — confirms repo is public and description is set
- [ ] `gh release view v0.1.0-beta --repo lucasmullikin/ModelStatus` — confirms release exists, shows .zip and .sha256 as attached assets
- [ ] `curl -L -o /tmp/test.zip https://github.com/lucasmullikin/ModelStatus/releases/download/v0.1.0-beta/ModelStatus-v0.1.0-beta.zip && unzip -t /tmp/test.zip` — exits 0, confirms zip is not corrupt
- [ ] Fresh install test: download zip, unzip, `xattr -dr com.apple.quarantine ModelStatus.app`, double-click → 🧠 appears in menu bar, clicking it shows the status menu without crash
- [ ] Confirm sha256 in `homebrew-tap/Casks/modelstatus.rb` matches `shasum -a 256` output of the released zip (if tap was pushed tonight)

---

## Owner

**Lucrative Pictures LLC**
Operator contact: lucas@lucrativepictures.com (do not embed in source code or build artifacts).

---

## Definition of done — v0.1.0-beta

v0.1.0-beta is complete when: the `v0.1.0-beta` tag is pushed to `https://github.com/lucasmullikin/ModelStatus`, the Release GitHub Action completes green, the `.zip` and `.sha256` artifacts are attached to the GitHub Release, and a fresh download of that zip installs and launches correctly on macOS 13+ (unsigned, with the standard `xattr -dr com.apple.quarantine` workaround). All items marked required in Tonight's checklist are checked. Optional items (Release notes edit, Homebrew tap push) may remain open and be completed within 24 hours without blocking the v0.1.0-beta designation.
