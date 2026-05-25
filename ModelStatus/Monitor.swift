import Foundation
import OSLog

private let logger = Logger(subsystem: ConfigManager.bundleIdentifier, category: "monitor")

/// Per-instance memo state, consolidated from 5 separate dicts in pre-v0.2.
/// Codable so v0.3+ can persist across launches to avoid the "Checking…" flash on cold start.
struct InstanceState: Sendable, Codable {
    var lastActive: Date?
    var lastClient: String?
    var lastReachable: Bool?
    var lastExpiresAt: String?
    var detectedKind: ProviderKind?
}

/// Orchestrates polling. One actor for the whole app — owns per-instance memo state
/// and dispatches each check to the appropriate Provider.
actor Monitor {
    private var pollTask: Task<Void, Never>?
    private var state: [UUID: InstanceState] = [:]

    typealias StatusCallback = @Sendable ([ServerStatus]) -> Void
    typealias ReachabilityCallback = @Sendable (Instance, Bool) -> Void
    private var onStatusChange: StatusCallback?
    private var onReachabilityChange: ReachabilityCallback?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 10
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func startPolling(onStatusChange: @escaping StatusCallback,
                      onReachabilityChange: @escaping ReachabilityCallback = { _, _ in }) {
        self.onStatusChange = onStatusChange
        self.onReachabilityChange = onReachabilityChange
        state = [:]
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await self.poll()
                let raw = ConfigManager.shared.pollInterval
                // Clamp: 1s lower bound, 600s upper bound, NaN/inf → 5s default
                let safe: TimeInterval = raw.isFinite ? max(1, min(600, raw)) : 5
                try? await Task.sleep(nanoseconds: UInt64(safe * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        onStatusChange = nil
        onReachabilityChange = nil
    }

    private func poll() async {
        let instances = ConfigManager.shared.instances
        let statuses = await withTaskGroup(of: ServerStatus.self) { group in
            for inst in instances { group.addTask { await self.check(inst) } }
            var r: [ServerStatus] = []
            for await s in group { r.append(s) }
            return r
        }
        var map: [UUID: ServerStatus] = [:]
        for s in statuses { map[s.instance.id] = s }
        let ordered = instances.compactMap { map[$0.id] }

        for s in ordered {
            let reachable = s.state != .unreachable
            if state[s.instance.id]?.lastReachable != reachable {
                state[s.instance.id, default: InstanceState()].lastReachable = reachable
                onReachabilityChange?(s.instance, reachable)
            }
        }

        onStatusChange?(ordered)
    }

    private func check(_ instance: Instance) async -> ServerStatus {
        let provider = await resolveProvider(for: instance)
        let isLocal = LocalProbe.isLocal(instance.url)
        let port = URL(string: instance.url)?.port ?? defaultPort(for: provider.kind)

        let keyword = processKeyword(for: provider.kind)
        async let cpu: Double? = (isLocal && !keyword.isEmpty) ? LocalProbe.cpuFor(processKeyword: keyword) : nil
        async let memMB: Int? = (isLocal && !keyword.isEmpty) ? LocalProbe.memoryMBFor(processKeyword: keyword) : nil
        async let client: String? = isLocal ? LocalProbe.clientProcess(port: port) : nil

        let localCPU = await cpu
        let localMem = await memMB
        if let c = await client { state[instance.id, default: InstanceState()].lastClient = c }
        let clientProcess = state[instance.id]?.lastClient

        var status = await provider.check(
            instance, session: session, isLocal: isLocal,
            localCPU: localCPU, localMemMB: localMem, localClientProcess: clientProcess,
            lastActive: state[instance.id]?.lastActive
        )

        // Remote Ollama Generating detection: when Ollama bumps expires_at between polls
        // (because inference reset the keep_alive timer), elevate .active → .generating.
        // Doesn't fire if keep_alive=-1 since the timestamp never bumps. Honest fallback.
        if status.state == .active, status.detectedKind == .ollama,
           let exp = status.loadedModels.first?.expiresAt {
            let prev = state[instance.id]?.lastExpiresAt
            state[instance.id, default: InstanceState()].lastExpiresAt = exp
            if let prev, prev != exp {
                status = ServerStatus(
                    instance: status.instance, detectedKind: status.detectedKind, state: .generating,
                    loadedModels: status.loadedModels, availableModelCount: status.availableModelCount,
                    vramTotal: status.vramTotal, lastActive: status.lastActive,
                    cpuPercent: status.cpuPercent, memoryMB: status.memoryMB,
                    clientProcess: status.clientProcess, latencyMs: status.latencyMs
                )
            }
        }

        // Track last-active when a new active/generating state appears
        if status.state == .active || status.state == .generating {
            state[instance.id, default: InstanceState()].lastActive = Date()
        }

        // If user picked .auto and we resolved a specific kind, record it for later use
        if instance.kind == .auto && status.state != .unreachable {
            state[instance.id, default: InstanceState()].detectedKind = status.detectedKind
        }

        // Re-emit lastActive in the status if we have a memoized one
        if status.lastActive == nil, let t = state[instance.id]?.lastActive {
            status = ServerStatus(
                instance: status.instance, detectedKind: status.detectedKind, state: status.state,
                loadedModels: status.loadedModels, availableModelCount: status.availableModelCount,
                vramTotal: status.vramTotal, lastActive: t,
                cpuPercent: status.cpuPercent, memoryMB: status.memoryMB,
                clientProcess: status.clientProcess, latencyMs: status.latencyMs
            )
        }
        return status
    }

    private func resolveProvider(for instance: Instance) async -> Provider {
        if instance.kind != .auto {
            return ProviderRegistry.provider(for: instance.kind)
        }
        if let detected = state[instance.id]?.detectedKind {
            return ProviderRegistry.provider(for: detected)
        }
        if let p = await ProviderRegistry.detect(instance, session: session) {
            state[instance.id, default: InstanceState()].detectedKind = p.kind
            return p
        }
        // Fallback: try OpenAI generic so we at least report unreachable cleanly
        return OpenAIProvider()
    }

    private func defaultPort(for kind: ProviderKind) -> Int {
        switch kind {
        case .ollama:                 return 11434
        case .lmStudio:               return 1234
        case .vllm:                   return 8000
        case .openAI, .auto:          return 8080
        }
    }

    private func processKeyword(for kind: ProviderKind) -> String {
        switch kind {
        case .ollama:                 return "ollama"
        case .lmStudio:               return "lmstudio"
        case .vllm:                   return "vllm"
        case .openAI, .auto:          return ""    // No process binding for generic
        }
    }

    // MARK: - Per-instance actions (eject / load) dispatched to the right provider

    func ejectModel(name: String, on instance: Instance) async {
        let provider = await resolveProvider(for: instance)
        guard provider.capabilities.contains(.eject) else {
            logger.notice("eject not supported by provider \(String(describing: provider.kind), privacy: .public)")
            return
        }
        await provider.ejectModel(name, on: instance, session: session)
    }

    func loadModel(name: String, on instance: Instance) async {
        let provider = await resolveProvider(for: instance)
        guard provider.capabilities.contains(.loadModel) else { return }
        await provider.loadModel(name, on: instance, session: session)
    }

    func availableModels(for instance: Instance) async -> [String] {
        let provider = await resolveProvider(for: instance)
        return await provider.availableModels(instance, session: session)
    }

    func capabilities(for instance: Instance) async -> ProviderCapabilities {
        await resolveProvider(for: instance).capabilities
    }

    func detectedKind(for instance: Instance) async -> ProviderKind {
        if instance.kind != .auto { return instance.kind }
        return state[instance.id]?.detectedKind ?? .openAI
    }

    // MARK: - Local Ollama control (kept for the menu's start/stop button)

    static func isLocalOllamaRunning() async -> Bool {
        guard let output = await LocalProbe.runShell("/bin/ps", args: ["-axo", "comm"]) else { return false }
        return output.split(separator: "\n").contains {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasSuffix("/ollama") || t == "ollama"
        }
    }

    static func toggleLocalOllama(start: Bool) async {
        let brewPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            ? "/opt/homebrew/bin/brew"
            : (FileManager.default.fileExists(atPath: "/usr/local/bin/brew") ? "/usr/local/bin/brew" : nil)

        if let brew = brewPath {
            _ = await LocalProbe.runShell(brew, args: ["services", start ? "start" : "stop", "ollama"])
            if await isLocalOllamaRunning() == start { return }
        }

        if start {
            let appPath = "/Applications/Ollama.app"
            if FileManager.default.fileExists(atPath: appPath) {
                _ = await LocalProbe.runShell("/usr/bin/open", args: ["-g", appPath])
            }
        } else {
            _ = await LocalProbe.runShell("/usr/bin/pkill", args: ["-x", "ollama"])
        }
    }
}
