# Contributing to ModelStatus

## Quick start

```bash
git clone https://github.com/lucasmullikin/ModelStatus.git
cd ModelStatus
swift build                     # compile
./scripts/build-app.sh          # assemble .app in build/
open build/ModelStatus.app
```

## Running tests locally

XCTest requires the full Xcode install (not just Command Line Tools), because XCTest ships with Xcode's bundled Swift toolchain rather than the standalone CLT toolchain.

- **With Xcode installed**: `swift test`
- **Without Xcode**: `swift build` works fine. Tests run in CI on every push.

## Code style

- Two-space indent, no trailing whitespace, no `print()` — use `os.Logger`.
- `@MainActor` everything that touches AppKit.
- New shell-exec must use the async `LocalProbe.runShell` helper, never blocking calls on Swift Concurrency cooperative threads.
- Auth secrets always through `Keychain`. Never `UserDefaults` or the JSON config.
- Network requests must go through `HTTPHelpers.get` / `.post` for the 4 MB cap + auth header injection.
- New providers: subclass `Provider`, register in `ProviderRegistry.all` (probe order matters — more specific before generic), add a `ProviderKind` case.

## Submitting changes

1. Fork + branch from `main`.
2. Add a `CHANGELOG.md` entry under `[Unreleased]`.
3. Update tests when you touch validation, formatting, or config-shape code.
4. Open a PR; CI will build and test.

## Project layout

```
ModelStatus/
├── ModelStatus/                  Swift sources
│   ├── AppDelegate.swift           @MainActor, menu/lifecycle
│   ├── Monitor.swift               actor — poll loop, provider dispatch
│   ├── Provider.swift              protocol, capabilities, HTTPHelpers, LocalProbe
│   ├── OllamaProvider.swift        /api/ps + /api/tags + eject/load
│   ├── LMStudioProvider.swift      /api/v0/models + unload/load
│   ├── VLLMProvider.swift          /v1/models + /metrics
│   ├── OpenAIProvider.swift        /v1/models catch-all
│   ├── Discovery.swift             LAN /24 + Tailscale scanner
│   ├── ConfigManager.swift         JSON config, migration, URLValidator
│   ├── Keychain.swift              SecItem wrapper for auth headers
│   ├── SettingsWindow.swift        Settings UI
│   ├── StatusIndicator.swift       NSStatusItem
│   ├── WelcomeWindow.swift         First-launch panel
│   ├── Formatters.swift            bytes / elapsed / bar / compact line
│   ├── Info.plist
│   └── ModelStatus.entitlements
├── Tests/ModelStatusTests/       XCTest suites
├── LaunchAgent/
│   └── com.lucasmullikin.ModelStatus.plist
├── homebrew-tap/                 Homebrew Cask formula + tap README
├── scripts/build-app.sh          SwiftPM build → .app bundle
├── .github/workflows/            build.yml (CI) + release.yml (tag → Release)
├── DESIGN.md                     Architecture deep-dive
├── RELEASE-PLAN.md               Release ticket + roadmap
├── Package.swift
└── README.md
```

## Adding a new provider

1. **Create** `ModelStatus/MyProvider.swift` conforming to `Provider`:
   - `kind: ProviderKind` (add a new case to the enum)
   - `capabilities: ProviderCapabilities` (which features your backend supports)
   - `probe(_:session:)` — return `true` if your backend's distinguishing endpoint responds
   - `check(_:session:isLocal:localCPU:localMemMB:localClientIP:lastActive:)` — full status fetch
   - Optionally override `ejectModel`, `loadModel`, `availableModels`
2. **Register** in `Provider.swift` `ProviderRegistry.all` (probe order matters — more specific before generic).
3. **Add** a case to `ProviderKind` and its `displayName`.
4. **Update** `Discovery.probeMatrix` if your backend listens on a specific default port.
5. **Add tests** under `Tests/ModelStatusTests/`.

See `LMStudioProvider.swift` for a clean reference implementation.

## Releasing

See `RELEASE-PLAN.md` for the full process. Short version:

1. Bump `CFBundleShortVersionString` in both `Info.plist` files.
2. Update `CHANGELOG.md`.
3. `git tag v3.x.y && git push origin v3.x.y` — the `release.yml` workflow builds, zips, and attaches to a GitHub Release automatically.

## Code of conduct

Be kind. Assume good faith. If you wouldn't say it to someone in person, don't write it in a PR review.
