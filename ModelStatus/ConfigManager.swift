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

    static let `default` = AppConfig(
        instances: [Instance(name: "Local", url: "http://127.0.0.1:11434", kind: .ollama)],
        pollInterval: 5.0,
        notifyOnStateChange: false,
        compactMode: false
    )

    enum CodingKeys: String, CodingKey {
        case instances, pollInterval, notifyOnStateChange, compactMode
    }

    init(instances: [Instance], pollInterval: TimeInterval, notifyOnStateChange: Bool, compactMode: Bool) {
        self.instances = instances
        self.pollInterval = pollInterval
        self.notifyOnStateChange = notifyOnStateChange
        self.compactMode = compactMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.instances = try c.decode([Instance].self, forKey: .instances)
        self.pollInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .pollInterval) ?? 5.0
        self.notifyOnStateChange = try c.decodeIfPresent(Bool.self, forKey: .notifyOnStateChange) ?? false
        self.compactMode = try c.decodeIfPresent(Bool.self, forKey: .compactMode) ?? false
    }
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

final class ConfigManager {
    static let shared = ConfigManager()

    static let bundleIdentifier = "com.lucrativepictures.ModelStatus"
    private static let legacyBundleIdentifiers = [
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

    private static func loadWithMigration(target: URL, in prefsDir: URL) -> AppConfig? {
        if let cfg = load(from: target) { return cfg }
        for legacy in legacyBundleIdentifiers {
            let legacyURL = prefsDir.appendingPathComponent("\(legacy).json")
            if let cfg = load(from: legacyURL) { return cfg }
        }
        return nil
    }

    private static func load(from url: URL) -> AppConfig? {
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

    static func validate(_ raw: String) -> Result<String, Issue> {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .failure(.invalid) }
        // Only prepend http:// when there's NO scheme at all. If the user typed an explicit
        // scheme like file://, ftp://, javascript: — fall through and reject below instead of
        // mangling it into "http://file:///..." which would still pass the http-scheme check.
        if !s.contains("://") && !s.lowercased().hasPrefix("javascript:") {
            s = "http://" + s
        }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else {
            return .failure(.invalid)
        }
        if scheme != "http" && scheme != "https" { return .failure(.unsupportedScheme) }
        guard let host = url.host, !host.isEmpty else { return .failure(.missingHost) }
        let blocked: Set<String> = ["169.254.169.254", "fd00:ec2::254", "metadata.google.internal"]
        if blocked.contains(host.lowercased()) { return .failure(.suspiciousHost) }
        return .success(s)
    }
}
