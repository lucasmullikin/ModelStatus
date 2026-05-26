# ModelStatus-AppStore.entitlements — documentation

The sibling `.entitlements` plist is the bare-minimum sandboxed
entitlements set for ModelStatus v1.0+. It has to be valid XML for
`codesign` — Apple's `codesign` AMFI parser doesn't handle multi-line
XML comments well — so the rationale lives here instead.

## Why this file exists

Mac App Store apps must declare `com.apple.security.app-sandbox=true` in
their entitlements. The `ModelStatus.entitlements` direct-download file
declares `false` for the unsandboxed builds (where `lsof`, `ps`,
`pgrep`, `brew` are all needed for full telemetry). `scripts/build-app.sh`
selects between the two based on the `--app-store` flag.

Architect-D54 gate finding #1 fix: previously the SAME
`ModelStatus.entitlements` (app-sandbox=false) was being used for both
builds. App Review would reject the upload within minutes — sandbox has
been mandatory for MAS apps since 2012.

## Entitlements granted

- **`app-sandbox = true`** — mandatory. Without it, App Review auto-rejects.
- **`network.client = true`** — outbound HTTP polling to local + remote LLM
  servers. NOT `network.server` — we never bind a listening socket.
- **`files.user-selected.read-write = true`** — needed for the
  `NSSavePanel` flow inside `DiagnosticBundle.exportInteractive(from:)`.
  Under sandbox, the panel returns a security-scoped URL that the app may
  write to (just-that-file scope; no broader filesystem access).

  Note: in the App Store build, the "Export Diagnostic Bundle" menu item
  is currently gated behind `#if !MODELSTATUS_APP_STORE` because the
  bundle internals use `Shell.run` + `/usr/bin/zip` which the sandbox
  rejects. The entitlement is still declared here so the v1.1 migration
  to `AppleArchive` framework + sandboxed save can ship without an
  entitlements bump (which triggers a fresh App Review).

## Entitlements NOT granted (intentional)

- `personal-information.*` (contacts/calendar/etc.) — we don't touch these
- `device.camera`, `device.microphone` — we don't use them
- `temporary-exception.*` — no escape-hatch privileges (these raise red
  flags with App Review)
- `inherit` — no child processes (relevant because `Shell.run` is
  unavailable under sandbox anyway via `SandboxedLocalSystemAccess`)
- `application-groups` — not needed; Keychain access works with the
  default sandbox keychain. Items stored with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` are correctly
  isolated to this app.

The OMISSIONS matter for App Review. Reviewers see this file via
`codesign -d --entitlements :- <app>` and notice tight bounds favorably.

## Security-reviewer subagent (2026-05-26) verdict

> The three-key set is correct and tight. Nothing present should be
> removed. `network.client` alone is sufficient for outbound HTTPS to
> `api.github.com` (the UpdateChecker call); App Transport Security
> default-allows HTTPS to public hosts, and the `NSAllowsLocalNetworking
> = true` in Info.plist permits `http://127.0.0.1:11434` (the local
> Ollama poll). No additional entitlements required for OSLogStore (the
> `.currentProcessIdentifier` scope is sandbox-safe without
> `com.apple.developer.diagnostics.read`).

## Future entitlement changes that would trigger a fresh App Review

Any added/removed entitlement key in this file requires a new App Review
cycle. The bare minimum here is intentional — if a future feature needs
e.g. `device.audio-input`, it'd be a separate release with its own
review pass.
