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

    func check(_ request: CheckRequest) async -> ServerStatus {
        let instance = request.instance
        let session = request.session
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
            // Audit-round-D7: require the `data` key — probe() does the same.
            // A 200 response with `{}` should be treated as malformed, not idle.
            guard let all = resp.data else { return offline }
            let loaded = all.filter { $0.state == "loaded" }
                .map { LoadedModel(name: $0.id, vramBytes: 0, expiresAt: nil) }
            let state: ServerState = loaded.isEmpty ? .idle : .active
            return ServerStatus(instance: instance, detectedKind: .lmStudio, state: state,
                                loadedModels: loaded, availableModelCount: all.count,
                                vramTotal: 0, lastActive: request.lastActive,
                                cpuPercent: request.localCPU, memoryMB: request.localMemMB,
                                clientProcess: request.localClientProcess, latencyMs: latency)
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
            // Audit-round-D7: validate HTTP status before decoding so non-200
            // responses that happen to look like the expected shape can't
            // populate the menu with junk.
            let (data, http, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session)
            guard http.statusCode == 200 else { return [] }
            return (try? JSONDecoder().decode(LMStudioModelsResponse.self, from: data))?.data?.map(\.id).sorted() ?? []
        } catch { return [] }
    }
}
