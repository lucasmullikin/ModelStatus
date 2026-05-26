# Security Policy

## Supported Versions

ModelStatus is in active beta. Security fixes land in the current pre-release
tag. Older tags are not back-patched.

| Version line | Status |
|--------------|--------|
| 0.2.x-beta   | Supported |
| 0.1.x-beta   | Superseded — please upgrade |

## Reporting a Vulnerability

Email **lucas@lucrativepictures.com** with:

- a short description of the issue,
- steps to reproduce (or a proof-of-concept), and
- the version (`About → CFBundleShortVersionString`) and macOS build.

Do **not** open a public GitHub issue for security bugs. Please give us a
reasonable window (≈ 30 days) to ship a fix before public disclosure.

If you don't get an acknowledgement within 7 days, feel free to escalate via
the maintainer's GitHub profile.

## Out of Scope

These are intentional design trade-offs, not vulnerabilities:

- **The app runs unsandboxed.** It uses `lsof` / `ps` / `pgrep` for local-server
  telemetry, which sandboxed apps can't do. A future App Store build will use
  a sandboxed variant with degraded telemetry.
- **The app polls localhost / Tailscale-peer URLs you configure.** It does not
  resolve hostnames against a connection-time blocklist — only the literal
  cloud-metadata IPs (`169.254.169.254` and IPv6/numeric/octal/hex equivalents)
  are rejected at Settings input time. If you point ModelStatus at a hostname
  that resolves to a metadata endpoint, it will connect to that endpoint.
- **No telemetry.** We don't collect anything. If a bug or feature you find
  *would* require telemetry, file a regular issue first so we can discuss.

## What's Hardened

In the current code:

- **Credentials**: per-instance `Authorization` headers live only in the
  macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). They
  never touch the config JSON, logs, diagnostic exports, or commits.
- **Cloud-metadata SSRF guard**: `URLValidator` canonicalizes IPv4 via
  `inet_aton` and IPv6 via `inet_pton`/`inet_ntop` so decimal, octal, hex,
  compressed, and shortened forms of blocked addresses all collapse to the
  same numeric check.
- **HTTP response size cap**: 4 MB streaming cap on all `HTTPHelpers.get` /
  `.post` calls — buffers are aborted as soon as the cap is exceeded.
- **Diagnostic bundle redaction**: Authorization headers, URL credentials,
  query secrets, JSON-shaped secret fields, and IP/hostnames are all
  scrubbed before zipping. The scrub salt lives in Keychain, not in the
  bundle.
- **No outbound traffic**: only the model-server URLs you configure +
  `api.github.com` for the once-per-24h update check.

## What's NOT Hardened (Yet)

- The app is **not codesigned and not notarized.** Users must run
  `xattr -dr com.apple.quarantine /Applications/ModelStatus.app` after
  install. A notarized build is on the roadmap.
- There is no automated SLSA provenance attestation on release artifacts
  yet. Verify downloads with the published `.sha256` file alongside the zip.
