import Foundation

enum ServerState: Equatable, Sendable {
    case generating, active, idle, unreachable
}

struct LoadedModel: Equatable, Sendable {
    let name: String
    let vramBytes: Int64
    let expiresAt: String?
}

struct ServerStatus: Equatable, Sendable {
    let instance: Instance
    let detectedKind: ProviderKind   // What the probe actually found (may differ from instance.kind if .auto)
    let state: ServerState
    let loadedModels: [LoadedModel]
    let availableModelCount: Int
    let vramTotal: Int64
    let lastActive: Date?
    let cpuPercent: Double?
    let memoryMB: Int?
    let clientProcess: String?       // Process name of who's hitting the local server (e.g. "python", "curl")
    let latencyMs: Int?

    var firstModel: String? { loadedModels.first?.name }
}

/// Capability flags — UI gates actions on these via `caps.contains(.eject)` etc.
///
/// OptionSet rather than struct-of-bools so future capabilities can be added without
/// breaking every static preset's positional initializer. Each new flag is purely additive.
struct ProviderCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let eject              = ProviderCapabilities(rawValue: 1 << 0)
    static let loadModel          = ProviderCapabilities(rawValue: 1 << 1)
    static let listAvailable      = ProviderCapabilities(rawValue: 1 << 2)
    static let reportsVRAM        = ProviderCapabilities(rawValue: 1 << 3)
    static let reportsGenerating  = ProviderCapabilities(rawValue: 1 << 4)

    // Presets ----------------------------------------------------------------

    static let ollama:   ProviderCapabilities = [.eject, .loadModel, .listAvailable, .reportsVRAM, .reportsGenerating]
    static let lmStudio: ProviderCapabilities = [.eject, .loadModel, .listAvailable]
    static let vllm:     ProviderCapabilities = [.listAvailable, .reportsVRAM]
    static let openAI:   ProviderCapabilities = [.listAvailable]
}

/// One implementation per backend type. Stateless — all per-instance state lives in Monitor.
protocol Provider: Sendable {
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }

    func probe(_ instance: Instance, session: URLSession) async -> Bool
    func check(_ instance: Instance, session: URLSession, isLocal: Bool, localCPU: Double?,
               localMemMB: Int?, localClientProcess: String?, lastActive: Date?) async -> ServerStatus
    func ejectModel(_ name: String, on instance: Instance, session: URLSession) async
    func loadModel(_ name: String, on instance: Instance, session: URLSession) async
    func availableModels(_ instance: Instance, session: URLSession) async -> [String]
}

extension Provider {
    func ejectModel(_ name: String, on instance: Instance, session: URLSession) async {}
    func loadModel(_ name: String, on instance: Instance, session: URLSession) async {}
}

/// Registry — order matters: probe stops at first match when .auto.
enum ProviderRegistry {
    static let all: [Provider] = [
        OllamaProvider(),
        LMStudioProvider(),
        VLLMProvider(),
        OpenAIProvider()    // Catch-all last
    ]

    static func provider(for kind: ProviderKind) -> Provider {
        switch kind {
        case .ollama:   return OllamaProvider()
        case .lmStudio: return LMStudioProvider()
        case .vllm:     return VLLMProvider()
        case .openAI:   return OpenAIProvider()
        case .auto:     return OpenAIProvider()  // Fallback when probe finds nothing
        }
    }

    /// Probe-based auto-detect. Returns the first provider whose probe succeeds, or nil.
    static func detect(_ instance: Instance, session: URLSession) async -> Provider? {
        for p in all {
            if await p.probe(instance, session: session) { return p }
        }
        return nil
    }
}

/// Shared helpers for HTTP fetches with auth header injection + response size cap.
enum HTTPHelpers {
    static let maxResponseBytes = 4 * 1024 * 1024

    static func get(_ url: URL, instanceID: UUID, session: URLSession,
                    timeout: TimeInterval = 5) async throws -> (Data, HTTPURLResponse, Int) {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        if let h = Keychain.authHeader(for: instanceID), !h.isEmpty {
            req.setValue(h, forHTTPHeaderField: "Authorization")
        }
        let start = Date()
        let (data, resp) = try await session.data(for: req)
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // Pre-check Content-Length when present (cheaper than full download).
        if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
           let len = Int(lenStr), len > maxResponseBytes {
            throw URLError(.dataLengthExceedsMaximum)
        }
        // Post-check actual byte count (some servers omit Content-Length).
        if data.count > maxResponseBytes { throw URLError(.dataLengthExceedsMaximum) }
        return (data, http, latency)
    }

    static func post(_ url: URL, body: [String: Any], instanceID: UUID,
                     session: URLSession, timeout: TimeInterval = 10) async throws -> HTTPURLResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let h = Keychain.authHeader(for: instanceID), !h.isEmpty {
            req.setValue(h, forHTTPHeaderField: "Authorization")
        }
        // Propagate JSON serialization failures rather than silently sending no body.
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = timeout
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http
    }
}

/// Local process probing — shared by all providers when the instance host is loopback.
enum LocalProbe {
    static func isLocal(_ url: String) -> Bool {
        guard let h = URL(string: url)?.host else { return false }
        return h == "127.0.0.1" || h == "localhost" || h == "0.0.0.0" || h == "::1"
    }

    static func cpuFor(processKeyword: String) async -> Double? {
        await shellMetricDouble(args: ["-eo", "pcpu,comm"], keyword: processKeyword)
    }

    static func memoryMBFor(processKeyword: String) async -> Int? {
        guard let kb = await shellMetricDouble(args: ["-eo", "rss,comm"], keyword: processKeyword) else { return nil }
        return Int(kb / 1024)
    }

    /// Return the process name of whoever is currently talking to a local server on `port`.
    /// Despite the surface meaning of "client", returning the IP would always be 127.0.0.1
    /// for loopback connections — the process name (e.g. "python", "curl", "Claude") is the
    /// useful identifier. Skips own-process lines (Ollama, ModelStatus).
    static func clientProcess(port: Int, excludeKeywords: [String] = []) async -> String? {
        guard let output = await runShell("/usr/sbin/lsof", args: ["-i", ":\(port)", "-n", "-P"]) else { return nil }
        for line in output.components(separatedBy: "\n") {
            if excludeKeywords.contains(where: { line.hasPrefix($0) }) { continue }
            if line.hasPrefix("ollama") { continue }
            if line.contains("OllamaSta") || line.contains("ModelStat") { continue }
            if line.contains("ESTABLISHED"), line.contains("->"), line.contains(":\(port)"),
               let proc = line.split(whereSeparator: { $0.isWhitespace }).first {
                return String(proc)
            }
        }
        return nil
    }

    static func establishedConnectionPresent(port: Int, excludingPids: Set<Int>) async -> Bool {
        let myPid = Int(ProcessInfo.processInfo.processIdentifier)
        guard let out = await runShell("/usr/sbin/lsof",
                                       args: ["-i", "TCP:\(port)", "-s", "TCP:ESTABLISHED", "-t"]) else { return false }
        let pids = Set(out.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        return !pids.subtracting(excludingPids.union([myPid])).isEmpty
    }

    static func pidsFor(processName: String) async -> Set<Int> {
        guard let out = await runShell("/usr/bin/pgrep", args: ["-x", processName]) else { return [] }
        return Set(out.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    private static func shellMetricDouble(args: [String], keyword: String) async -> Double? {
        guard !keyword.isEmpty else { return nil }   // Never match-all
        let needle = keyword.lowercased()
        guard let output = await runShell("/bin/ps", args: args) else { return nil }
        var total: Double = 0
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.lowercased().contains(needle) else { continue }
            if let val = Double(t.split(whereSeparator: { $0.isWhitespace }).first ?? "") { total += val }
        }
        return total > 0 ? total : nil
    }

    /// Hardened (v0.2 D-revised): streams stdout via `readabilityHandler` instead of the
    /// blocking `readDataToEndOfFile`, and escalates SIGTERM → SIGKILL on a two-stage
    /// deadline. A single-fire latch ensures the continuation resumes exactly once even
    /// when multiple resolution paths race.
    ///
    /// Scope-down note (per v0.2 security blocker B3): we kill the immediate child only,
    /// not the process group. Every caller in ModelStatus invokes a known binary with
    /// explicit argv (`/bin/ps`, `/usr/sbin/lsof`, `/usr/bin/pgrep`, `/usr/bin/open`,
    /// `/usr/bin/pkill`, `/opt/homebrew/bin/brew`). None of these fork grandchildren that
    /// outlive SIGKILL. If a future call site needs `/bin/sh -c`, add process-group kill
    /// via `posix_spawn` + `POSIX_SPAWN_SETPGROUP` first.
    static func runShell(_ path: String, args: [String], timeout: TimeInterval = 5) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            // Mutable state lives in a reference type so closures that fire on
            // arbitrary GCD threads (readabilityHandler, terminationHandler, kill
            // timers) can share it without Sendable copy semantics. Access is
            // serialized through `sync` — the @unchecked annotation is honest.
            final class State: @unchecked Sendable {
                var buffer = Data()
                var resumed = false
            }
            let state = State()
            let sync = DispatchQueue(label: "modelstatus.runshell.sync")
            let readFH = pipe.fileHandleForReading

            readFH.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    // Writer side closed → no more data coming. Detach the handler so
                    // GCD stops dispatching. terminationHandler will resume the continuation.
                    fh.readabilityHandler = nil
                    return
                }
                sync.sync { state.buffer.append(chunk) }
            }

            // Single-fire finalizer. Called from terminationHandler, the SIGKILL
            // backstop, or — if the kernel somehow doesn't reap — a fallback timer.
            let tryFinish: @Sendable () -> Void = {
                let shouldResume = sync.sync { () -> Bool in
                    if state.resumed { return false }
                    state.resumed = true
                    return true
                }
                guard shouldResume else { return }
                readFH.readabilityHandler = nil
                let final: Data = sync.sync { state.buffer }
                try? readFH.close()
                continuation.resume(returning: String(data: final, encoding: .utf8))
            }

            proc.terminationHandler = { _ in tryFinish() }

            do {
                try proc.run()
            } catch {
                readFH.readabilityHandler = nil
                try? readFH.close()
                continuation.resume(returning: nil)
                return
            }

            // Two-stage kill on the immediate child. Kernel reaps on SIGKILL,
            // which fires terminationHandler → tryFinish(). The backstop timer
            // at +3s catches the (extremely rare) case where neither signal lands.
            let killQueue = DispatchQueue.global(qos: .utility)
            killQueue.asyncAfter(deadline: .now() + timeout) {
                if proc.isRunning { proc.terminate() }   // SIGTERM
            }
            killQueue.asyncAfter(deadline: .now() + timeout + 2.0) {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
            killQueue.asyncAfter(deadline: .now() + timeout + 3.0) {
                tryFinish()    // backstop — never leak the continuation
            }
        }
    }
}
