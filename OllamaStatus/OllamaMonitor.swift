import Foundation

/// Represents the status of an Ollama instance
enum OllamaStatus: Equatable {
    case idle
    case active
    case unreachable
}

/// Status for a single instance
struct InstanceStatus: Equatable {
    let instance: OllamaInstance
    let status: OllamaStatus
    let modelName: String?
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
            return InstanceStatus(instance: instance, status: .unreachable, modelName: nil)
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return InstanceStatus(instance: instance, status: .unreachable, modelName: nil)
            }

            let psResponse = try JSONDecoder().decode(OllamaPsResponse.self, from: data)

            if let models = psResponse.models, !models.isEmpty {
                let modelName = models.first?.name
                return InstanceStatus(instance: instance, status: .active, modelName: modelName)
            }

            return InstanceStatus(instance: instance, status: .idle, modelName: nil)
        } catch {
            return InstanceStatus(instance: instance, status: .unreachable, modelName: nil)
        }
    }
}
