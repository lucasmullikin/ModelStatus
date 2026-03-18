import Foundation

/// Represents the status of an Ollama instance
enum OllamaStatus: Equatable {
    case active       // model loaded in memory
    case idle         // ollama running, no models loaded
    case unreachable  // cannot connect
}

/// Status for a single instance
struct InstanceStatus: Equatable {
    let instance: OllamaInstance
    let status: OllamaStatus
    let modelName: String?
    let lastActive: Date?  // When model was last used (prompt in/out)
}

/// Response structure for /api/ps endpoint
struct OllamaPsResponse: Codable {
    let models: [OllamaModel]?
}

struct OllamaModel: Codable {
    let name: String
    let size: Int64?
    let digest: String?
    let details: OllamaModelDetails?
    let expires_at: String?
    let size_vram: Int64?
}

struct OllamaModelDetails: Codable {
    let format: String?
    let family: String?
    let parameter_size: String?
    let quantization_level: String?
}

/// Monitors multiple Ollama instances via /api/ps polling
actor OllamaMonitor {
    private var pollTask: Task<Void, Never>?
    private var currentStatuses: [UUID: InstanceStatus] = [:]
    private var lastExpiresAt: [UUID: String] = [:]      // Track expires_at per instance
    private var lastActiveTime: [UUID: Date] = [:]       // When expires_at last changed

    typealias StatusCallback = @Sendable ([InstanceStatus]) -> Void
    private var onStatusChange: StatusCallback?

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 5.0
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func startPolling(onStatusChange: @escaping StatusCallback) {
        self.onStatusChange = onStatusChange
        lastExpiresAt = [:]
        lastActiveTime = [:]

        pollTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                await self.poll()
                let interval = ConfigManager.shared.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() async {
        let instances = ConfigManager.shared.instances

        // Check all instances concurrently
        let statuses = await withTaskGroup(of: InstanceStatus.self) { group in
            for instance in instances {
                group.addTask {
                    await self.checkStatus(for: instance)
                }
            }

            var results: [InstanceStatus] = []
            for await status in group {
                results.append(status)
            }
            return results
        }

        // Check if anything changed
        var newStatuses: [UUID: InstanceStatus] = [:]
        for status in statuses {
            newStatuses[status.instance.id] = status
        }

        if newStatuses != currentStatuses {
            currentStatuses = newStatuses
            // Maintain order from config
            let orderedStatuses = instances.compactMap { newStatuses[$0.id] }
            onStatusChange?(orderedStatuses)
        }
    }

    private func checkStatus(for instance: OllamaInstance) async -> InstanceStatus {
        guard let baseURL = URL(string: instance.url),
              let url = URL(string: "/api/ps", relativeTo: baseURL) else {
            return InstanceStatus(instance: instance, status: .unreachable, modelName: nil, lastActive: nil)
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return InstanceStatus(instance: instance, status: .unreachable, modelName: nil, lastActive: nil)
            }

            let psResponse = try JSONDecoder().decode(OllamaPsResponse.self, from: data)

            if let models = psResponse.models, !models.isEmpty {
                let model = models.first
                let modelName = model?.name
                let currentExpires = model?.expires_at

                // Track when expires_at changes (indicates prompt activity)
                let previousExpires = lastExpiresAt[instance.id]
                if let current = currentExpires {
                    if previousExpires != current {
                        // expires_at changed = model was just used
                        lastActiveTime[instance.id] = Date()
                    }
                    lastExpiresAt[instance.id] = current
                }

                let lastActive = lastActiveTime[instance.id]
                return InstanceStatus(instance: instance, status: .active, modelName: modelName, lastActive: lastActive)
            }

            return InstanceStatus(instance: instance, status: .idle, modelName: nil, lastActive: nil)
        } catch {
            return InstanceStatus(instance: instance, status: .unreachable, modelName: nil, lastActive: nil)
        }
    }
}
