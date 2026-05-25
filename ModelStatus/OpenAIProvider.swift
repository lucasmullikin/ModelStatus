import Foundation

struct OpenAIModelsResponse: Codable {
    struct M: Codable {
        let id: String
    }
    let data: [M]?
}

/// Generic OpenAI-compatible provider — works with llama.cpp server, MLX (mlx_lm.server),
/// LocalAI, LM Studio (fallback if /api/v0 not detected), Text-Gen-WebUI, etc.
struct OpenAIProvider: Provider {
    let kind: ProviderKind = .openAI
    let capabilities = ProviderCapabilities.openAI

    func probe(_ instance: Instance, session: URLSession) async -> Bool {
        guard let base = URL(string: instance.url),
              let url = URL(string: "/v1/models", relativeTo: base) else { return false }
        do {
            let (data, http, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session, timeout: 3)
            guard http.statusCode == 200 else { return false }
            return (try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data)) != nil
        } catch { return false }
    }

    func check(_ instance: Instance, session: URLSession, isLocal: Bool, localCPU: Double?,
               localMemMB: Int?, localClientIP: String?, lastActive: Date?) async -> ServerStatus {
        let offline = ServerStatus(instance: instance, detectedKind: .openAI, state: .unreachable,
                                   loadedModels: [], availableModelCount: 0, vramTotal: 0,
                                   lastActive: nil, cpuPercent: nil, memoryMB: nil,
                                   clientIP: nil, latencyMs: nil)
        guard let base = URL(string: instance.url),
              let url = URL(string: "/v1/models", relativeTo: base) else { return offline }

        do {
            let (data, http, latency) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session)
            guard http.statusCode == 200 else { return offline }
            let resp = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
            let models = resp.data ?? []

            // OpenAI-compat servers list available models; for generic ones every listed model
            // counts as "loadable", with zero true VRAM info — show idle if nothing meaningful loaded.
            // We treat presence of models as "active" only when local lsof shows traffic, otherwise idle.
            let state: ServerState
            if isLocal {
                let busy = await LocalProbe.establishedConnectionPresent(
                    port: base.port ?? defaultPortGuess(base: base.absoluteString),
                    excludingPids: [])
                state = busy ? .generating : (models.isEmpty ? .idle : .active)
            } else {
                state = models.isEmpty ? .idle : .active   // No "generating" for remote OpenAI-compat
            }

            let loaded: [LoadedModel] = models.map { LoadedModel(name: $0.id, vramBytes: 0, expiresAt: nil) }
            return ServerStatus(instance: instance, detectedKind: .openAI, state: state,
                                loadedModels: loaded, availableModelCount: models.count,
                                vramTotal: 0, lastActive: lastActive,
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

    private func defaultPortGuess(base: String) -> Int {
        // Common local OpenAI-compat ports: LM Studio 1234, llama.cpp 8080, vLLM/mlx 8000
        if base.contains(":1234") { return 1234 }
        if base.contains(":8080") { return 8080 }
        if base.contains(":8000") { return 8000 }
        return 8080
    }
}
