import Foundation

/// Headless command-line interface for ModelStatus.
///
/// `ModelStatus status [--json]` runs a single poll cycle through the real
/// `Monitor` + `ConfigManager`, prints each configured server's state, and
/// exits — no menu bar, no GUI. Lets the app be scripted and integration-tested
/// without screenshots.
///
/// Parsing/rendering are pure functions (tested in StatusCLITests). The
/// network-touching `run` reuses production code and is verified manually /
/// in integration.
enum StatusCLI {

    enum Command: Equatable {
        case status(json: Bool)
        case help
        case gui   // No CLI subcommand — fall through to normal app launch.
    }

    /// Stable machine-readable state strings. Deliberately NOT derived from
    /// `String(describing:)` so a future enum rename can't silently break
    /// downstream scripts.
    static func stateLabel(_ s: ServerState) -> String {
        switch s {
        case .generating:  return "generating"
        case .active:      return "active"
        case .idle:        return "idle"
        case .unreachable: return "unreachable"
        }
    }

    static func parse(_ argv: [String]) -> Command {
        // argv[0] is the executable path. Only treat a leading `status` token
        // as a CLI invocation; anything else (including the macOS-injected
        // -NS* debug flags) is normal GUI launch.
        let args = Array(argv.dropFirst())
        guard let first = args.first else { return .gui }
        switch first {
        case "status":
            let json = args.dropFirst().contains("--json")
            return .status(json: json)
        case "--help", "-h", "help":
            return .help
        default:
            return .gui
        }
    }

    // MARK: - rendering

    static func renderText(_ statuses: [ServerStatus]) -> String {
        guard !statuses.isEmpty else {
            return "No servers configured. Add one in Settings… or the app's menu."
        }
        return statuses.map { s -> String in
            var parts = ["\(stateLabel(s.state).padding(toLength: 11, withPad: " ", startingAt: 0)) \(s.instance.name)"]
            parts.append("(\(s.detectedKind.displayName))")
            if let first = s.loadedModels.first {
                var m = first.name
                if s.loadedModels.count > 1 { m += " +\(s.loadedModels.count - 1)" }
                parts.append("· \(m)")
            }
            if s.vramTotal > 0 { parts.append("· \(Formatters.bytes(s.vramTotal))") }
            if s.availableModelCount > 0 { parts.append("· \(s.availableModelCount) available") }
            if let lat = s.latencyMs { parts.append("· \(lat)ms") }
            return parts.joined(separator: " ")
        }.joined(separator: "\n")
    }

    static func renderJSON(_ statuses: [ServerStatus]) -> String {
        let rows: [[String: Any]] = statuses.map { s in
            [
                "name": s.instance.name,
                "url": s.instance.url,
                "configuredKind": s.instance.kind.rawValue,
                "detectedKind": s.detectedKind.rawValue,
                "state": stateLabel(s.state),
                "loadedModels": s.loadedModels.map { m -> [String: Any] in
                    [
                        "name": m.name,
                        "vramBytes": m.vramBytes,
                        // expiresAt is String? in this codebase; explicit NSNull
                        // avoids relying on Optional→null bridging in JSONSerialization.
                        "expiresAt": m.expiresAt ?? NSNull()
                    ]
                },
                "availableModelCount": s.availableModelCount,
                "vramTotalBytes": s.vramTotal,
                // Non-finite Doubles (NaN/Inf) make JSONSerialization throw, so
                // a stray value can't collapse the whole output — clamp to null.
                "cpuPercent": finiteOrNull(s.cpuPercent),
                "memoryMB": s.memoryMB ?? NSNull(),
                "clientProcess": s.clientProcess ?? NSNull(),
                "latencyMs": s.latencyMs ?? NSNull()
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: rows,
            options: [.prettyPrinted, .sortedKeys]
        ), let str = String(data: data, encoding: .utf8) else {
            // Unreachable in practice: every value above is a JSON-safe
            // primitive (String/Int/Int64/Bool/NSNull) — finiteOrNull already
            // strips the only throwing case (non-finite Double). Kept as
            // defense-in-depth, and an explicit error object rather than "[]"
            // so a failure could never be mistaken for "no servers configured".
            return "{\"error\":\"failed to encode status as JSON\"}"
        }
        return str
    }

    private static func finiteOrNull(_ d: Double?) -> Any {
        guard let d, d.isFinite else { return NSNull() }
        return d
    }

    static func helpText() -> String {
        """
        ModelStatus — local AI server monitor

        USAGE:
          ModelStatus                  Launch the menu bar app (default)
          ModelStatus status           Print one poll cycle of all servers (text)
          ModelStatus status --json    Same, as JSON for scripting
          ModelStatus --help           Show this help

        The status command reads your configured servers, polls each once,
        prints the result, and exits. It shares the same config the app uses.
        """
    }

    // MARK: - headless run

    /// Runs a single poll cycle and prints the result. Returns the process
    /// exit code: 0 on success (including an empty server list), 1 on timeout.
    /// `run` reuses the real Monitor — the one poll, single source of truth.
    ///
    /// The 15s ceiling relies on the poll child being cancellation-aware: the
    /// `for await` on `statusEvents` (an AsyncStream) resumes with nil when the
    /// task group is cancelled, and `startPolling()` returns synchronously
    /// (it only spawns an internal Task). Both hold today, so the group scope
    /// can always exit after the sleep branch wins — empirically confirmed when
    /// a keychain stall on the unsigned dev binary tripped the timeout cleanly.
    @MainActor
    static func run(json: Bool) async -> Int32 {
        let monitor = Monitor()
        // Subscribe BEFORE polling so we don't miss the first (only) emission.
        let stream = monitor.statusEvents

        // Race the entire poll path (startPolling + awaiting the first event)
        // against a 15s sleep so nothing — DNS stall, slow start, hung server —
        // can wedge the CLI. startPolling lives INSIDE the raced task so the
        // ceiling structurally covers it too, even if it ever gains an await.
        //
        // A real poll ALWAYS yields its [ServerStatus] array (even empty when
        // no servers are configured), so `nil` here means either the sleep
        // branch won (timeout) OR the stream finished without emitting — both
        // are non-success "didn't get a poll result" outcomes, reported
        // identically as exit 1. That keeps "no servers" (empty array, exit 0)
        // distinct from "no result" (error, exit 1).
        let result: [ServerStatus]? = await withTaskGroup(of: [ServerStatus]?.self) { group in
            group.addTask {
                await monitor.startPolling()
                for await s in stream { return s }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s ceiling
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await monitor.stopPolling()

        guard let statuses = result else {
            // Timeout: surface it explicitly with a non-zero exit so scripts
            // never mistake a hung poll for an empty server list.
            let msg = "timed out after 15s waiting for the first poll cycle"
            print(json ? "{\"error\":\"\(msg)\"}" : "error: \(msg)")
            return 1
        }

        print(json ? renderJSON(statuses) : renderText(statuses))
        return 0
    }
}
