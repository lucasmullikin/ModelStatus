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
              let url = Self.modelsEndpoint(base: base) else { return false }
        do {
            let (data, http, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session, timeout: 3)
            guard http.statusCode == 200 else { return false }
            // Strict: require the `data` key to be present.
            return (try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data))?.data != nil
        } catch { return false }
    }

    func check(_ request: CheckRequest) async -> ServerStatus {
        let instance = request.instance
        let session = request.session
        let offline = ServerStatus(instance: instance, detectedKind: .openAI, state: .unreachable,
                                   loadedModels: [], availableModelCount: 0, vramTotal: 0,
                                   lastActive: nil, cpuPercent: nil, memoryMB: nil,
                                   clientProcess: nil, latencyMs: nil)
        guard let base = URL(string: instance.url),
              let url = Self.modelsEndpoint(base: base) else { return offline }

        do {
            let (data, http, latency) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session)
            guard http.statusCode == 200 else { return offline }
            let resp = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
            // Audit-round-D8: require the `data` key — probe() does the same.
            // A 200 response with `{}` should be reported as offline, not idle.
            guard let models = resp.data else { return offline }

            // OpenAI-compat servers list available models; for generic ones every listed model
            // counts as "loadable" with no true VRAM info. State semantics:
            //   • models present + local traffic from a non-self process → .generating
            //   • models present otherwise → .active
            //   • no models → .idle
            // Audit-round-D7: exclude our own PID from the traffic check so our
            // polling connection isn't counted as a client and incorrectly
            // bumps state to .generating.
            let state: ServerState
            if request.isLocal {
                let selfPid = Int(ProcessInfo.processInfo.processIdentifier)
                // Use the URL's EFFECTIVE port (scheme default if omitted) so
                // the traffic probe checks the same port URLSession actually
                // connected to. Audit-round-D7: the previous version fell back
                // to defaultPortGuess (8080) for port-less URLs, which mismatched
                // what http://localhost actually hit (port 80).
                let busy = await LocalProbe.establishedConnectionPresent(
                    port: Self.effectivePort(for: base),
                    excludingPids: [selfPid])
                state = models.isEmpty ? .idle : (busy ? .generating : .active)
            } else {
                state = models.isEmpty ? .idle : .active   // No "generating" for remote OpenAI-compat
            }

            let loaded: [LoadedModel] = models.map { LoadedModel(name: $0.id, vramBytes: 0, expiresAt: nil) }
            return ServerStatus(instance: instance, detectedKind: .openAI, state: state,
                                loadedModels: loaded, availableModelCount: models.count,
                                vramTotal: 0, lastActive: request.lastActive,
                                cpuPercent: request.localCPU, memoryMB: request.localMemMB,
                                clientProcess: request.localClientProcess, latencyMs: latency)
        } catch { return offline }
    }

    func availableModels(_ instance: Instance, session: URLSession) async -> [String] {
        guard let base = URL(string: instance.url),
              let url = Self.modelsEndpoint(base: base) else { return [] }
        do {
            // Audit-round-D7: gate on HTTP 200 before decoding, matching probe().
            let (data, http, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session)
            guard http.statusCode == 200 else { return [] }
            return (try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data))?.data?.map(\.id).sorted() ?? []
        } catch { return [] }
    }

    /// Effective TCP port for a URL — explicit, else the scheme's default.
    /// Matches the port URLSession will actually use when making the request,
    /// so traffic probes hit the same socket. Audit-round-D8: the old
    /// `defaultPortGuess` is removed as dead code now that `check` uses
    /// `effectivePort`.
    private static func effectivePort(for url: URL) -> Int {
        if let p = url.port { return p }
        return (url.scheme?.lowercased() == "https") ? 443 : 80
    }

    /// Path-preserving `/v1/models` endpoint construction. Audit-round-D9:
    /// `URL(string: "/v1/models", relativeTo: base)` treats the leading slash
    /// as an absolute path and discards any prefix in `base.path` — so
    /// `https://host/proxy/openai` would resolve to `https://host/v1/models`
    /// instead of `https://host/proxy/openai/v1/models`. Use path-component
    /// appending so reverse-proxied deployments work.
    static func modelsEndpoint(base: URL) -> URL? {
        // Drop any trailing slash on the base path, then append `v1/models`.
        // Audit-round-D10: normalize a base whose path already ends in `/v1`
        // so we don't double-append (`/v1/v1/models`). Also clear any query
        // and fragment so a user-typed URL with `?x=1` doesn't leak into the
        // endpoint URL.
        var path = base.path
        while path.hasSuffix("/") { path.removeLast() }
        let suffix: String
        // Audit-round-D49: a user can paste the FULL `/v1/models` URL by
        // mistake when adding an instance. Detect that and don't re-append.
        if path.hasSuffix("/v1/models") {
            suffix = ""
        } else if path.hasSuffix("/v1") {
            suffix = "/models"
        } else {
            suffix = "/v1/models"
        }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.path = path + suffix
        comps?.query = nil
        comps?.fragment = nil
        return comps?.url
    }
}
