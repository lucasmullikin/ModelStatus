import Foundation

private struct PsResponse: Codable {
    let models: [PsModel]?
}
private struct PsModel: Codable {
    let name: String
    let size: Int64?
    let size_vram: Int64?
    let expires_at: String?
}
private struct TagsResponse: Codable {
    struct Model: Codable { let name: String }
    let models: [Model]?
}

struct OllamaProvider: Provider {
    let kind: ProviderKind = .ollama
    let capabilities = ProviderCapabilities.ollama

    func probe(_ instance: Instance, session: URLSession) async -> Bool {
        guard let base = URL(string: instance.url),
              let url = Self.endpoint(base: base, suffix: "api/tags") else { return false }
        do {
            let (data, http, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session, timeout: 3)
            guard http.statusCode == 200 else { return false }
            // Strict: require the `models` key to be present (even if empty array).
            return (try? JSONDecoder().decode(TagsResponse.self, from: data))?.models != nil
        } catch { return false }
    }

    func check(_ request: CheckRequest) async -> ServerStatus {
        let instance = request.instance
        let session = request.session
        let offline = ServerStatus(instance: instance, detectedKind: .ollama, state: .unreachable,
                                   loadedModels: [], availableModelCount: 0, vramTotal: 0,
                                   lastActive: nil, cpuPercent: nil, memoryMB: nil,
                                   clientProcess: nil, latencyMs: nil)
        guard let base = URL(string: instance.url),
              let psURL = Self.endpoint(base: base, suffix: "api/ps"),
              let tagsURL = Self.endpoint(base: base, suffix: "api/tags") else { return offline }

        do {
            let (psData, psResp, latency) = try await HTTPHelpers.get(psURL, instanceID: instance.id, session: session)
            guard psResp.statusCode == 200 else { return offline }

            // Audit-round-D46: gate on HTTP 200 before decoding /api/tags so
            // a non-200 body that happens to match the shape can't inflate
            // availableModelCount.
            var tagsData: Data?
            do {
                let (data, tagsResp, _) = try await HTTPHelpers.get(tagsURL, instanceID: instance.id, session: session)
                if tagsResp.statusCode == 200 { tagsData = data }
            } catch {}
            let availCount = tagsData.flatMap { try? JSONDecoder().decode(TagsResponse.self, from: $0) }?.models?.count ?? 0

            let ps = try JSONDecoder().decode(PsResponse.self, from: psData)
            if let models = ps.models, !models.isEmpty {
                var loaded: [LoadedModel] = []
                var vramTotal: Int64 = 0
                for m in models {
                    let v = m.size_vram ?? m.size ?? 0
                    vramTotal += v
                    loaded.append(LoadedModel(name: m.name, vramBytes: v, expiresAt: m.expires_at))
                }
                var busy = false
                if request.isLocal {
                    let port = base.port ?? 11434
                    let ollamaPids = await LocalProbe.pidsFor(processName: "ollama")
                    // Audit-round-D36: exclude our OWN PID too so URLSession's
                    // keep-alive polling connection isn't counted as
                    // generation traffic and falsely flips state to
                    // .generating on every poll.
                    let selfPid = Int(ProcessInfo.processInfo.processIdentifier)
                    busy = await LocalProbe.establishedConnectionPresent(
                        port: port,
                        excludingPids: ollamaPids.union([selfPid])
                    )
                }
                return ServerStatus(instance: instance, detectedKind: .ollama,
                                    state: busy ? .generating : .active,
                                    loadedModels: loaded, availableModelCount: availCount,
                                    vramTotal: vramTotal, lastActive: request.lastActive,
                                    cpuPercent: request.localCPU, memoryMB: request.localMemMB,
                                    clientProcess: request.localClientProcess, latencyMs: latency)
            }
            return ServerStatus(instance: instance, detectedKind: .ollama, state: .idle,
                                loadedModels: [], availableModelCount: availCount, vramTotal: 0,
                                lastActive: nil, cpuPercent: request.localCPU, memoryMB: request.localMemMB,
                                clientProcess: nil, latencyMs: latency)
        } catch { return offline }
    }

    func ejectModel(_ name: String, on instance: Instance, session: URLSession) async {
        guard let base = URL(string: instance.url),
              let url = Self.endpoint(base: base, suffix: "api/generate") else { return }
        _ = try? await HTTPHelpers.post(url,
                                        body: ["model": name, "keep_alive": 0],
                                        instanceID: instance.id, session: session)
    }

    func loadModel(_ name: String, on instance: Instance, session: URLSession) async {
        guard let base = URL(string: instance.url),
              let url = Self.endpoint(base: base, suffix: "api/generate") else { return }
        _ = try? await HTTPHelpers.post(url,
                                        body: ["model": name, "keep_alive": -1],
                                        instanceID: instance.id, session: session, timeout: 30)
    }

    func availableModels(_ instance: Instance, session: URLSession) async -> [String] {
        guard let base = URL(string: instance.url),
              let tagsURL = Self.endpoint(base: base, suffix: "api/tags") else { return [] }
        do {
            let (data, http, _) = try await HTTPHelpers.get(tagsURL, instanceID: instance.id, session: session)
            guard http.statusCode == 200 else { return [] }
            return (try? JSONDecoder().decode(TagsResponse.self, from: data))?.models?.map(\.name).sorted() ?? []
        } catch { return [] }
    }

    /// Path-preserving endpoint construction. Audit-round-D12: a base like
    /// `https://host/ollama` should yield `https://host/ollama/api/X`, not
    /// `https://host/api/X`. The leading-slash `URL(string:relativeTo:)`
    /// pattern discards the prefix; we explicitly append to `base.path`.
    static func endpoint(base: URL, suffix: String) -> URL? {
        var path = base.path
        while path.hasSuffix("/") { path.removeLast() }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.path = path + "/" + suffix
        comps?.query = nil
        comps?.fragment = nil
        return comps?.url
    }
}
