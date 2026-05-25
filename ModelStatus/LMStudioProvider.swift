import Foundation

private struct LMStudioModelsResponse: Codable {
    struct M: Codable {
        let id: String
        let state: String?       // "loaded", "not-loaded", etc.
        let max_context_length: Int?
        let loaded_context_length: Int?
    }
    let data: [M]?
}

/// LM Studio adds /api/v0/models which exposes per-model loaded state,
/// plus /api/v0/models/load and /api/v0/models/unload endpoints.
struct LMStudioProvider: Provider {
    let kind: ProviderKind = .lmStudio
    let capabilities = ProviderCapabilities.lmStudio

    func probe(_ instance: Instance, session: URLSession) async -> Bool {
        guard let base = URL(string: instance.url),
              let url = URL(string: "/api/v0/models", relativeTo: base) else { return false }
        do {
            let (data, http, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session, timeout: 3)
            guard http.statusCode == 200 else { return false }
            // Strict: require the `data` key to be present.
            return (try? JSONDecoder().decode(LMStudioModelsResponse.self, from: data))?.data != nil
        } catch { return false }
    }

    func check(_ instance: Instance, session: URLSession, isLocal: Bool, localCPU: Double?,
               localMemMB: Int?, localClientProcess: String?, lastActive: Date?) async -> ServerStatus {
        let offline = ServerStatus(instance: instance, detectedKind: .lmStudio, state: .unreachable,
                                   loadedModels: [], availableModelCount: 0, vramTotal: 0,
                                   lastActive: nil, cpuPercent: nil, memoryMB: nil,
                                   clientProcess: nil, latencyMs: nil)
        guard let base = URL(string: instance.url),
              let url = URL(string: "/api/v0/models", relativeTo: base) else { return offline }

        do {
            let (data, http, latency) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session)
            guard http.statusCode == 200 else { return offline }
            let resp = try JSONDecoder().decode(LMStudioModelsResponse.self, from: data)
            let all = resp.data ?? []
            let loaded = all.filter { $0.state == "loaded" }
                .map { LoadedModel(name: $0.id, vramBytes: 0, expiresAt: nil) }
            let state: ServerState = loaded.isEmpty ? .idle : .active
            return ServerStatus(instance: instance, detectedKind: .lmStudio, state: state,
                                loadedModels: loaded, availableModelCount: all.count,
                                vramTotal: 0, lastActive: lastActive,
                                cpuPercent: localCPU, memoryMB: localMemMB,
                                clientProcess: localClientProcess, latencyMs: latency)
        } catch { return offline }
    }

    func ejectModel(_ name: String, on instance: Instance, session: URLSession) async {
        guard let base = URL(string: instance.url),
              let url = URL(string: "/api/v0/models/unload", relativeTo: base) else { return }
        _ = try? await HTTPHelpers.post(url, body: ["model": name],
                                        instanceID: instance.id, session: session)
    }

    func loadModel(_ name: String, on instance: Instance, session: URLSession) async {
        guard let base = URL(string: instance.url),
              let url = URL(string: "/api/v0/models/load", relativeTo: base) else { return }
        _ = try? await HTTPHelpers.post(url, body: ["model": name],
                                        instanceID: instance.id, session: session, timeout: 60)
    }

    func availableModels(_ instance: Instance, session: URLSession) async -> [String] {
        guard let base = URL(string: instance.url),
              let url = URL(string: "/api/v0/models", relativeTo: base) else { return [] }
        do {
            let (data, _, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session)
            return (try? JSONDecoder().decode(LMStudioModelsResponse.self, from: data))?.data?.map(\.id).sorted() ?? []
        } catch { return [] }
    }
}
