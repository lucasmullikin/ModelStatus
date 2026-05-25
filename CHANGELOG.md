# Changelog

All notable changes to ModelStatus (and its predecessor OllamaStatus).

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [3.0.0] — 2026-05-25

**ModelStatus** debuts. Renamed from OllamaStatus and refactored into a multi-provider menu bar app for local LLM servers.

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
