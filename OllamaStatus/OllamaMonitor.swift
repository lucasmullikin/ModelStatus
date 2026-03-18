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
    let cpuPercent: Double?  // CPU usage for local instances only
    let memoryMB: Int?  // Memory usage in MB
    let clientIP: String?  // Client calling Ollama (local only)
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
    private var lastClientIP: [UUID: String] = [:]       // Last seen client IP

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

    /// Check if URL points to localhost
    private func isLocalInstance(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0"
    }

    /// Get CPU% of ollama process (local only)
    private func getOllamaCPU() -> Double? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pcpu,comm"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Find ollama process and sum CPU (could be multiple)
            var totalCPU: Double = 0
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("ollama") || trimmed.contains("Ollama") {
                    let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                    if let cpuStr = parts.first, let cpu = Double(cpuStr) {
                        totalCPU += cpu
                    }
                }
            }
            return totalCPU > 0 ? totalCPU : nil
        } catch {
            return nil
        }
    }

    /// Get memory usage of ollama process in MB (local only)
    private func getOllamaMemory() -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "rss,comm"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Find ollama process and sum memory (KB -> MB)
            var totalKB: Int = 0
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("ollama") || trimmed.contains("Ollama") {
                    let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                    if let kbStr = parts.first, let kb = Int(kbStr) {
                        totalKB += kb
                    }
                }
            }
            return totalKB > 0 ? totalKB / 1024 : nil
        } catch {
            return nil
        }
    }

    /// Get client info - process name or external IP connecting to Ollama
    private func getClientInfo() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-i", ":11434", "-n", "-P"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Look for client connections (not ollama itself, not our app)
            for line in output.components(separatedBy: "\n") {
                // Skip ollama server and our status app
                if line.hasPrefix("ollama") || line.contains("OllamaSta") { continue }

                // Look for ESTABLISHED connections TO port 11434
                if line.contains("ESTABLISHED") && line.contains("->") && line.contains(":11434") {
                    // Extract process name (first column)
                    let parts = line.split(whereSeparator: { $0.isWhitespace })
                    if let processName = parts.first {
                        let name = String(processName)
                        // Also try to get remote IP for external connections
                        if let arrowRange = line.range(of: "->") {
                            let beforeArrow = line[..<arrowRange.lowerBound]
                            // Check if connection is FROM external IP
                            if !beforeArrow.contains("127.0.0.1") && !beforeArrow.contains("[::1]") && !beforeArrow.contains("localhost") {
                                // External connection - extract IP
                                if let lastColon = beforeArrow.range(of: ":", options: .backwards),
                                   let spaceBeforeIP = beforeArrow[..<lastColon.lowerBound].range(of: " ", options: .backwards) {
                                    let ip = String(beforeArrow[spaceBeforeIP.upperBound..<lastColon.lowerBound])
                                    return "\(name) @ \(ip)"
                                }
                            }
                        }
                        return name
                    }
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    func startPolling(onStatusChange: @escaping StatusCallback) {
        self.onStatusChange = onStatusChange
        lastExpiresAt = [:]
        lastActiveTime = [:]
        lastClientIP = [:]

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

        // Always update (values like CPU/memory change constantly)
        var newStatuses: [UUID: InstanceStatus] = [:]
        for status in statuses {
            newStatuses[status.instance.id] = status
        }

        currentStatuses = newStatuses
        // Maintain order from config
        let orderedStatuses = instances.compactMap { newStatuses[$0.id] }
        onStatusChange?(orderedStatuses)
    }

    private func checkStatus(for instance: OllamaInstance) async -> InstanceStatus {
        guard let baseURL = URL(string: instance.url),
              let url = URL(string: "/api/ps", relativeTo: baseURL) else {
            return InstanceStatus(instance: instance, status: .unreachable, modelName: nil, lastActive: nil, cpuPercent: nil, memoryMB: nil, clientIP: nil)
        }

        // Get CPU, memory and client info for local instances
        let isLocal = isLocalInstance(instance.url)
        let cpuPercent: Double? = isLocal ? getOllamaCPU() : nil
        let memoryMB: Int? = isLocal ? getOllamaMemory() : nil

        // Track client info - if we see one now, update; otherwise use last known
        if isLocal {
            if let currentClient = getClientInfo() {
                lastClientIP[instance.id] = currentClient
            }
        }
        let clientIP = lastClientIP[instance.id]

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return InstanceStatus(instance: instance, status: .unreachable, modelName: nil, lastActive: nil, cpuPercent: nil, memoryMB: nil, clientIP: nil)
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
                        lastActiveTime[instance.id] = Date()
                    }
                    lastExpiresAt[instance.id] = current
                }

                let lastActive = lastActiveTime[instance.id]
                return InstanceStatus(instance: instance, status: .active, modelName: modelName, lastActive: lastActive, cpuPercent: cpuPercent, memoryMB: memoryMB, clientIP: clientIP)
            }

            // API returned empty but memory > 1GB means model is loaded (Ollama API bug workaround)
            if isLocal, let mem = memoryMB, mem > 1024 {
                lastActiveTime[instance.id] = Date()
                return InstanceStatus(instance: instance, status: .active, modelName: "model loaded", lastActive: Date(), cpuPercent: cpuPercent, memoryMB: memoryMB, clientIP: clientIP)
            }

            return InstanceStatus(instance: instance, status: .idle, modelName: nil, lastActive: nil, cpuPercent: cpuPercent, memoryMB: memoryMB, clientIP: nil)
        } catch {
            return InstanceStatus(instance: instance, status: .unreachable, modelName: nil, lastActive: nil, cpuPercent: nil, memoryMB: nil, clientIP: nil)
        }
    }
}
