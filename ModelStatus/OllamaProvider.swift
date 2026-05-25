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
              let url = URL(string: "/api/tags", relativeTo: base) else { return false }
        do {
            let (data, http, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session, timeout: 3)
            guard http.statusCode == 200 else { return false }
            // Strict: require the `models` key to be present (even if empty array).
            return (try? JSONDecoder().decode(TagsResponse.self, from: data))?.models != nil
        } catch { return false }
    }

    func check(_ instance: Instance, session: URLSession, isLocal: Bool, localCPU: Double?,
               localMemMB: Int?, localClientProcess: String?, lastActive: Date?) async -> ServerStatus {
        let offline = ServerStatus(instance: instance, detectedKind: .ollama, state: .unreachable,
                                   loadedModels: [], availableModelCount: 0, vramTotal: 0,
                                   lastActive: nil, cpuPercent: nil, memoryMB: nil,
                                   clientProcess: nil, latencyMs: nil)
        guard let base = URL(string: instance.url),
              let psURL = URL(string: "/api/ps", relativeTo: base),
              let tagsURL = URL(string: "/api/tags", relativeTo: base) else { return offline }

        do {
            let (psData, psResp, latency) = try await HTTPHelpers.get(psURL, instanceID: instance.id, session: session)
            guard psResp.statusCode == 200 else { return offline }

            var tagsData: Data?
            do { tagsData = try await HTTPHelpers.get(tagsURL, instanceID: instance.id, session: session).0 } catch {}
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
                if isLocal {
                    let port = base.port ?? 11434
                    let ollamaPids = await LocalProbe.pidsFor(processName: "ollama")
                    busy = await LocalProbe.establishedConnectionPresent(port: port, excludingPids: ollamaPids)
                }
                return ServerStatus(instance: instance, detectedKind: .ollama,
                                    state: busy ? .generating : .active,
                                    loadedModels: loaded, availableModelCount: availCount,
                                    vramTotal: vramTotal, lastActive: lastActive,
                                    cpuPercent: localCPU, memoryMB: localMemMB,
                                    clientProcess: localClientProcess, latencyMs: latency)
            }
            return ServerStatus(instance: instance, detectedKind: .ollama, state: .idle,
                                loadedModels: [], availableModelCount: availCount, vramTotal: 0,
                                lastActive: nil, cpuPercent: localCPU, memoryMB: localMemMB,
                                clientProcess: nil, latencyMs: latency)
        } catch { return offline }
    }

    func ejectModel(_ name: String, on instance: Instance, session: URLSession) async {
        guard let base = URL(string: instance.url) else { return }
        _ = try? await HTTPHelpers.post(base.appendingPathComponent("api/generate"),
                                        body: ["model": name, "keep_alive": 0],
                                        instanceID: instance.id, session: session)
    }

    func loadModel(_ name: String, on instance: Instance, session: URLSession) async {
        guard let base = URL(string: instance.url) else { return }
        _ = try? await HTTPHelpers.post(base.appendingPathComponent("api/generate"),
                                        body: ["model": name, "keep_alive": -1],
                                        instanceID: instance.id, session: session, timeout: 30)
    }

    func availableModels(_ instance: Instance, session: URLSession) async -> [String] {
        guard let base = URL(string: instance.url),
              let tagsURL = URL(string: "/api/tags", relativeTo: base) else { return [] }
        do {
            let (data, _, _) = try await HTTPHelpers.get(tagsURL, instanceID: instance.id, session: session)
            return (try? JSONDecoder().decode(TagsResponse.self, from: data))?.models?.map(\.name).sorted() ?? []
        } catch { return [] }
    }
}
