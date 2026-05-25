import Foundation

/// vLLM speaks OpenAI /v1/models and additionally exposes a Prometheus /metrics endpoint.
/// We detect it by probing /metrics for the characteristic `vllm:` metric prefix.
struct VLLMProvider: Provider {
    let kind: ProviderKind = .vllm
    let capabilities = ProviderCapabilities.vllm

    func probe(_ instance: Instance, session: URLSession) async -> Bool {
        guard let base = URL(string: instance.url),
              let metricsURL = URL(string: "/metrics", relativeTo: base) else { return false }
        do {
            let (data, http, _) = try await HTTPHelpers.get(metricsURL, instanceID: instance.id, session: session, timeout: 3)
            guard http.statusCode == 200, let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("vllm:")
        } catch { return false }
    }

    func check(_ instance: Instance, session: URLSession, isLocal: Bool, localCPU: Double?,
               localMemMB: Int?, localClientIP: String?, lastActive: Date?) async -> ServerStatus {
        let offline = ServerStatus(instance: instance, detectedKind: .vllm, state: .unreachable,
                                   loadedModels: [], availableModelCount: 0, vramTotal: 0,
                                   lastActive: nil, cpuPercent: nil, memoryMB: nil,
                                   clientIP: nil, latencyMs: nil)
        guard let base = URL(string: instance.url),
              let modelsURL = URL(string: "/v1/models", relativeTo: base),
              let metricsURL = URL(string: "/metrics", relativeTo: base) else { return offline }

        do {
            let (modelsData, http, latency) = try await HTTPHelpers.get(modelsURL, instanceID: instance.id, session: session)
            guard http.statusCode == 200 else { return offline }
            let mr = try JSONDecoder().decode(OpenAIModelsResponse.self, from: modelsData)
            let models = mr.data ?? []

            var vramTotal: Int64 = 0
            if let (metricsData, _, _) = try? await HTTPHelpers.get(metricsURL, instanceID: instance.id, session: session),
               let text = String(data: metricsData, encoding: .utf8) {
                vramTotal = Self.parseGPUMemoryBytes(prometheusText: text)
            }

            let loaded: [LoadedModel] = models.map {
                LoadedModel(name: $0.id, vramBytes: vramTotal / Int64(max(models.count, 1)), expiresAt: nil)
            }
            let state: ServerState = models.isEmpty ? .idle : .active
            return ServerStatus(instance: instance, detectedKind: .vllm, state: state,
                                loadedModels: loaded, availableModelCount: models.count,
                                vramTotal: vramTotal, lastActive: lastActive,
                                cpuPercent: localCPU, memoryMB: localMemMB,
                                clientIP: localClientIP, latencyMs: latency)
        } catch { return offline }
    }

    func availableModels(_ instance: Instance, session: URLSession) async -> [String] {
        guard let base = URL(string: instance.url),
              let url = URL(string: "/v1/models", relativeTo: base) else { return [] }
        do {
            let (data, _, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session)
            return (try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data))?.data?.map(\.id).sorted() ?? []
        } catch { return [] }
    }

    /// Parse `vllm:gpu_memory_usage_bytes` (or similar) from Prometheus text exposition format.
    static func parseGPUMemoryBytes(prometheusText: String) -> Int64 {
        var total: Int64 = 0
        for line in prometheusText.split(separator: "\n") {
            if line.hasPrefix("#") { continue }
            let lower = line.lowercased()
            guard lower.contains("vllm") && lower.contains("memory") else { continue }
            // Last whitespace-separated token is the value
            if let valStr = line.split(whereSeparator: { $0.isWhitespace }).last,
               let val = Double(valStr) {
                total += Int64(val)
            }
        }
        return total
    }
}
