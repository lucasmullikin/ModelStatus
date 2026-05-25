# ModelStatus — Design Document

## 1. Overview

ModelStatus is a macOS menu bar application that continuously polls one or more local-network and remote model-serving processes (Ollama, LM Studio, vLLM, and anything that speaks the OpenAI-compatible `/v1/models` API) and displays their combined state as colored dot indicators beside a 🧠 icon in the system status bar. Each click opens a menu with per-instance details: loaded models, VRAM usage, CPU/memory (local processes only), response latency, last-active time, and a connected-client IP when running on loopback. The app is built on four explicit design pillars:

**Clean** — the entire codebase fits in fourteen focused Swift files; there are no third-party dependencies, no Storyboards, no Xcode project file, and the object graph is shallow enough to hold in working memory. **Small** — the compiled app binary is under 1 MB; it carries no embedded model data, no frameworks, no resources beyond Info.plist. **Secure** — auth tokens live only in the macOS Keychain, the config file is written mode 0600 with `completeFileProtection`, URL input is validated against a scheme allowlist and a cloud-metadata-host blocklist, and response payloads are capped at 4 MB before any JSON parsing begins. **Lightweight** — the process runs as a `.accessory` activation policy (no Dock icon, no window server participation at idle), all I/O is async/await on Swift Concurrency cooperative threads or a single utility DispatchQueue for shell process I/O, and the URLSession is ephemeral (no disk cache).

---

## 2. Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  macOS Status Bar                                               │
│                                                                 │
│  ┌──────────────────┐                                          │
│  │  StatusIndicator  │  ← NSStatusItem + attributed title     │
│  │  (🧠 ● ● ○ ✗)    │    rebuildMenu() on every poll         │
│  └────────┬─────────┘                                          │
│           │ updateStatuses([ServerStatus])                      │
│  ┌────────▼─────────────────────────────────────────────────┐  │
│  │              AppDelegate  (@MainActor)                    │  │
│  │  startMonitoring()  rebuildMenu()  ejectModel/loadModel   │  │
│  └────────┬─────────────────────────────────────────────────┘  │
│           │ startPolling(onStatusChange:onReachabilityChange:)  │
│  ┌────────▼──────────────────────────────────────────────────┐ │
│  │              Monitor  (actor)                              │ │
│  │  detectedKinds[UUID: ProviderKind]                        │ │
│  │  lastActiveTime / lastClientIP / lastReachability         │ │
│  │  URLSession (ephemeral, 8s request timeout)               │ │
│  │                                                            │ │
│  │  withTaskGroup → check(Instance) × N in parallel          │ │
│  │       │                                                    │ │
│  │       ├──▶ OllamaProvider   /api/ps + /api/tags            │ │
│  │       ├──▶ LMStudioProvider /api/v0/models                 │ │
│  │       ├──▶ VLLMProvider     /v1/models + /metrics          │ │
│  │       └──▶ OpenAIProvider   /v1/models  (catch-all)        │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
│  Sidecar — not on the poll hot-path:                           │
│  ┌────────────────┐  ┌───────────┐  ┌──────────────────────┐  │
│  │ ConfigManager  │  │  Keychain │  │  Discovery           │  │
│  │ (singleton)    │  │ (enum ns) │  │  (on-demand only)    │  │
│  │ JSON 0600 file │  │ per-UUID  │  │  LAN /24 + Tailscale │  │
│  └────────────────┘  └───────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

All poll-path types conform to `Sendable`. `Monitor` is a Swift actor; `AppDelegate` is `@MainActor`. Cross-boundary communication uses `Task { @MainActor in … }` blocks — no explicit locks anywhere in the codebase.

---

## 3. The Provider Abstraction

**`Provider` protocol** (`Provider.swift:56`):

```swift
protocol Provider: Sendable {
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }
    func probe(_ instance: Instance, session: URLSession) async -> Bool
    func check(_ instance: Instance, session: URLSession, isLocal: Bool,
               localCPU: Double?, localMemMB: Int?, localClientIP: String?,
               lastActive: Date?) async -> ServerStatus
    func ejectModel(_ name: String, on instance: Instance, session: URLSession) async
    func loadModel(_ name: String, on instance: Instance, session: URLSession) async
    func availableModels(_ instance: Instance, session: URLSession) async -> [String]
}
```

`ejectModel` and `loadModel` have no-op default implementations in the protocol extension (`Provider.swift:68-71`), so providers that don't support those operations don't need to implement them.

**`ProviderKind` enum** (`ConfigManager.swift:3`): `.auto`, `.ollama`, `.openAI`, `.lmStudio`, `.vllm`. Raw value is `String` for JSON persistence. `displayName` is the only UI concern the enum carries.

**`ProviderCapabilities`** (`Provider.swift:30`): Five boolean flags, with a pre-built static constant per provider:

| Capability | Ollama | LM Studio | vLLM | OpenAI-compat |
|---|---|---|---|---|
| `canEject` | true | true | false | false |
| `canLoadModel` | true | true | false | false |
| `canListAvailable` | true | true | true | true |
| `reportsVRAM` | true | false | true | false |
| `reportsGenerating` | true | false | false | false |

The UI gates menu actions exclusively on these flags. `AppDelegate.rebuildMenu()` reads `capabilitiesByInstance[id]`, which is populated lazily on first menu open via `Monitor.capabilities(for:)`. If capabilities have not yet been fetched for an instance, the menu falls back to `ProviderCapabilities.openAI` (the most-restrictive set), which is safe: it will just omit eject/load options until the next menu open.

**`ProviderRegistry`** (`Provider.swift:74`): A static `all: [Provider]` array in probe priority order — Ollama, LMStudio, VLLM, OpenAI. Auto-detect iterates this list and returns on first `probe` success. Order matters: LM Studio's `/api/v0/models` endpoint is checked before falling through to the generic `/v1/models` check, so an LM Studio instance is never mis-classified as generic OpenAI-compat.

---

## 4. Polling Lifecycle

`Monitor.startPolling` (`Monitor.swift:29`) resets all memo dictionaries and cancels any prior `pollTask`, then spawns a new `Task` that calls `poll()` in a tight loop with `Task.sleep` for the configured interval. `poll()` reads `ConfigManager.shared.instances` fresh on every iteration — config changes take effect within one poll cycle without requiring a restart.

`poll()` uses `withTaskGroup` to fan out a `check(Instance)` call for every configured instance in parallel. Results arrive in non-deterministic order; they are re-sorted by the original `instances` array order before invoking the `onStatusChange` callback.

`check(Instance)` (`Monitor.swift:77`) first calls `resolveProvider(for:)`:

1. If `instance.kind != .auto`, return the matching concrete provider immediately.
2. If `.auto` and `detectedKinds[instance.id]` is set (from a prior successful probe), return that provider without re-probing. This is the fast path for every poll after the first.
3. If `.auto` and no cached detection, run `ProviderRegistry.detect(instance, session:)` — a sequential probe across the four providers with a 3-second timeout each (`Provider.swift:25`, `25`, `13`). Store the result in `detectedKinds`. On complete failure, fall through to `OpenAIProvider` so the status is reported as `.unreachable` cleanly rather than crashing.

After provider resolution, three local-telemetry async calls are launched concurrently (`Monitor.swift:82-84`) using `async let`: `LocalProbe.cpuFor`, `LocalProbe.memoryMBFor`, and `LocalProbe.clientIP`. These only fire when `LocalProbe.isLocal(instance.url)` is true (host = `127.0.0.1`, `localhost`, or `0.0.0.0`). On remote instances all three return `nil` immediately.

Re-detection is triggered by removing `detectedKinds[instance.id]`. Currently the only trigger is `Monitor.startPolling` resetting all memo state, which happens when `AppDelegate.openSettings` saves a config change (`AppDelegate.swift:248`). There is no periodic re-probe of already-resolved instances — if a server binary is replaced mid-session and the API changes (unlikely but possible), the user can trigger re-detection by toggling the kind in Settings.

---

## 5. Local-Process Telemetry

`LocalProbe` (`Provider.swift:137`) is a caseless enum used purely as a namespace. It provides five async functions:

- `cpuFor(processKeyword:)` — runs `/bin/ps -eo pcpu,comm`, sums all rows whose `comm` column contains the keyword. Returns `Double?` (aggregate CPU %).
- `memoryMBFor(processKeyword:)` — same with `rss` column, converts KB to MB.
- `clientIP(port:excludeKeywords:)` — runs `/usr/sbin/lsof -i :<port> -n -P`, scans output for `ESTABLISHED` lines that contain `->` and the port number, skips lines beginning with `OllamaSta` or `ModelStat` (the monitor's own connections), returns the first matching process name.
- `establishedConnectionPresent(port:excludingPids:)` — runs `lsof -i TCP:<port> -s TCP:ESTABLISHED -t`, parses PIDs, subtracts the known server PIDs and the monitor's own PID, returns true if any remain. This is how Ollama's `.generating` state is determined (`OllamaProvider.swift:59-62`).
- `pidsFor(processName:)` — `/usr/bin/pgrep -x <name>`, returns `Set<Int>`.

All five delegate to `runShell` (`Provider.swift:189`). The implementation bridges between Swift Concurrency's cooperative thread pool and Unix process I/O using `withCheckedContinuation`. The `Process` object and `Pipe` are created on a global `.utility` DispatchQueue, not on a cooperative thread, because:

- `proc.waitUntilExit()` blocks the calling thread. Blocking a cooperative thread degrades Swift Concurrency's thread pool efficiency.
- `Pipe.fileHandleForReading.readDataToEndOfFile()` also blocks.
- Using `DispatchQueue.global(qos: .utility)` isolates this blocking work to a thread the runtime can preempt without starving the cooperative pool.

A `DispatchWorkItem` killer is armed immediately after `proc.run()` with a 5-second deadline (`Provider.swift:204-207`). If the process exceeds the deadline it is sent `SIGTERM` and the continuation resumes with `nil`.

---

## 6. HTTP Layer

`HTTPHelpers` (`Provider.swift:102`) provides two static async functions used by all four providers:

**`get`** (`Provider.swift:105`): Builds a `URLRequest`, injects `Authorization: <value>` from `Keychain.authHeader(for: instanceID)` when present, fires `session.data(for:)`, captures wall-clock latency in milliseconds, enforces the 4 MB response cap (`maxResponseBytes = 4 * 1024 * 1024`, line 103), and returns `(Data, HTTPURLResponse, Int)` where the `Int` is latency. The `URLSession` used for all poll-path requests is created inside `Monitor` (`Monitor.swift:21`) with `URLSessionConfiguration.ephemeral`, `timeoutIntervalForRequest = 8`, `timeoutIntervalForResource = 10`, and `waitsForConnectivity = false`. For probe calls (3-second timeout) and load-model calls (30-60 second timeout), callers pass an explicit `timeout:` override.

**`post`** (`Provider.swift:121`): Same auth injection, sets `Content-Type: application/json`, serializes the body dict with `JSONSerialization`, and returns only `HTTPURLResponse`. Used for eject/load operations, where the response body is not needed.

The response size cap is a defense against a misbehaving server returning an arbitrarily large body. It throws `URLError(.dataLengthExceedsMaximum)` before any JSON deserialization occurs. At 4 MB the cap is far above any realistic model-list response (a server with thousands of models would still be well under 1 MB).

---

## 7. State Machine

`ServerState` (`Provider.swift:3`) has four cases: `.generating`, `.active`, `.idle`, `.unreachable`.

Transition logic per provider:

- **Ollama**: `.unreachable` when `/api/ps` fails or returns non-200. `.idle` when `ps.models` is empty. `.active` when models are loaded and `LocalProbe.establishedConnectionPresent` returns false. `.generating` when models are loaded and `establishedConnectionPresent` returns true. Note: `.generating` is only reported for local Ollama instances (the established-connection check requires lsof).
- **LM Studio**: `.unreachable` on failure. `.idle` when no models have `state == "loaded"`. `.active` when at least one model is loaded. Never `.generating`.
- **vLLM**: `.unreachable` on failure. `.idle` when `/v1/models` returns an empty list. `.active` when models are present. Never `.generating`.
- **OpenAI-compat**: Same idle/active logic as vLLM, except local instances also run `LocalProbe.establishedConnectionPresent` and can report `.generating` — though this is collapsed by the UI (see below).

**Honesty rule** — enforced identically in two places:

`StatusIndicator.iconAndColor(for:)` (`StatusIndicator.swift:43`):
```swift
let effective: ServerState = (s.detectedKind == .ollama) ? s.state :
    (s.state == .generating ? .active : s.state)
```

`AppDelegate.statusInfo(_:)` (`AppDelegate.swift:290`):
```swift
let effective: ServerState = (s.detectedKind == .ollama) ? s.state :
    (s.state == .generating ? .active : s.state)
```

For non-Ollama providers, `.generating` is silently promoted to `.active` before rendering. This prevents the blue dot from appearing for providers that can't definitively distinguish inference-in-flight from a background keep-alive connection. Both sites must be kept in sync if this rule changes.

---

## 8. Discovery

`Discovery.scan()` (`Discovery.swift:38`) is the entry point. It fans out two async sub-scans in parallel with `async let` and deduplicates results by `"host:port"` key before returning.

**LAN /24 scan** (`Discovery.swift:50`): Calls `currentSubnetBase()`, which iterates `getifaddrs` looking for the first non-loopback `AF_INET` address on an interface whose name starts with `en` (en0, en1). It extracts the first three octets to produce a subnet base like `"192.168.1"`. Then it generates 254 host addresses (`.1` through `.254`) and feeds them to `probeHosts`.

**Tailscale scan** (`Discovery.swift:94`): Checks for `/Applications/Tailscale.app/Contents/MacOS/Tailscale`. If present, runs `tailscale status --json` via `LocalProbe.runShell`, parses the `Peer` dictionary for entries where `Online == true`, collects their first `TailscaleIPs` entry, and feeds those IPs to `probeHosts`.

**`probeHosts`** (`Discovery.swift:115`): Creates a dedicated ephemeral `URLSession` with `timeoutIntervalForRequest = 1.5` (the `timeoutPerProbe` argument) and launches a `withTaskGroup` with `hosts.count × probeMatrix.count` concurrent tasks — 254 × 5 = 1,270 tasks for a full LAN scan. Each task calls `singleProbe`, which does a plain GET to `http://<host>:<port><path>` (path is `/api/tags` for Ollama kind, `/v1/models` for all others) and returns a `DiscoveredServer` on HTTP 200 or nil.

`probeMatrix` (`Discovery.swift:30`) covers ports 11434 (Ollama), 1234 (LM Studio), 8080 (OpenAI/generic), 8000 (vLLM), and 5001 (text-generation-webui).

Discovery is never invoked automatically. It is triggered only by the "Discover…" button in `SettingsWindowController` (`SettingsWindow.swift:285`), which presents a spinning progress sheet, calls `await Discovery.scan()`, then shows results in a checkbox list for the user to selectively add.

---

## 9. Storage

**Config file**: `~/Library/Preferences/com.lucrativepictures.ModelStatus.json`. Written atomically with `Data.write(to:options:[.atomic,.completeFileProtection])` and then `setAttributes([.posixPermissions: 0o600])` (`ConfigManager.swift:161-166`). `completeFileProtection` encrypts the file using the device passcode key when the device is locked — on macOS this is effectively full-disk encryption, but the flag is set for parity with iOS secure storage conventions.

The file contains `AppConfig`: an `instances` array of `Instance` records (id, name, url, kind), `pollInterval`, `notifyOnStateChange`, and `compactMode`. Auth headers are **not** in the file.

**Legacy migration** (`ConfigManager.swift:147`): On first init, `loadWithMigration` tries the current config URL first. On failure it tries `com.lucrativepictures.OllamaStatus.json` (previous bundle ID during the rename from "OllamaStatus" to "ModelStatus"), then `com.local.ollamastatus.json` (even earlier). On success the migrated config is immediately re-saved under the current bundle identifier. The legacy file is not deleted; the user can remove it manually.

**`AppConfig` defaults** (`ConfigManager.swift:51`): One instance named "Local" pointing to `http://127.0.0.1:11434` with kind `.ollama`, 5-second poll interval, notifications off, compact mode off.

**`PollInterval` enum** (`ConfigManager.swift:78`): `.fast` (2s), `.normal` (5s), `.slow` (10s), `.lazy` (30s), `.idle` (60s), `.sleepy` (180s). `PollInterval.closest(to:)` finds the nearest enum case to an arbitrary `TimeInterval`, used when loading a config that was saved with a value not matching any case.

**Keychain**: Service identifier `"com.lucrativepictures.ModelStatus.auth"`, account = `instance.id.uuidString`. Accessibility attribute `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`Keychain.swift:36`): the auth header is readable after the first unlock post-boot, but is not migrated to other devices via iCloud Keychain. Removing an instance via `ConfigManager.removeInstance` also calls `Keychain.setAuthHeader(nil, for: id)` (`ConfigManager.swift:183`), so orphaned credentials don't accumulate.

---

## 10. Security Model

**URL validation** (`ConfigManager.swift:203`): `URLValidator.validate` enforces scheme `http` or `https`, requires a non-empty host, and blocks the cloud metadata endpoint addresses `169.254.169.254` (AWS/Azure/GCP IMDSv1), `fd00:ec2::254` (AWS IMDSv2 IPv6), and `metadata.google.internal`. These are the addresses an SSRF attack would target to extract IAM credentials from a cloud host. Without this check, a user could be social-engineered into adding one of these URLs, and the app would dutifully poll it with any stored auth header.

**Response size cap**: 4 MB (`HTTPHelpers.maxResponseBytes`). Enforced before `JSONDecoder` is invoked. Prevents memory pressure from a server returning a pathologically large payload.

**Keychain accessibility**: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — not synced to iCloud Keychain, not migrated to new devices. Auth tokens for private local-network servers should not escape the originating machine.

**Config file permissions**: 0600 + `completeFileProtection`. The config file contains server URLs and names (not secrets), but 0600 prevents other users on a multi-user Mac from reading the server topology.

**Sandbox-disabled rationale**: The app runs outside the macOS App Sandbox (`ModelStatus.entitlements` does not include `com.apple.security.app-sandbox`). This is required for:
- `/bin/ps`, `/usr/sbin/lsof`, `/usr/bin/pgrep` — local process introspection.
- `brew services start/stop ollama` — Homebrew invocation.
- `/usr/bin/pkill` — local Ollama stop.
- Arbitrary outbound TCP to user-configured hosts (sandboxed apps require `com.apple.security.network.client` and can still connect, but some URL schemes are restricted).

**No telemetry, no analytics**: The app makes no outbound connections except to the servers the user explicitly configures, and on-demand to the user's own local network via Discovery. There is no crash reporter, no usage ping, no update check.

---

## 11. Customization Guide

### Adding a new provider

1. Create `MyProvider.swift` implementing `Provider`. Implement `probe` to return `true` for your server's distinguishing endpoint (e.g. a unique path or response key). Implement `check` to return a `ServerStatus` with `detectedKind` set to your new `ProviderKind` case.
2. Add a case to `ProviderKind` in `ConfigManager.swift:3` (add `case myProvider`). Update `displayName` switch.
3. Add a `ProviderCapabilities.myProvider` static constant in `Provider.swift:37-52`.
4. Append `MyProvider()` to `ProviderRegistry.all` in `Provider.swift:75`. Position matters for auto-detect order — insert before `OpenAIProvider` (catch-all).
5. Add the `case .myProvider: return MyProvider()` arm to `ProviderRegistry.provider(for:)` in `Provider.swift:82`.
6. Add the default port to `Monitor.defaultPort(for:)` in `Monitor.swift:135`.
7. Add the process keyword (if local probing applies) to `Monitor.processKeyword(for:)` in `Monitor.swift:144`.

### Adding a new poll interval option

Add a new case to `PollInterval` in `ConfigManager.swift:79` with a `TimeInterval` raw value and a `label` string. `SettingsWindowController` reads `PollInterval.allCases` to populate the popup (`SettingsWindow.swift:95`), so the new option appears automatically.

### Overriding the auto-detect order

Edit `ProviderRegistry.all` in `Provider.swift:75`. Move entries up to give them higher priority. The first provider whose `probe` returns `true` wins.

### Changing the menu bar icon

The brain emoji is a Unicode literal `"\u{1F9E0}"` at `StatusIndicator.swift:14`. Replace with any single character or emoji. The dots that follow it are `"\u{25CF}"` (filled) and `"\u{25CB}"` (open) at `StatusIndicator.swift:20-24`; change those to use different Unicode symbols or NSImage-based icons (requires converting from attributed-string title to button image).

### Adding a custom Authorization scheme

The `Keychain` stores the full `Authorization` header value verbatim (`Keychain.swift:9`). The `HTTPHelpers.get` and `HTTPHelpers.post` functions inject it as `req.setValue(h, forHTTPHeaderField: "Authorization")` (`Provider.swift:109`, `126`). Supported formats (anything valid for the HTTP Authorization header):
- `Bearer <token>`
- `Basic <base64-encoded-user:pass>`
- `ApiKey <key>` (non-standard but accepted by many servers)
- Any custom scheme like `Token <value>`

Enter the full string in Settings → Edit Auth. No parsing or transformation occurs.

### Adding tests

Test target is `ModelStatusTests` at `Tests/ModelStatusTests/`, declared in `Package.swift:13`. Run with `swift test`. Tests can import `ModelStatus` and instantiate any of the value types or call static functions directly. `Monitor` is an actor; test methods that call it must be `async`. Providers are stateless structs — inject a mock `URLSession` to test `check` without a live server.

---

## 12. Adding New Telemetry Signals (No Agent Install Required)

**Latency** — already captured. `HTTPHelpers.get` returns `latencyMs: Int` as its third return value (`Provider.swift:114`). All four provider `check` implementations pass this into `ServerStatus.latencyMs`. It is displayed in the menu as `📊 <N>ms` (`AppDelegate.swift:169`).

**Uptime / availability history** — not currently stored. The groundwork exists: `Monitor.lastReachability[UUID: Bool]` tracks the most recent reachability state per instance and fires `onReachabilityChange` on transitions (`Monitor.swift:66-71`). Adding uptime tracking requires persisting a `[UUID: [(Date, Bool)]]` ring buffer, either in memory (lost on restart) or appended to the config file. The `onReachabilityChange` callback is the right hook.

**Loaded-model deltas** — already available. Each `ServerStatus` contains `loadedModels: [LoadedModel]`. Comparing consecutive status values in `AppDelegate.currentStatuses` before overwriting detects model load/unload events without any server-side changes.

**VRAM via /metrics for vLLM** — already implemented. `VLLMProvider.check` fetches `/metrics` and calls `VLLMProvider.parseGPUMemoryBytes(prometheusText:)` (`VLLMProvider.swift:36-39`). The parser sums all Prometheus lines containing `vllm` and `memory`. To track individual GPU memory metrics separately, extend the parser to capture metric labels.

**Response-time-based "busy" inference detection** — proposed. For providers that don't expose a generating state (LM Studio, vLLM, generic OpenAI-compat), a sustained increase in `latencyMs` above a rolling baseline is a reasonable proxy for inference-in-flight. This would require storing a short latency history per instance and a threshold (e.g., 3× the median idle latency).

**What is not possible without an agent installed on the server host**: GPU temperature, fan speed, per-process GPU utilization (beyond what `/metrics` exposes for vLLM), total system memory and swap on remote machines, and inference request queue depth. These require either a sidecar process (e.g., a node exporter) or a dedicated metrics endpoint that most inference servers don't ship by default.

---

## 13. Build & Distribution

**SwiftPM** (`Package.swift`): Single executable target `ModelStatus`, path `ModelStatus/`, macOS 13+ minimum. Excludes `Info.plist` and `ModelStatus.entitlements` from compilation (they are copied by the assembly script). One test target `ModelStatusTests` at `Tests/ModelStatusTests/` depending on `ModelStatus`. Build: `swift build -c release`. Test: `swift test`.

**`scripts/build-app.sh`**: Produces `build/ModelStatus.app` from the SwiftPM release binary. Steps: `swift build -c release`, create `build/ModelStatus.app/Contents/MacOS` and `Contents/Resources`, copy the binary and `Info.plist`, write a `PkgInfo` file. Optionally codesigns with `--deep --force --options runtime` when `--sign "Developer ID Application: ..."` is passed. No Xcode, no xcodeproj, no xcarchive.

**CI — `.github/workflows/build.yml`**: Triggers on push/PR to `main`. Runs on `macos-14`. Steps: `swift --version`, `swift build -c release`, `swift test`, `./scripts/build-app.sh`, upload `build/ModelStatus.app` as artifact.

**CI — `.github/workflows/release.yml`**: Triggers on `v*` tag push. Runs the assembly script, zips with `ditto` (preserving resource forks), computes SHA-256, and creates a GitHub Release via `softprops/action-gh-release@v2` with `generate_release_notes: true`.

**Homebrew Cask** (`homebrew-tap/Casks/modelstatus.rb`): References `https://github.com/lucasmullikin/ModelStatus/releases/download/v<version>/ModelStatus-v<version>.zip`. `livecheck` strategy `github_latest`. `depends_on macos: ">= :ventura"`. `zap` removes both the config file and the LaunchAgent plist. Caveats note that the app is unsigned and instruct the user to run `xattr -dr com.apple.quarantine` after installation.

**Notarization** — deferred. The release workflow does not submit to Apple Notary Service. The Homebrew cask caveats document the manual quarantine removal step as a workaround.

**Login-item / LaunchAgent** (`LaunchAgent/`): A `com.lucrativepictures.ModelStatus.plist` LaunchAgent is included in the repo for users who want autostart without the Homebrew cask. Copy to `~/Library/LaunchAgents/` and bootstrap with `launchctl bootstrap gui/$UID`.

---

## 14. File Map

| File | Responsibility |
|---|---|
| `Provider.swift` | `Provider` protocol, `ProviderCapabilities`, `ProviderRegistry`, `HTTPHelpers`, `LocalProbe`, `ServerState`, `ServerStatus`, `LoadedModel` |
| `Monitor.swift` | Actor poll loop, provider resolution, memo state (`detectedKinds`, `lastActiveTime`, `lastClientIP`, `lastReachability`), eject/load/availableModels dispatch, local Ollama start/stop |
| `OllamaProvider.swift` | Ollama `/api/ps` + `/api/tags` polling, lsof-based generating detection, keep_alive eject/load |
| `OpenAIProvider.swift` | Generic `/v1/models` probe and check; catch-all for llama.cpp, MLX, LocalAI, text-gen-webui |
| `LMStudioProvider.swift` | LM Studio `/api/v0/models` (per-model loaded state), `/api/v0/models/load` and `/unload` |
| `VLLMProvider.swift` | vLLM `/v1/models` + Prometheus `/metrics` for VRAM; `parseGPUMemoryBytes` parser |
| `ConfigManager.swift` | `ProviderKind`, `Instance`, `AppConfig`, `PollInterval`, `ConfigManager` singleton, `URLValidator` |
| `Keychain.swift` | Minimal Keychain CRUD for per-instance auth headers; `kSecClassGenericPassword` |
| `Discovery.swift` | `DiscoveredServer`, `Discovery.scan()`, LAN /24 via `getifaddrs`, Tailscale peer enumeration |
| `AppDelegate.swift` | `@MainActor` application entry; menu construction; notification delivery; Settings/Welcome controller lifecycle |
| `StatusIndicator.swift` | `NSStatusItem` ownership; colored dot rendering; Ollama-only generating dot rule |
| `SettingsWindow.swift` | `SettingsWindowController` (NSTableView-based instance editor, poll/notify/compact controls, discovery sheet) |
| `WelcomeWindow.swift` | First-run onboarding window; `Notification.Name` extensions for cross-window signaling |
| `Formatters.swift` | `bytes()`, `elapsed()`, `bar()` (unicode block progress bar), `compactLine()`, `systemMemoryBytes` |
| `Package.swift` | SwiftPM manifest: macOS 13+, one executable target, one test target |
| `scripts/build-app.sh` | Assemble `build/ModelStatus.app` from SwiftPM output; optional codesign |
| `.github/workflows/build.yml` | CI: build + test + artifact upload on push/PR |
| `.github/workflows/release.yml` | Release: build, zip with ditto, SHA-256, GitHub Release on `v*` tag |
| `homebrew-tap/Casks/modelstatus.rb` | Homebrew Cask definition; livecheck; zap; Gatekeeper caveats |

---

## Open Design Questions (v3.1+)

- **Dedicated `MLXProvider`**: `mlx_lm.server` speaks `/v1/models` so it currently falls through to `OpenAIProvider`. A dedicated provider could detect it by probing `/v1/models` and checking the response structure (mlx_lm reports quantization info in model ids), and could surface per-layer memory stats once mlx exposes a metrics endpoint. This requires either Apple releasing an official metrics API for mlx_lm or a community extension.

- **App Store sandboxed build**: Distributing via the Mac App Store would require enabling `com.apple.security.app-sandbox` and `com.apple.security.temporary-exception.files.absolute-path.read-only` for `/bin/ps` and `/usr/sbin/lsof` paths, or replacing all process-inspection calls with an XPC helper. The entire `LocalProbe` namespace would need to be redesigned. This is architecturally possible but non-trivial and would require Apple approving the XPC helper entitlement.

- **Linux / Windows port**: The `LocalProbe` functions use macOS-specific paths (`/usr/sbin/lsof`, `/opt/homebrew`, `getifaddrs` with macOS struct layout). `Discovery` uses the Tailscale CLI path `/Applications/Tailscale.app/…`. `ConfigManager` writes to `~/Library/Preferences/`. `AppDelegate` and `StatusIndicator` use AppKit exclusively. A cross-platform port would need a platform abstraction layer for all five of these concerns and a GTK or WinUI 3 UI layer.

- **Sparkle auto-update**: No in-app update mechanism exists. The Homebrew cask has `livecheck` but requires manual `brew upgrade`. Integrating `Sparkle 2` (`https://sparkle-project.org`) would add one framework dependency (currently zero) and require a signed appcast. The release workflow already produces the zip and SHA-256 needed for an appcast entry.

- **Per-instance polling intervals**: All instances share a single `ConfigManager.shared.pollInterval`. A high-frequency instance (local Ollama at 2s) forces all remote instances to also poll at 2s, which is wasteful over a WAN. Supporting per-instance intervals requires changing `Monitor.startPolling` to maintain one `Task` per instance, each sleeping for its own interval, and merging results into a single ordered array on each callback. The `Monitor` actor's sequential `check` fan-out design accommodates this without structural changes.
