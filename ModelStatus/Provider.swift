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
    /// Architect-D53 #45: provider wants Monitor to pre-collect
    /// `localProcessOnPort(port)` and pass it via `CheckRequest`. Without this
    /// flag Monitor skips the lsof+ps shell calls (~ 2 saves per poll for
    /// providers that don't need argv inspection).
    static let needsLocalProcessArgv = ProviderCapabilities(rawValue: 1 << 5)

    // Presets ----------------------------------------------------------------

    static let ollama:   ProviderCapabilities = [.eject, .loadModel, .listAvailable, .reportsVRAM, .reportsGenerating]
    static let lmStudio: ProviderCapabilities = [.eject, .loadModel, .listAvailable]
    static let vllm:     ProviderCapabilities = [.listAvailable, .reportsVRAM]
    static let mlx:      ProviderCapabilities = [.listAvailable, .reportsVRAM, .reportsGenerating, .needsLocalProcessArgv]
    static let openAI:   ProviderCapabilities = [.listAvailable]
}

/// All inputs a `Provider.check(_:)` cycle needs, bundled into one value.
///
/// Audit-round-D6 refactor: the previous 7-parameter `check` signature mixed
/// per-instance fields (`instance`, `session`, `lastActive`) with derived-on-
/// the-spot local metrics (`isLocal`, `localCPU`, `localMemMB`,
/// `localClientProcess`). Bundling them keeps the call site honest and lets a
/// future remote-only provider ignore the local-only fields without changing
/// the protocol every time.
struct CheckRequest: Sendable {
    let instance: Instance
    let session: URLSession
    let isLocal: Bool
    let localCPU: Double?
    let localMemMB: Int?
    let localClientProcess: String?
    let lastActive: Date?
    /// Architect-D53 #45: pre-collected (pid, argv) for the LISTEN-er on the
    /// instance's port. Only populated when the resolved provider declares
    /// `.needsLocalProcessArgv` AND the URL resolves to loopback. MLXProvider
    /// is the sole consumer today; without this hoist it would shell out for
    /// `lsof + ps args=` on every poll inside its own check.
    let localProcessInfo: LocalProcessInfo?
}

/// One implementation per backend type. Stateless — all per-instance state lives in Monitor.
protocol Provider: Sendable {
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }

    func probe(_ instance: Instance, session: URLSession) async -> Bool
    func check(_ request: CheckRequest) async -> ServerStatus
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
    // Order matters for .auto detection: MLX must come BEFORE OpenAI because both
    // accept /v1/models, but MLX has a tighter id-pattern + port-tied process
    // gate that OpenAI's catch-all would shadow if it ran first.
    static let all: [Provider] = [
        OllamaProvider(),
        LMStudioProvider(),
        VLLMProvider(),
        MLXProvider(),
        OpenAIProvider()    // Catch-all last
    ]

    static func provider(for kind: ProviderKind) -> Provider {
        switch kind {
        case .ollama:   return OllamaProvider()
        case .lmStudio: return LMStudioProvider()
        case .vllm:     return VLLMProvider()
        case .mlx:      return MLXProvider()
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
