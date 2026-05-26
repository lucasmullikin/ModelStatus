import AppKit
import OSLog
import Foundation
import UniformTypeIdentifiers

/// Diagnostic bundle exporter — produces a user-savable .zip with config, logs,
/// system info, and (optionally) a process list + discovery scan. Every text file
/// inside is run through `Anonymizer.scrub` so secrets and hostnames don't leak.
enum DiagnosticBundle {

    // MARK: Options

    struct Options {
        var anonymizeHostnames: Bool = true
        var includeProcessList: Bool = false
        var includeDiscoveryScan: Bool = false
    }

    // MARK: Interactive entry point

    /// Driven from a menu item. Shows an options sheet, then an NSSavePanel,
    /// then assembles the bundle on a background task.
    @MainActor
    static func exportInteractive(from parent: NSWindow?) async {
        guard let options = await presentOptionsSheet(parent: parent) else { return }
        guard let destination = await presentSavePanel(parent: parent) else { return }

        do {
            try await assemble(to: destination, options: options)
            presentSuccessAlert(parent: parent, destination: destination)
        } catch {
            presentFailureAlert(parent: parent, error: error)
        }
    }

    // MARK: Options sheet

    @MainActor
    private static func presentOptionsSheet(parent: NSWindow?) async -> Options? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Options?, Never>) in
            let alert = NSAlert()
            alert.messageText = "Export Diagnostics"
            alert.informativeText = "Choose what to include. The bundle is a .zip you save locally — nothing is sent anywhere."
            alert.addButton(withTitle: "Export…")
            alert.addButton(withTitle: "Cancel")

            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))

            let anonCheck = NSButton(checkboxWithTitle: "Anonymize hostnames", target: nil, action: nil)
            anonCheck.state = .on
            anonCheck.frame = NSRect(x: 0, y: 56, width: 320, height: 20)

            let procCheck = NSButton(checkboxWithTitle: "Include local process list (model servers only)",
                                     target: nil, action: nil)
            procCheck.state = .off
            procCheck.frame = NSRect(x: 0, y: 28, width: 320, height: 20)

            let discCheck = NSButton(checkboxWithTitle: "Include LAN/Tailscale discovery scan",
                                     target: nil, action: nil)
            discCheck.state = .off
            discCheck.frame = NSRect(x: 0, y: 0, width: 320, height: 20)

            accessory.addSubview(anonCheck)
            accessory.addSubview(procCheck)
            accessory.addSubview(discCheck)
            alert.accessoryView = accessory

            let respond: (NSApplication.ModalResponse) -> Void = { response in
                if response == .alertFirstButtonReturn {
                    let opts = Options(
                        anonymizeHostnames: anonCheck.state == .on,
                        includeProcessList: procCheck.state == .on,
                        includeDiscoveryScan: discCheck.state == .on
                    )
                    continuation.resume(returning: opts)
                } else {
                    continuation.resume(returning: nil)
                }
            }

            if let parent {
                alert.beginSheetModal(for: parent, completionHandler: respond)
            } else {
                respond(alert.runModal())
            }
        }
    }

    @MainActor
    private static func presentSavePanel(parent: NSWindow?) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let panel = NSSavePanel()
            panel.title = "Save Diagnostic Bundle"
            panel.nameFieldStringValue = "ModelStatus-diagnostics-\(timestampForFilename()).zip"
            // Audit-round-4: declare the actual ZIP UTType so Save panel
            // filtering matches what we'll write.
            panel.allowedContentTypes = [.zip]
            panel.allowsOtherFileTypes = false
            let respond: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
            if let parent {
                panel.beginSheetModal(for: parent, completionHandler: respond)
            } else {
                respond(panel.runModal())
            }
        }
    }

    @MainActor
    private static func presentSuccessAlert(parent: NSWindow?, destination: URL) {
        let alert = NSAlert()
        alert.messageText = "Diagnostics exported"
        alert.informativeText = destination.path
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "OK")
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
        if let parent {
            alert.beginSheetModal(for: parent, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    @MainActor
    private static func presentFailureAlert(parent: NSWindow?, error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't export diagnostics"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let parent {
            alert.beginSheetModal(for: parent, completionHandler: { _ in })
        } else {
            alert.runModal()
        }
    }

    // MARK: Assembly

    /// Build a diagnostic .zip at `destZip`. Throws on any unrecoverable failure.
    static func assemble(to destZip: URL, options: Options) async throws {
        // 0700 staging dir under the system temp (security M5).
        let stage = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stage) }

        // 1. Config snapshot (read on MainActor since ConfigManager is @MainActor)
        let configJSON = try await collectConfigJSON(anonymize: options.anonymizeHostnames)
        try writeText(configJSON, to: stage.appendingPathComponent("config.json"))

        // 2. Logs (last hour, all categories)
        let logsText = collectLogsText()
        try writeText(logsText, to: stage.appendingPathComponent("logs.txt"))

        // 3. System info
        let sysInfo = await collectSystemInfo()
        try writeText(sysInfo, to: stage.appendingPathComponent("system-info.txt"))

        // 4. Optional: process list (model-server names only, no args)
        if options.includeProcessList {
            let procs = await collectProcessList()
            try writeText(procs, to: stage.appendingPathComponent("processes.txt"))
        }

        // 5. Optional: discovery scan
        if options.includeDiscoveryScan {
            let disc = try await collectDiscoveryJSON()
            try writeText(disc, to: stage.appendingPathComponent("discovery.json"))
        }

        // 6. README — included in the anonymization pass too (security L3).
        try writeText(readmeText(), to: stage.appendingPathComponent("README.txt"))

        // 7. Bundle-wide redaction pass: every text file goes through Anonymizer.scrub
        //    (handles Authorization, api_key, IPs, hostnames). When the user opts out
        //    of hostname anonymization we still strip secrets — that's non-negotiable.
        try redactAllTextFiles(in: stage, anonymizeHostnames: options.anonymizeHostnames)

        // 8. Zip the staging dir into destZip.
        try zipStaging(stage: stage, dest: destZip)
    }

    // MARK: Staging dir

    private static func makeStagingDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStatus-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return base
    }

    // MARK: Collectors

    @MainActor
    private static func collectConfigJSON(anonymize: Bool) throws -> String {
        var cfg = ConfigManager.shared.config
        if anonymize {
            cfg.instances = cfg.instances.map { inst in
                var copy = inst
                copy.url = Anonymizer.scrubURL(inst.url)
                return copy
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cfg)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Note: `ConfigManager.bundleIdentifier` is `nonisolated static let` — safe
    /// to read from any isolation domain. We don't need to be on MainActor
    /// just to assemble the OSLog predicate string.
    /// Audit-round-D2: stream entries through a fixed-size ring buffer so a
    /// verbose process can't materialize tens of thousands of OSLogEntry
    /// values during export. Cap matches LogViewerWindowController's
    /// `maxEntries` so the diagnostic bundle and in-app viewer report the
    /// same snapshot.
    private static let maxLogEntries = 1000
    private static func collectLogsText() -> String {
        let subsystem = ConfigManager.bundleIdentifier
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-3600))
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let entries = try store.getEntries(at: position, matching: predicate)

            var ring = [OSLogEntryLog?](repeating: nil, count: maxLogEntries)
            var ringCount = 0
            var ringHead = 0
            var total = 0
            // Audit-round-D26: shorten the lookback window proactively under
            // high log volume so the retained ring is biased toward the
            // NEWEST entries. OSLogStore enumerates oldest→newest from
            // `position`; a flat scan cap would keep the oldest entries and
            // drop the most recent (most diagnostically valuable) ones.
            // Strategy: run the scan with a generous cap; if we hit it,
            // narrow the lookback to the last 5 minutes and re-scan.
            let maxScannedEntries = 50_000
            var scanned = 0
            var hitCap = false
            for entry in entries {
                scanned += 1
                if scanned > maxScannedEntries { hitCap = true; break }
                guard let log = entry as? OSLogEntryLog else { continue }
                total += 1
                if ringCount < maxLogEntries {
                    ring[(ringHead + ringCount) % maxLogEntries] = log
                    ringCount += 1
                } else {
                    ring[ringHead] = log
                    ringHead = (ringHead + 1) % maxLogEntries
                }
            }
            // Audit-round-D30: progressive fallback windows. The retained ring
            // should always cover the newest entries; under hostile log volume
            // even a 5-minute window can blow past 50k entries. Try
            // 5 min → 1 min → 15 s; stop at the first window that completes
            // under the cap. Track which window succeeded so the header
            // accurately reflects the snapshot's coverage.
            let fallbackWindows: [(label: String, seconds: TimeInterval)] = [
                ("5 minutes", 300),
                ("1 minute", 60),
                ("15 seconds", 15),
                ("1 second", 1)
            ]
            var fallbackUsedLabel: String? = nil
            if hitCap {
                for window in fallbackWindows {
                    let recentPosition = store.position(date: Date().addingTimeInterval(-window.seconds))
                    guard let recentEntries = try? store.getEntries(at: recentPosition, matching: predicate) else {
                        continue
                    }
                    ring = [OSLogEntryLog?](repeating: nil, count: maxLogEntries)
                    ringCount = 0
                    ringHead = 0
                    total = 0
                    scanned = 0
                    var windowHitCap = false
                    for entry in recentEntries {
                        scanned += 1
                        if scanned > maxScannedEntries { windowHitCap = true; break }
                        guard let log = entry as? OSLogEntryLog else { continue }
                        total += 1
                        if ringCount < maxLogEntries {
                            ring[(ringHead + ringCount) % maxLogEntries] = log
                            ringCount += 1
                        } else {
                            ring[ringHead] = log
                            ringHead = (ringHead + 1) % maxLogEntries
                        }
                    }
                    if !windowHitCap {
                        fallbackUsedLabel = window.label
                        break
                    }
                    // else: this window also hit the cap; try the next narrower one.
                }
            }
            let scanCapped = hitCap
            let fallbackLabel = fallbackUsedLabel

            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            var lines: [String] = []
            lines.reserveCapacity(ringCount + 1)
            // Audit-round-D30: report the ACTUAL fallback window that
            // succeeded, not a hardcoded "5 minutes". If every narrowing
            // step still hit the cap, say so honestly.
            if scanCapped, let label = fallbackLabel {
                if total > maxLogEntries {
                    lines.append("# (log volume exceeded scan cap; narrowed to last \(label); showing last \(maxLogEntries) of \(total) entries)")
                } else {
                    lines.append("# (log volume exceeded scan cap; narrowed to last \(label) — \(total) entries)")
                }
            } else if scanCapped {
                // Audit-round-D33: every fallback window — down to 1 second
                // — still hit the cap. Don't emit a misleading partial ring;
                // omit the body and surface only the cap notice. The user
                // gets an honest "log scan failed" rather than a stale
                // snapshot mislabelled as recent.
                return "# (log volume exceeded scan cap at every window down to 1 second — no usable snapshot)\n"
            } else if total > maxLogEntries {
                lines.append("# (truncated: showing last \(maxLogEntries) of \(total) entries from the last hour)")
            }
            for i in 0..<ringCount {
                guard let e = ring[(ringHead + i) % maxLogEntries] else { continue }
                let ts = f.string(from: e.date)
                let lvl = levelTag(e.level)
                let cat = e.category.isEmpty ? "-" : e.category
                lines.append("\(ts) [\(lvl)] [\(cat)] \(e.composedMessage)")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Failed to read OSLogStore: \(error.localizedDescription)\n"
                 + "Try Console.app → filter on subsystem \(subsystem)."
        }
    }

    private static func collectSystemInfo() async -> String {
        let pi = ProcessInfo.processInfo
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let buildVersion = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"
        let osVer = pi.operatingSystemVersionString

        let swVers = await LocalProbe.runShell("/usr/bin/sw_vers", args: []) ?? ""
        let model = await LocalProbe.runShell("/usr/sbin/sysctl", args: ["-n", "hw.model"]) ?? ""
        let memBytes = await LocalProbe.runShell("/usr/sbin/sysctl", args: ["-n", "hw.memsize"]) ?? ""

        var out = "ModelStatus \(appVersion) (build \(buildVersion))\n"
        out += "OS: \(osVer)\n\n"
        out += "sw_vers:\n\(swVers.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        out += "hw.model: \(model.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        out += "hw.memsize: \(memBytes.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        return out
    }

    /// `comm` + PID only, filtered to known model-server binaries.
    /// Per security M2: never emit raw `args` — they can contain API keys,
    /// model paths, etc. that the user wouldn't expect to ship.
    private static let modelServerNames: [String] = [
        "mlx_lm", "ollama", "lm-studio", "lmstudio", "vllm"
    ]

    private static func collectProcessList() async -> String {
        guard let output = await LocalProbe.runShell("/bin/ps", args: ["-Aco", "pid,comm"]) else {
            return "ps unavailable\n"
        }
        // Audit-round-D29: match against the COMM column's basename only,
        // not the whole line. Substring matching previously could include
        // unrelated processes whose name happened to contain an allowed
        // substring.
        let needles = modelServerNames.map { $0.lowercased() }
        var matches: [String] = ["PID    COMM"]
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // `ps -Aco pid,comm`: column 0 = PID, column 1+ = COMM (path).
            let fields = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 2 else { continue }
            let comm = fields[1].lowercased()
            let basename = comm.split(separator: "/").last.map(String.init) ?? comm
            if needles.contains(where: { basename == $0 || basename.hasPrefix($0) }) {
                matches.append(trimmed)
            }
        }
        if matches.count == 1 { matches.append("(no matching processes)") }
        return matches.joined(separator: "\n") + "\n"
    }

    private static func collectDiscoveryJSON() async throws -> String {
        let results = await Discovery.scan()
        // Encode a minimal projection — DiscoveredServer isn't Codable directly,
        // and we want to be explicit about what ships.
        let projection = results.map { ds -> [String: Any] in
            [
                "host": ds.host,
                "port": ds.port,
                "kind": ds.kind.rawValue,
                "source": ds.source.rawValue
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: projection,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func readmeText() -> String {
        """
        ModelStatus Diagnostic Bundle
        =============================

        Generated: \(ISO8601DateFormatter().string(from: Date()))

        Files in this bundle
        --------------------
          config.json       App configuration (instances, poll interval, flags).
          logs.txt          OSLog entries from the last hour, subsystem-filtered.
          system-info.txt   macOS + hardware identifiers and app version.
          processes.txt     (optional) PID + comm for known model-server processes.
          discovery.json    (optional) Snapshot of LAN/Tailscale discovery scan.

        What was redacted
        -----------------
        Authorization headers, api_key/token/access_token/key/auth query values,
        and any URL credentials are replaced with <redacted>.

        If you chose "Anonymize hostnames", IPv4/IPv6 addresses and *.local,
        *.ts.net, *.tailscale.net, AWS, and Google hostnames are hashed with a
        per-install salt (the salt stays in your Keychain — it is NOT in this
        bundle). Identical hosts hash to the same token within a bundle.

        What is NOT in this bundle
        --------------------------
        Keychain auth tokens, the anonymization salt, raw process arguments,
        environment variables, file contents, or anything outside the items
        listed above. ModelStatus has no telemetry or phone-home.

        Sharing
        -------
        This file is safe to attach to a GitHub issue. If you want a second
        scrubbing pass, open the .zip, eyeball the text files, and remove
        anything you don't want shared before sending.
        """
    }

    // MARK: Redaction pass

    /// Bundle-wide redaction pass. **Throws** if any text file in the staging
    /// directory cannot be read or UTF-8-decoded — we'd rather fail the export
    /// than ship an unredacted file. Previously this used `try? … continue`,
    /// which the v0.2 audit flagged as a silent-failure surface.
    private static func redactAllTextFiles(in dir: URL, anonymizeHostnames: Bool) throws {
        // Audit-round-D31: walk recursively so any future nested staged file
        // also goes through redaction. Today every staged file is top-level,
        // but `zipStaging` archives recursively — keep the redaction surface
        // matching the archive surface.
        let fm = FileManager.default
        // Audit-round-D32+D33: throw on resource-value lookup failure rather
        // than silently skipping a file. Also fail if the enumerator itself
        // can't be created — silently producing zero files would skip
        // redaction entirely, the opposite of the export's privacy intent.
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw NSError(
                domain: "ModelStatus.DiagnosticBundle",
                code: -16,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't enumerate staging directory for redaction at \(dir.path)"]
            )
        }
        var contents: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { contents.append(url) }
        }
        for url in contents {
            guard isTextFile(url) else { continue }
            let data = try Data(contentsOf: url)
            guard var text = String(data: data, encoding: .utf8) else {
                throw NSError(
                    domain: "ModelStatus.DiagnosticBundle",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Couldn't decode \(url.lastPathComponent) as UTF-8 for redaction; aborting export to avoid shipping un-scrubbed content."]
                )
            }
            // We always strip secrets. Hostname/IP hashing only when opted in.
            text = anonymizeHostnames ? Anonymizer.scrub(text) : stripSecretsOnly(text)
            guard let outData = text.data(using: .utf8) else {
                throw NSError(
                    domain: "ModelStatus.DiagnosticBundle",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Couldn't re-encode \(url.lastPathComponent) after redaction."]
                )
            }
            try outData.write(to: url, options: [.atomic])
        }
    }

    private static let textExtensions: Set<String> = ["txt", "json", "log", "md"]

    private static func isTextFile(_ url: URL) -> Bool {
        textExtensions.contains(url.pathExtension.lowercased())
    }

    /// When the user opts out of hostname anonymization, we still run a
    /// secrets-only pass. Implemented as a narrow regex set rather than
    /// reusing Anonymizer.scrub so we don't accidentally hash hosts.
    private static func stripSecretsOnly(_ text: String) -> String {
        var s = text
        for (pattern, replacement) in secretsOnlyPatterns {
            let range = NSRange(s.startIndex..., in: s)
            s = pattern.stringByReplacingMatches(in: s, range: range, withTemplate: replacement)
        }
        return s
    }

    private static let secretsOnlyPatterns: [(NSRegularExpression, String)] = {
        // Match the FULL Authorization header value regardless of scheme
        // prefix. Audit-round-D28: the `^`-anchored form missed authorization
        // values inside formatted log lines like
        // `2026-... [INFO] [net] Authorization: Bearer abc` because the
        // header isn't at the start of the line. Match anywhere with a
        // word boundary, consume to end of line.
        let auth = try! NSRegularExpression(pattern: #"(?im)(\bAuthorization\s*:\s*).+$"#)
        let query = try! NSRegularExpression(
            pattern: #"(?i)([?&](?:api[_-]?key|access[_-]?token|token|key|auth|password|secret)=)[^&\s"'<>]+"#)
        // URL credentials: `scheme://userinfo@host[:port][/path]` — strip the
        // userinfo block. Audit-round-D31: also handle the password-less
        // form `scheme://token@host` (e.g. GitHub-style `https://token@…`),
        // not just `user:password@`. Userinfo is `[^/@\s]+`.
        let urlCreds = try! NSRegularExpression(
            pattern: #"([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@\s]+@"#)
        // JSON-shaped secret fields: `"api_key": "..."`, `"token": "..."`, etc.
        // Audit-round-D31: handle backslash-escaped quotes inside the value so
        // `"token": "abc\"def"` is fully redacted rather than truncating at
        // the embedded escape. The value pattern is "anything except an
        // unescaped quote", expressed as zero or more of (\\. | [^"\\]).
        let jsonSecret = try! NSRegularExpression(
            pattern: #"(?i)("(?:api[_-]?key|access[_-]?token|token|key|auth|password|secret)"\s*:\s*")(?:\\.|[^"\\])*(")"#)
        // Bare `key=value` forms in log text outside a URL query. Audit-round-5:
        // add `auth` and `key` to match the query/json sets (previously omitted).
        let bareKV = try! NSRegularExpression(
            pattern: #"(?i)(\b(?:api[_-]?key|access[_-]?token|token|auth|key|password|secret)\s*=\s*)[^\s,;"'<>&]+"#)
        return [
            (auth,       "$1<redacted>"),
            (query,      "$1<redacted>"),
            (urlCreds,   "$1<redacted>@"),
            (jsonSecret, "$1<redacted>$2"),
            (bareKV,     "$1<redacted>")
        ]
    }()

    // MARK: Zip

    /// Build the archive in a sibling temp file, set 0600 perms, then atomically
    /// replace any existing file at `dest`. Two audit-round-2 issues addressed:
    ///
    /// 1. **Permissions**: `/usr/bin/zip` writes via the user's umask (often 0644
    ///    → world-readable). We chmod the new file BEFORE it lands at the user's
    ///    chosen path so a diagnostic bundle can't be read by other local users.
    /// 2. **Rollback**: previously the existing destination was removed before
    ///    `zip` ran — a zip failure left the user with neither the old file nor
    ///    a new one. Writing to a sibling first preserves the original on failure.
    private static func zipStaging(stage: URL, dest: URL) throws {
        // Audit-round-D23: resolve symlinks and standardize both paths
        // before the containment check so a `dest` that includes `..` or a
        // symlink resolving under `stage` can't bypass the guard.
        let canonicalStage = stage.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalDest = dest.resolvingSymlinksInPath().standardizedFileURL.path
        if canonicalDest.hasPrefix(canonicalStage + "/") || canonicalDest == canonicalStage {
            throw NSError(
                domain: "ModelStatus.DiagnosticBundle",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Destination cannot be inside the staging directory."]
            )
        }

        // Audit-round-D32: verify the destination's parent directory exists
        // and is a directory BEFORE we start staging work. NSSavePanel
        // always provides an existing parent, but direct callers of
        // `assemble(to:options:)` may not.
        let parent = dest.deletingLastPathComponent()
        var parentIsDir: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDir)
        if !parentExists || !parentIsDir.boolValue {
            throw NSError(
                domain: "ModelStatus.DiagnosticBundle",
                code: -15,
                userInfo: [NSLocalizedDescriptionKey: "Destination parent directory does not exist or is not a directory: \(parent.path)"]
            )
        }

        // Audit-round-3: zip into a PRIVATE 0700 sibling directory so the
        // in-flight archive is never readable by other local users during
        // creation. Avoids the umask-controlled window where the prior
        // implementation wrote a temp file with default 0644 perms.
        let privateDir = parent.appendingPathComponent(".ModelStatus-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: privateDir,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: privateDir) }
        let tmp = privateDir.appendingPathComponent("bundle.zip")

        // Audit-round-D3: redirect zip stderr to a file inside the private
        // 0700 staging dir rather than a Pipe. This sidesteps the pipe-buffer
        // deadlock concern entirely (a chatty zip can't block on write because
        // the kernel just keeps appending to the file), AND avoids the
        // readabilityHandler ↔ teardown race that the previous Pipe-based
        // approach kept hitting. The file lives in privateDir so it's
        // 0700-scoped and disappears when the defer'd removeItem runs.
        let stderrPath = privateDir.appendingPathComponent("zip-stderr.log")
        FileManager.default.createFile(
            atPath: stderrPath.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        guard let stderrWrite = try? FileHandle(forWritingTo: stderrPath) else {
            throw NSError(
                domain: "ModelStatus.DiagnosticBundle",
                code: -12,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't open zip stderr capture file."]
            )
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -r recursive, -q quiet, -X strip extra file attributes (cleaner output)
        proc.arguments = ["-rqX", tmp.path, "."]
        proc.currentDirectoryURL = stage
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = stderrWrite

        try proc.run()
        proc.waitUntilExit()
        try? stderrWrite.close()

        if proc.terminationStatus != 0 {
            let raw = (try? Data(contentsOf: stderrPath)) ?? Data()
            // Cap at 4 KB so a hostile/runaway stderr can't bloat our error.
            let snippet = String(data: raw.prefix(4096), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = snippet.isEmpty
                ? "zip exited with status \(proc.terminationStatus)"
                : "zip exited with status \(proc.terminationStatus): \(snippet)"
            throw NSError(
                domain: "ModelStatus.DiagnosticBundle",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        // chmod 0600 the archive inside the private dir.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tmp.path
        )

        // Audit-round-D25: use `replaceItemAt` with `.usingNewMetadataOnly`
        // so we avoid both metadata carryover (ACLs, extended attributes,
        // quarantine flags from the prior file) AND the data-loss window of
        // remove-then-move. macOS will preserve the old file if the move
        // fails. Additionally refuse if dest exists but is a directory —
        // we'd be destroying user data with no real recovery.
        // Audit-round-D34: detect symlinks via destinationOfSymbolicLink
        // which works for DANGLING symlinks too (where resourceValues can
        // fail because the target is missing). If the call succeeds, the
        // path is a symlink — refuse, regardless of whether the target
        // exists. Following symlinks for a privacy-sensitive write would be
        // surprising.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: dest.path)) != nil {
            throw NSError(
                domain: "ModelStatus.DiagnosticBundle",
                code: -14,
                userInfo: [NSLocalizedDescriptionKey: "Destination is a symbolic link. Refusing to write through it."]
            )
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir)
            if isDir.boolValue {
                throw NSError(
                    domain: "ModelStatus.DiagnosticBundle",
                    code: -13,
                    userInfo: [NSLocalizedDescriptionKey: "Refusing to replace a directory at \(dest.path) with a zip file."]
                )
            }
            _ = try FileManager.default.replaceItemAt(
                dest, withItemAt: tmp,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try FileManager.default.moveItem(at: tmp, to: dest)
        }

        // `replaceItemAt` may carry metadata from the prior destination if one
        // existed. Force 0600 again on the final landing path so a previously
        // world-readable file with the same name can't loosen the new archive's
        // perms. Fail loudly if this doesn't take — the privacy guarantee is
        // load-bearing.
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: dest.path
            )
        } catch {
            throw NSError(
                domain: "ModelStatus.DiagnosticBundle",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey:
                    "Couldn't set 0600 permissions on \(dest.path): \(error.localizedDescription)"]
            )
        }
    }

    // MARK: Helpers

    private static func writeText(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw NSError(
                domain: "ModelStatus.DiagnosticBundle",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "could not encode \(url.lastPathComponent) as UTF-8"]
            )
        }
        try data.write(to: url, options: [.atomic])
        // 0600 — only the running user should read these intermediate files.
        // Audit-round-4: fail loudly if chmod doesn't take so a permissions
        // regression can't silently leave staging-dir intermediate text files
        // readable by other local users even though the staging dir itself is
        // 0700.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func timestampForFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func levelTag(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug:    return "DEBUG"
        case .info:     return "INFO "
        case .notice:   return "NOTE "
        case .error:    return "ERROR"
        case .fault:    return "FAULT"
        case .undefined: return "----- "
        @unknown default: return "----- "
        }
    }
}
