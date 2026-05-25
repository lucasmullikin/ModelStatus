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
    let clientIP: String?
    let latencyMs: Int?

    var firstModel: String? { loadedModels.first?.name }
}

/// Capability flags — UI gates actions on these.
struct ProviderCapabilities: Sendable {
    let canEject: Bool          // Send "unload" / keep_alive: 0 to free VRAM
    let canLoadModel: Bool      // Preload a model into memory
    let canListAvailable: Bool  // Enumerate downloadable / available models
    let reportsVRAM: Bool       // VRAM reported via API (not just local lsof)
    let reportsGenerating: Bool // Can distinguish "active" vs "generating"

    static let ollama = ProviderCapabilities(
        canEject: true, canLoadModel: true, canListAvailable: true,
        reportsVRAM: true, reportsGenerating: true
    )
    static let openAI = ProviderCapabilities(
        canEject: false, canLoadModel: false, canListAvailable: true,
        reportsVRAM: false, reportsGenerating: false
    )
    static let lmStudio = ProviderCapabilities(
        canEject: true, canLoadModel: true, canListAvailable: true,
        reportsVRAM: false, reportsGenerating: false
    )
    static let vllm = ProviderCapabilities(
        canEject: false, canLoadModel: false, canListAvailable: true,
        reportsVRAM: true, reportsGenerating: false
    )
}

/// One implementation per backend type. Stateless — all per-instance state lives in Monitor.
protocol Provider: Sendable {
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }

    func probe(_ instance: Instance, session: URLSession) async -> Bool
    func check(_ instance: Instance, session: URLSession, isLocal: Bool, localCPU: Double?,
               localMemMB: Int?, localClientIP: String?, lastActive: Date?) async -> ServerStatus
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
        if data.count > maxResponseBytes { throw URLError(.dataLengthExceedsMaximum) }
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
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
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
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
        return h == "127.0.0.1" || h == "localhost" || h == "0.0.0.0"
    }

    static func cpuFor(processKeyword: String) async -> Double? {
        await shellMetricDouble(args: ["-eo", "pcpu,comm"], keyword: processKeyword)
    }

    static func memoryMBFor(processKeyword: String) async -> Int? {
        guard let kb = await shellMetricDouble(args: ["-eo", "rss,comm"], keyword: processKeyword) else { return nil }
        return Int(kb / 1024)
    }

    static func clientIP(port: Int, excludeKeywords: [String] = []) async -> String? {
        guard let output = await runShell("/usr/sbin/lsof", args: ["-i", ":\(port)", "-n", "-P"]) else { return nil }
        for line in output.components(separatedBy: "\n") {
            if excludeKeywords.contains(where: { line.hasPrefix($0) }) { continue }
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
        guard let output = await runShell("/bin/ps", args: args) else { return nil }
        var total: Double = 0
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.lowercased().contains(keyword) else { continue }
            if let val = Double(t.split(whereSeparator: { $0.isWhitespace }).first ?? "") { total += val }
        }
        return total > 0 ? total : nil
    }

    static func runShell(_ path: String, args: [String], timeout: TimeInterval = 5) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let killer = DispatchWorkItem {
                    if proc.isRunning { proc.terminate() }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}
