import Foundation

enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case auto      // Auto-detect on first probe
    case ollama
    case openAI    // Generic OpenAI-compatible (/v1/models)
    case lmStudio  // LM Studio (/api/v0/models, supports unload)
    case vllm      // vLLM (adds /metrics for telemetry)

    var displayName: String {
        switch self {
        case .auto:     return "Auto-detect"
        case .ollama:   return "Ollama"
        case .openAI:   return "OpenAI-compatible"
        case .lmStudio: return "LM Studio"
        case .vllm:     return "vLLM"
        }
    }
}

struct Instance: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var url: String
    var kind: ProviderKind

    init(id: UUID = UUID(), name: String, url: String, kind: ProviderKind = .auto) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, name, url, kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.url = try c.decode(String.self, forKey: .url)
        self.kind = (try? c.decodeIfPresent(ProviderKind.self, forKey: .kind)) ?? .ollama
    }
}

struct AppConfig: Codable {
    var instances: [Instance]
    var pollInterval: TimeInterval
    var notifyOnStateChange: Bool
    var compactMode: Bool
    var verboseLogging: Bool

    static let `default` = AppConfig(
        instances: [Instance(name: "Local", url: "http://127.0.0.1:11434", kind: .ollama)],
        pollInterval: 5.0,
        notifyOnStateChange: false,
        compactMode: false,
        verboseLogging: false
    )

    enum CodingKeys: String, CodingKey {
        case instances, pollInterval, notifyOnStateChange, compactMode, verboseLogging
    }

    init(instances: [Instance], pollInterval: TimeInterval,
         notifyOnStateChange: Bool, compactMode: Bool, verboseLogging: Bool = false) {
        self.instances = instances
        self.pollInterval = pollInterval
        self.notifyOnStateChange = notifyOnStateChange
        self.compactMode = compactMode
        self.verboseLogging = verboseLogging
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.instances = try c.decode([Instance].self, forKey: .instances)
        self.pollInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .pollInterval) ?? 5.0
        self.notifyOnStateChange = try c.decodeIfPresent(Bool.self, forKey: .notifyOnStateChange) ?? false
        self.compactMode = try c.decodeIfPresent(Bool.self, forKey: .compactMode) ?? false
        self.verboseLogging = try c.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? false
    }
}

/// Per-poll-cycle snapshot of config + cycle metadata. Built once at the top of
/// `Monitor.poll()` (eventually via `MainActor.run` once ConfigManager is @MainActor)
/// and used in lieu of direct `ConfigManager.shared.X` reads from actor contexts.
///
/// Threaded through Monitor only today; the diagnostics pass (E) will extend this
/// to Provider.probe/check so the per-provider `verbose()` helper can read
/// `ctx.verbose` without crossing actor boundaries.
struct PollContext: Sendable {
    let verbose: Bool
    let pollInterval: TimeInterval
    let instances: [Instance]
    let timestamp: Date
}

enum PollInterval: TimeInterval, CaseIterable, Sendable {
    case fast = 2, normal = 5, slow = 10, lazy = 30, idle = 60, sleepy = 180

    var label: String {
        switch self {
        case .fast:   return "2s"
        case .normal: return "5s"
        case .slow:   return "10s"
        case .lazy:   return "30s"
        case .idle:   return "1m"
        case .sleepy: return "3m"
        }
    }

    static func closest(to value: TimeInterval) -> PollInterval {
        Self.allCases.min(by: { abs($0.rawValue - value) < abs($1.rawValue - value) }) ?? .normal
    }
}

@MainActor
final class ConfigManager {
    static let shared = ConfigManager()

    // Static constants are immutable and safe to read from any isolation domain.
    // Marking nonisolated makes that explicit so Logger(subsystem:) etc. stay synchronous.
    nonisolated static let bundleIdentifier = "com.lucrativepictures.ModelStatus"
    nonisolated private static let legacyBundleIdentifiers = [
        "com.lucrativepictures.OllamaStatus",
        "com.local.ollamastatus"
    ]

    private let configURL: URL
    private var _config: AppConfig

    var config: AppConfig {
        get { _config }
        set { _config = newValue; save() }
    }

    var instances: [Instance] {
        get { _config.instances }
        set { _config.instances = newValue; save() }
    }

    var pollInterval: TimeInterval {
        get { _config.pollInterval }
        set { _config.pollInterval = newValue; save() }
    }

    var notifyOnStateChange: Bool {
        get { _config.notifyOnStateChange }
        set { _config.notifyOnStateChange = newValue; save() }
    }

    var compactMode: Bool {
        get { _config.compactMode }
        set { _config.compactMode = newValue; save() }
    }

    var verboseLogging: Bool {
        get { _config.verboseLogging }
        set { _config.verboseLogging = newValue; save() }
    }

    /// Snapshot reader used by `Monitor.poll()` to capture config in a single hop.
    /// After v0.2 step B this becomes the only legal way to read config from non-MainActor contexts.
    func snapshotForPoll() -> PollContext {
        PollContext(
            verbose: _config.verboseLogging,
            pollInterval: _config.pollInterval,
            instances: _config.instances,
            timestamp: Date()
        )
    }

    private init() {
        let prefsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        configURL = prefsDir.appendingPathComponent("\(Self.bundleIdentifier).json")

        if let migrated = Self.loadWithMigration(target: configURL, in: prefsDir) {
            _config = migrated
        } else {
            _config = .default
        }
        save()
    }

    nonisolated private static func loadWithMigration(target: URL, in prefsDir: URL) -> AppConfig? {
        if let cfg = load(from: target) { return cfg }
        for legacy in legacyBundleIdentifiers {
            let legacyURL = prefsDir.appendingPathComponent("\(legacy).json")
            if let cfg = load(from: legacyURL) { return cfg }
        }
        return nil
    }

    nonisolated private static func load(from url: URL) -> AppConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(_config) else { return }
        try? data.write(to: configURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    @discardableResult
    func addInstance(name: String, url: String, kind: ProviderKind = .auto, authHeader: String? = nil) -> Instance {
        let inst = Instance(name: name, url: url, kind: kind)
        _config.instances.append(inst)
        save()
        if let authHeader, !authHeader.isEmpty {
            Keychain.setAuthHeader(authHeader, for: inst.id)
        }
        return inst
    }

    func removeInstance(at index: Int) {
        guard index >= 0 && index < _config.instances.count else { return }
        let id = _config.instances[index].id
        _config.instances.remove(at: index)
        Keychain.setAuthHeader(nil, for: id)
        save()
    }

    func removeInstance(id: UUID) {
        _config.instances.removeAll { $0.id == id }
        Keychain.setAuthHeader(nil, for: id)
        save()
    }

    func updateInstance(id: UUID, name: String? = nil, url: String? = nil, kind: ProviderKind? = nil) {
        guard let i = _config.instances.firstIndex(where: { $0.id == id }) else { return }
        if let name { _config.instances[i].name = name }
        if let url { _config.instances[i].url = url }
        if let kind { _config.instances[i].kind = kind }
        save()
    }
}

enum URLValidator {
    enum Issue: Error, LocalizedError {
        case invalid, unsupportedScheme, missingHost, suspiciousHost
        var errorDescription: String? {
            switch self {
            case .invalid: return "Not a valid URL."
            case .unsupportedScheme: return "Only http:// and https:// URLs are supported."
            case .missingHost: return "URL must include a hostname."
            case .suspiciousHost: return "Host is not allowed (cloud metadata endpoints are blocked)."
            }
        }
    }

    private static let schemeRegex = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9+.-]*:")

    /// Canonical form of well-known cloud-metadata hosts. Strip trailing dot, lowercase,
    /// fold IPv4 variants. This is intentionally not exhaustive — link-local IP-range
    /// blocking belongs at request time, not config time.
    private static let blockedHosts: Set<String> = [
        "169.254.169.254",
        "fd00:ec2::254",
        "metadata.google.internal",
        "metadata"               // GCP shortcut
    ]

    static func validate(_ raw: String) -> Result<String, Issue> {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .failure(.invalid) }
        // Detect an explicit scheme via RFC-style regex. Only prepend http:// when there's
        // truly no scheme — otherwise pass the user's input through so file:/, ftp:/,
        // javascript:, mailto: etc. get rejected at the scheme allowlist below.
        let range = NSRange(s.startIndex..., in: s)
        if schemeRegex.firstMatch(in: s, range: range) == nil {
            s = "http://" + s
        }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else {
            return .failure(.invalid)
        }
        if scheme != "http" && scheme != "https" { return .failure(.unsupportedScheme) }
        guard let rawHost = url.host, !rawHost.isEmpty else { return .failure(.missingHost) }
        // Canonicalize: lowercase, strip trailing dot.
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if blockedHosts.contains(host) { return .failure(.suspiciousHost) }
        return .success(s)
    }
}
