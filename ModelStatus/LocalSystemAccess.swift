import Foundation
import os.log

/// Audit-round-D46: emit a release-visible log line if the App Store target
/// ever forgets to call `LocalSystemAccessProvider.configure(_:)` before the
/// first read. DEBUG builds also assert; RELEASE builds need OSLog so the
/// fault is visible in Console.app and the exported diagnostic bundle.
private let localSystemAccessLogger = Logger(subsystem: ConfigManager.bundleIdentifier,
                                             category: "local-system-access")

/// Abstraction over local-system inspection (`lsof` / `ps` / `pgrep` / shell
/// execution + loopback detection).
///
/// **Why this exists:** the direct download build is unsandboxed and can call
/// these freely. The future Mac App Store build will be sandboxed and CANNOT
/// invoke them — `Process` with absolute paths to `/usr/sbin/lsof` etc. will
/// fail. By routing all local-system calls through this protocol, the App
/// Store target can ship a `SandboxedLocalSystemAccess` that returns nil for
/// everything, and the rest of the codebase keeps compiling and running with
/// gracefully-degraded telemetry (no client-process display, no CPU/RSS, no
/// Tailscale discovery, etc.).
///
/// **Scope today (D53-architect):** the protocol is wired through the
/// hottest call sites — `Monitor.check` (the inner poll loop:
/// isLocal/cpu/mem/clientProcess), `Monitor.isLocalOllamaRunning`,
/// `Monitor.toggleLocalOllama` (brew/open/pkill), and
/// `Discovery.scanTailscalePeers` (Tailscale binary exec). Lower-traffic
/// sites in `DiagnosticBundle.swift` (sw_vers/sysctl/ps for the bundle
/// payload) still call `LocalProbe` directly — they're invoked only on
/// user-requested diagnostic export, never during automatic polling. A
/// sandboxed App Store target that injects `SandboxedLocalSystemAccess`
/// today gets correct fail-closed behavior for the poll path and would only
/// be missing diagnostic-bundle output until those sites migrate too.
protocol LocalSystemAccess: Sendable {
    func isLocal(_ url: String) -> Bool
    func cpuFor(processKeyword: String) async -> Double?
    func memoryMBFor(processKeyword: String) async -> Int?
    func clientProcess(port: Int, excludeKeywords: [String]) async -> String?
    func establishedConnectionPresent(port: Int, excludingPids: Set<Int>) async -> Bool
    func pidsFor(processName: String) async -> Set<Int>
    func localProcessOnPort(_ port: Int) async -> LocalProcessInfo?
    func runShell(_ path: String, args: [String], timeout: TimeInterval) async -> String?
}

/// Production implementation. Forwards to the existing `LocalProbe` enum so
/// behavior is identical to pre-protocol code.
struct DirectLocalSystemAccess: LocalSystemAccess {
    func isLocal(_ url: String) -> Bool {
        LocalProbe.isLocal(url)
    }
    func cpuFor(processKeyword: String) async -> Double? {
        await LocalProbe.cpuFor(processKeyword: processKeyword)
    }
    func memoryMBFor(processKeyword: String) async -> Int? {
        await LocalProbe.memoryMBFor(processKeyword: processKeyword)
    }
    func clientProcess(port: Int, excludeKeywords: [String]) async -> String? {
        await LocalProbe.clientProcess(port: port, excludeKeywords: excludeKeywords)
    }
    func establishedConnectionPresent(port: Int, excludingPids: Set<Int>) async -> Bool {
        await LocalProbe.establishedConnectionPresent(port: port, excludingPids: excludingPids)
    }
    func pidsFor(processName: String) async -> Set<Int> {
        await LocalProbe.pidsFor(processName: processName)
    }
    func localProcessOnPort(_ port: Int) async -> LocalProcessInfo? {
        await LocalProbe.localProcessOnPort(port)
    }
    func runShell(_ path: String, args: [String], timeout: TimeInterval) async -> String? {
        await Shell.run(path, args: args, timeout: timeout)
    }
}

/// Sandboxed stub. Returns nil/false for every call. The App Store target
/// will inject this in place of `DirectLocalSystemAccess`. Polling will still
/// work (HTTP-only), but client-process, CPU/RSS, brew control, MLX argv,
/// Tailscale discovery, and any other `lsof`/`ps`-derived data become
/// unavailable — which is the correct behavior under the sandbox.
struct SandboxedLocalSystemAccess: LocalSystemAccess {
    func isLocal(_ url: String) -> Bool {
        // Loopback detection is pure URL parsing, no syscalls — safe under sandbox.
        LocalProbe.isLocal(url)
    }
    func cpuFor(processKeyword: String) async -> Double? { nil }
    func memoryMBFor(processKeyword: String) async -> Int? { nil }
    func clientProcess(port: Int, excludeKeywords: [String]) async -> String? { nil }
    func establishedConnectionPresent(port: Int, excludingPids: Set<Int>) async -> Bool { false }
    func pidsFor(processName: String) async -> Set<Int> { [] }
    func localProcessOnPort(_ port: Int) async -> LocalProcessInfo? { nil }
    func runShell(_ path: String, args: [String], timeout: TimeInterval) async -> String? { nil }
}

/// Global injection point. Configure ONCE at app launch via
/// `LocalSystemAccessProvider.configure(_:)` BEFORE the first Monitor poll
/// fires. Defaults to `DirectLocalSystemAccess`. The App Store target's
/// `main.swift` would call `.configure(SandboxedLocalSystemAccess())`.
///
/// Audit-round-D7: NSLock-protected reads/writes + single-assignment via
/// `configure(_:)`. The earlier `nonisolated(unsafe)` global was a race
/// surface. Reads are still cheap (one lock acquisition) and happen at most
/// once per poll.
enum LocalSystemAccessProvider {
    private static let lock = NSLock()

    /// Audit-round-D47: compile-time default. The App Store target builds
    /// with `-DMODELSTATUS_APP_STORE` and gets `SandboxedLocalSystemAccess`
    /// as the fail-closed default. Direct downloads default to
    /// `DirectLocalSystemAccess`. Either target can still override via
    /// `configure(_:)` for testing, but a missed runtime configure can no
    /// longer let a sandboxed target accidentally execute `Process` / `lsof`.
    #if MODELSTATUS_APP_STORE
    private static var _current: LocalSystemAccess = SandboxedLocalSystemAccess()
    #else
    private static var _current: LocalSystemAccess = DirectLocalSystemAccess()
    #endif
    private static var _configured = false
    private static var _accessed = false

    /// Audit-round-D46: track first-access so an App Store target that
    /// forgets to call `configure(.sandboxed)` BEFORE the first read can be
    /// detected immediately. We can't fail closed in production without a
    /// hard-coded compile-time policy (the protocol abstraction is shared
    /// between direct and sandboxed targets), but in DEBUG we assert so the
    /// bug is loud during development. In release we log to OSLog so the
    /// diagnostic bundle captures it.
    static var current: LocalSystemAccess {
        lock.lock(); defer { lock.unlock() }
        if !_accessed {
            _accessed = true
            // Audit-round-D49: only the App Store / sandboxed target treats
            // a missing `configure(_:)` call as a misconfiguration worth
            // surfacing. Direct downloads intentionally default to
            // `DirectLocalSystemAccess` without explicit configuration and
            // shouldn't trip the DEBUG assert or fire an OSLog fault.
            if !_configured {
                #if MODELSTATUS_APP_STORE
                #if DEBUG
                assertionFailure(
                    "LocalSystemAccessProvider.current read before configure(_:). "
                  + "App Store target must call configure(SandboxedLocalSystemAccess()) "
                  + "from main() before the first Monitor poll."
                )
                #else
                localSystemAccessLogger.fault(
                    "LocalSystemAccessProvider.current read before configure(_:). Sandboxed default is in use; App Store target should call configure(SandboxedLocalSystemAccess()) from main() before the first poll."
                )
                #endif
                #endif
            }
        }
        return _current
    }

    /// Set the provider exactly once. Subsequent calls are no-ops (returns
    /// false). The App Store target should call this from `main()` before
    /// constructing `Monitor`. Audit-round-D46: configure() AFTER first read
    /// is rejected — switching access kind mid-flight would create
    /// inconsistent behavior across early and later polls.
    @discardableResult
    static func configure(_ provider: LocalSystemAccess) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_configured, !_accessed else { return false }
        _current = provider
        _configured = true
        return true
    }
}
