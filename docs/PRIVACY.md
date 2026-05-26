# ModelStatus Privacy Policy

**Last updated: 2026-05-26**
**Version: 1.0 (matches ModelStatus v1.0)**

## TL;DR

**ModelStatus collects nothing. No telemetry, no analytics, no cloud,
no account, no tracking, no ads. Network traffic only goes to the
LLM servers you configure and (direct-download builds only) to
github.com once a day to check for new versions.**

---

## What ModelStatus is

ModelStatus is a macOS menu bar application that monitors local
HTTP-accessible AI model servers (Ollama, LM Studio, vLLM, MLX,
llama.cpp, and any OpenAI-compatible API). It is developed and
published by Lucas Mullikin (individual developer, US-based,
Apple Developer Team ID `ZFXWBW78LZ`).

Source code is available at <https://github.com/lucasmullikin/ModelStatus>
under the MIT License.

## What data ModelStatus collects

**None.** ModelStatus does not collect, store, transmit, sell, share,
or otherwise process any personal data or telemetry from users.

The 14 Apple App Privacy data categories — all answered "Data Not
Collected":

- Contact Info, Health & Fitness, Financial Info, Location,
  Sensitive Info, Contacts, User Content, Browsing History,
  Search History, Identifiers, Purchases, Usage Data, Diagnostics,
  Other Data.

## What network connections ModelStatus makes

ModelStatus connects only to:

1. **The LLM server URLs you explicitly configure** in the Settings
   window or via the Discovery scan. Connections poll `/api/tags`,
   `/api/ps`, `/v1/models`, `/metrics`, etc. at the interval you
   choose (default 5 seconds). Polling stops when ModelStatus quits.
2. **Your local network (`/24` subnet)** — only when you press the
   "Discover" button. ModelStatus scans the common model-server
   ports (11434, 1234, 8080, 8000, 10240, 5001) and reports
   responding hosts. The scan does not run automatically.
3. **Tailscale peers** — only when you press the "Discover" button
   AND Tailscale.app is installed on your Mac. ModelStatus calls
   the local `tailscale status --json` command and probes the
   reported peers.
4. **github.com** (direct-download builds only) — once every 24
   hours, ModelStatus fetches
   `https://api.github.com/repos/lucasmullikin/ModelStatus/releases/latest`
   to check for new versions. **No user identifier, telemetry,
   or analytics is sent.** Apple App Store builds skip this check
   entirely (Apple's auto-update mechanism handles updates).

ModelStatus never makes any other outbound connection. There is no
backend service, no usage tracking, no error reporting service,
no SDK that could phone home.

## What data ModelStatus stores locally

All data stays on your Mac. Specifically:

1. **`~/Library/Preferences/com.lucasmullikin.ModelStatus.json`**
   (mode 0600 — owner-readable only) — your server list, poll
   interval, notification preference, compact-menu preference.
2. **macOS Keychain** items with service identifier
   `com.lucasmullikin.ModelStatus.auth` — Authorization headers
   you've optionally set for individual servers.
   Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
   (no iCloud Keychain sync, this device only).
3. **macOS Keychain** items with service identifier
   `com.lucasmullikin.ModelStatus.anon` — a random salt used to
   anonymize hostnames in exported diagnostic bundles (see below).
   Generated once on first diagnostic-bundle export.
4. **macOS unified log (OSLog)** — runtime log entries under
   subsystem `com.lucasmullikin.ModelStatus`. Standard macOS log
   storage; visible in Console.app. ModelStatus's in-app Log
   Viewer reads from this same store via `OSLogStore.local()`.

## Diagnostic Bundle Export

If you trigger **Settings → Diagnostics → Export Diagnostic Bundle…**,
ModelStatus creates a `.zip` file with:
- Recent log entries (last 1 hour, capped at 1000 lines)
- A snapshot of your server config (hostnames are anonymized via
  salted SHA-256 — the salt lives in your Keychain and never
  leaves your device)
- macOS version, hardware model, available memory
- A list of running processes by name only (no full command lines)

All output is privacy-scrubbed. Hostnames are replaced with
`host-<64hex>` tokens that are stable across the bundle but cannot
be reversed back to the original hostname (the salt is required
and never leaves your device). Auth headers, API keys, query
strings, and URL credentials are explicitly redacted.

The bundle is written to a location you select via the standard
macOS Save Panel. ModelStatus does not upload the bundle anywhere —
it's yours to do with as you wish (e.g., attach to a GitHub issue
when reporting a bug).

This feature is disabled in the App Store sandboxed build (the
underlying `sw_vers` / `sysctl` / `ps` shell calls aren't permitted
under sandbox). It remains available in the direct-download build.

## Notifications

If you enable "Notify on reachability change" in Settings, ModelStatus
will request macOS notification permission and post local
notifications when one of your configured servers becomes unreachable
or comes back. These are standard macOS notifications generated
on-device. No notification content is transmitted anywhere.

## Third-Party Services

None. ModelStatus has no third-party SDKs, no analytics frameworks,
no ad networks, no crash reporters. The binary statically links only
Apple's standard frameworks (Foundation, AppKit, CryptoKit, OSLog,
Security, ServiceManagement, UserNotifications, UniformTypeIdentifiers).

## Children

ModelStatus is not directed to children and does not knowingly
collect data from anyone under 13. Age rating: 4+ (no restricted
content).

## Changes to this Policy

If this policy materially changes, the new version will be posted
at the same URL with an updated "Last updated" date. Material
changes are also noted in the app's release notes.

## Contact

Author: Lucas Mullikin
Email: lucas@lucasmullikin.com (or via GitHub Issues at
<https://github.com/lucasmullikin/ModelStatus/issues>)
Security disclosures: see `SECURITY.md` in the repository.

## Jurisdiction

ModelStatus is developed in the United States (Boise, Idaho).
Your use of the software is subject to the MIT License terms in
`LICENSE` and, for App Store distribution, Apple's standard EULA.
