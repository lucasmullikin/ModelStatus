import Foundation

/// Represents a single Ollama instance configuration
struct OllamaInstance: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var url: String

    init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
}

/// Application configuration
struct AppConfig: Codable {
    var instances: [OllamaInstance]
    var pollInterval: TimeInterval
    var showURLs: Bool

    static let `default` = AppConfig(
        instances: [
            OllamaInstance(name: "Local Mac", url: "http://127.0.0.1:11434"),
            OllamaInstance(name: "M4 Pro", url: "http://100.93.42.114:11434")
        ],
        pollInterval: 2.0,
        showURLs: true
    )
}

/// Manages persistent configuration for OllamaStatus
final class ConfigManager {
    static let shared = ConfigManager()

    private let configURL: URL
    private var _config: AppConfig

    var config: AppConfig {
        get { _config }
        set {
            _config = newValue
            save()
        }
    }

    var instances: [OllamaInstance] {
        get { _config.instances }
        set {
            _config.instances = newValue
            save()
        }
    }

    var pollInterval: TimeInterval {
        get { _config.pollInterval }
        set {
            _config.pollInterval = newValue
            save()
        }
    }

    var showURLs: Bool {
        get { _config.showURLs }
        set {
            _config.showURLs = newValue
            save()
        }
    }

    private init() {
        let prefsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        configURL = prefsDir.appendingPathComponent("com.local.ollamastatus.json")

        _config = Self.load(from: configURL) ?? .default
    }

    private static func load(from url: URL) -> AppConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(_config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    func addInstance(name: String, url: String) {
        let instance = OllamaInstance(name: name, url: url)
        _config.instances.append(instance)
        save()
    }

    func removeInstance(at index: Int) {
        guard index >= 0 && index < _config.instances.count else { return }
        _config.instances.remove(at: index)
        save()
    }

    func removeInstance(id: UUID) {
        _config.instances.removeAll { $0.id == id }
        save()
    }
}
