# ModelStatus v0.2.0

Foundation hardening release. No new providers, but the existing code has been substantially rebuilt for correctness, security, and the future App Store path.

## Install

```bash
brew tap lucasmullikin/tap
brew install --cask modelstatus
xattr -dr com.apple.quarantine /Applications/ModelStatus.app
open /Applications/ModelStatus.app
```

Or download `ModelStatus-v0.2.0.zip` from this release and drop the app into `/Applications`.

## What's new

### Diagnostics & debugging
- **OSLog viewer** in the menu — filter by category (`monitor`, `discovery`, `updater`, `provider.*`), 1-hour window, 1000-entry ring buffer.
- **Export Diagnostic Bundle…** — generates a privacy-scrubbed `.zip` you can attach to an issue. Hostnames are replaced with salted-SHA-256 tokens; credentials, auth headers, and URL userinfo are redacted; the per-install salt lives in the Keychain.

### MLX support
- Dedicated `MLXProvider` (not just OpenAI-compat).
- HuggingFace cache enumeration for "what could be served if you restart the process."
- Scheme-aware default port (HTTPS = 443, HTTP = 8080) so `https://localhost` works correctly.
- Argv-based local-process verification (won't expose your MLX cache to a non-MLX endpoint).

### Update checker
- **Snooze** (7 days) hides the "update available" badge without affecting the next background check.
- **Dismiss** removes a specific tag permanently (capped at 16 entries).
- App Store builds skip the GitHub-releases check entirely — both `check()` and `cachedAvailableUpdate()` short-circuit.

### Security
- Salted-SHA-256 log scrubber replaces the previous truncated-MD5 stand-in. URLs, hostnames, and auth headers are now consistently anonymized in OSLog output and the diagnostic bundle.
- `URLValidator` rejects octal/hex/decimal/shortened IPv4 forms, compressed IPv6, and any link-local / Tailscale CGNAT / RFC1918 / cloud-metadata literal.
- DNS-rebinding resolution guard pre-resolves via `getaddrinfo` and re-checks the bypass list.
- HTTP responses streamed with a 4 MB cap; no redirects allowed at the session level.
- Tailscale binary identity verified via codesign Team ID before exec.

### App Store readiness
- `LocalSystemAccess` protocol abstracts all `lsof` / `ps` / `pgrep` / shell calls. A compile flag (`MODELSTATUS_APP_STORE`) selects a `SandboxedLocalSystemAccess` fail-closed default for the App Store target. The polling loop, brew control, and Tailscale discovery all route through the protocol.

### Process
- 50+ rounds of Codex 5.5 audit-fix iteration (4 in hard mode at `REASONING_EFFORT=high`).
- 1 architectural outside-review pass.
- 41/41 unit tests passing.

## Known limitations

- **Unsigned binary** — Apple Developer enrollment is the next prerequisite. Run `xattr -dr com.apple.quarantine /Applications/ModelStatus.app` once after install.
- **macOS 13+** — uses OSLog Store, modern Swift Concurrency, `replaceItemAt` with `.usingNewMetadataOnly`.
- **Sandbox is OFF** in the direct-download build — local-server telemetry needs `lsof` / `ps`. The future App Store build will degrade those gracefully.

## Breaking changes

None. v0.1 configs and Keychain entries load directly.

## Deferred to v0.2.1 / v0.3

- Anonymizer `ParsedAuthority` shared parser (3 internal URL-parsing pipelines collapse to 1).
- Single source of truth for "config era" (consolidates 4 cancellation mechanisms).
- `Provider.swift` 4-way split (Provider / HTTPHelpers / LocalProbe / Shell).
- MLX argv hoisted into `CheckRequest` (drops 2 shell calls per poll).

---

**Full changelog:** see commits between `v0.1.0-beta` and `v0.2.0`.

**Report issues:** https://github.com/lucasmullikin/ModelStatus/issues
**Security disclosures:** lucas@lucrativepictures.com (30-day window — see [SECURITY.md](SECURITY.md))
