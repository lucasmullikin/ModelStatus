import Foundation
import os

private let log = Logger(subsystem: ConfigManager.bundleIdentifier, category: "provider.httpHealth")

struct HealthResponse: Codable {
    let status: String?
    let model: String?
}

struct HTTPHealthProvider: Provider {
    let kind: ProviderKind = .httpHealth
    let capabilities: ProviderCapabilities = .httpHealth

    func probe(_ instance: Instance, session: URLSession) async -> Bool {
        guard let base = URL(string: instance.url) else { return false }
        for suffix in ["/health", "/healthz"] {
            guard let url = URL(string: suffix, relativeTo: base) else { continue }
            do {
                let (data, http, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session, timeout: 3)
                guard http.statusCode == 200 else { continue }
                if let resp = try? JSONDecoder().decode(HealthResponse.self, from: data),
                   resp.status?.lowercased() == "ok" || resp.status?.lowercased() == "healthy" {
                    return true
                }
                if let text = String(data: data, encoding: .utf8),
                   text.lowercased().contains("ok") || text.lowercased().contains("healthy") {
                    return true
                }
            } catch { continue }
        }
        return false
    }

    func check(_ request: CheckRequest) async -> ServerStatus {
        let instance = request.instance
        let session = request.session
        let offline = ServerStatus(instance: instance, detectedKind: .httpHealth, state: .unreachable,
                                   loadedModels: [], availableModelCount: 0, vramTotal: 0,
                                   lastActive: nil, cpuPercent: nil, memoryMB: nil,
                                   clientProcess: nil, latencyMs: nil)
        guard let base = URL(string: instance.url) else { return offline }

        for suffix in ["/health", "/healthz"] {
            guard let url = URL(string: suffix, relativeTo: base) else { continue }
            do {
                let (data, http, latency) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session)
                guard http.statusCode == 200 else { continue }

                let resp = try? JSONDecoder().decode(HealthResponse.self, from: data)
                let modelName = resp?.model

                let loaded: [LoadedModel] = modelName.map {
                    [LoadedModel(name: $0, vramBytes: 0, expiresAt: nil)]
                } ?? []

                let state: ServerState = loaded.isEmpty ? .idle : .active

                return ServerStatus(instance: instance, detectedKind: .httpHealth, state: state,
                                    loadedModels: loaded, availableModelCount: loaded.count,
                                    vramTotal: 0, lastActive: request.lastActive,
                                    cpuPercent: request.localCPU, memoryMB: request.localMemMB,
                                    clientProcess: request.localClientProcess, latencyMs: latency)
            } catch {
                log.debug("HTTPHealth check failed on \(suffix): \(String(describing: error), privacy: .public)")
                continue
            }
        }
        return offline
    }

    func availableModels(_ instance: Instance, session: URLSession) async -> [String] {
        guard let base = URL(string: instance.url),
              let url = URL(string: "/health", relativeTo: base) else { return [] }
        do {
            let (data, http, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session)
            guard http.statusCode == 200 else { return [] }
            if let resp = try? JSONDecoder().decode(HealthResponse.self, from: data),
               let model = resp.model {
                return [model]
            }
        } catch {}
        return []
    }
}
