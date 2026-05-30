import Foundation

/// vLLM speaks OpenAI /v1/models and additionally exposes a Prometheus /metrics endpoint.
/// We detect it by probing /metrics for the characteristic `vllm:` metric prefix.
struct VLLMProvider: Provider {
    let kind: ProviderKind = .vllm
    let capabilities = ProviderCapabilities.vllm

    func probe(_ instance: Instance, session: URLSession) async -> Bool {
        guard let base = URL(string: instance.url),
              let metricsURL = Self.endpoint(base: base, suffix: "metrics") else { return false }
        do {
            let (data, http, _) = try await HTTPHelpers.get(metricsURL, instanceID: instance.id, session: session, timeout: 3)
            guard http.statusCode == 200, let text = String(data: data, encoding: .utf8) else { return false }
            // Audit-round-D37: require a real sample line starting with the
            // documented `vllm:` metric prefix. Dropped the broader
            // `vllm_` form — only `vllm:` is canonical, accepting both
            // widened detection to non-vLLM services exposing similarly-
            // named metrics.
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") || line.isEmpty { continue }
                if line.hasPrefix("vllm:") { return true }
            }
            return false
        } catch { return false }
    }

    func check(_ request: CheckRequest) async -> ServerStatus {
        let instance = request.instance
        let session = request.session
        let offline = ServerStatus(instance: instance, detectedKind: .vllm, state: .unreachable,
                                   loadedModels: [], availableModelCount: 0, vramTotal: 0,
                                   lastActive: nil, cpuPercent: nil, memoryMB: nil,
                                   clientProcess: nil, latencyMs: nil)
        guard let base = URL(string: instance.url),
              let modelsURL = Self.endpoint(base: base, suffix: "v1/models"),
              let metricsURL = Self.endpoint(base: base, suffix: "metrics") else { return offline }

        do {
            let (modelsData, http, latency) = try await HTTPHelpers.get(modelsURL, instanceID: instance.id, session: session)
            guard http.statusCode == 200 else { return offline }
            let mr = try JSONDecoder().decode(OpenAIModelsResponse.self, from: modelsData)
            let models = mr.data ?? []

            var vramTotal: Int64 = 0
            var requestsRunning: Int = 0
            // Audit-round-D36: gate metrics parsing on a successful 200
            // response so a non-200 body that happens to match the parser
            // shape can't contribute to vramTotal.
            if let (metricsData, metricsHTTP, _) = try? await HTTPHelpers.get(metricsURL, instanceID: instance.id, session: session),
               metricsHTTP.statusCode == 200,
               let text = String(data: metricsData, encoding: .utf8) {
                vramTotal = Self.parseGPUMemoryBytes(prometheusText: text)
                // v1.0.1: parse num_requests_running to detect Generating state.
                // vLLM exposes `vllm:num_requests_running` as the count of
                // requests currently being processed by the engine (NOT just
                // queued — those are in `vllm:num_requests_waiting`). When >0
                // the server is actively generating tokens right now.
                requestsRunning = Self.parseRequestsRunning(prometheusText: text)
            }

            let loaded: [LoadedModel] = models.map {
                LoadedModel(name: $0.id, vramBytes: vramTotal / Int64(max(models.count, 1)), expiresAt: nil)
            }
            // v1.0.1: three-state classification driven by /metrics activity.
            //   • num_requests_running > 0  → Generating (blue, mid-inference)
            //   • models loaded, no requests → Active (green, ready)
            //   • no models                  → Idle (yellow, registry empty)
            // Falls back to (models.isEmpty ? idle : active) if /metrics
            // didn't return a value (older vLLM versions, /metrics blocked
            // by a proxy, etc.).
            let state: ServerState
            if requestsRunning > 0 {
                state = .generating
            } else if models.isEmpty {
                state = .idle
            } else {
                state = .active
            }
            return ServerStatus(instance: instance, detectedKind: .vllm, state: state,
                                loadedModels: loaded, availableModelCount: models.count,
                                vramTotal: vramTotal, lastActive: request.lastActive,
                                cpuPercent: request.localCPU, memoryMB: request.localMemMB,
                                clientProcess: request.localClientProcess, latencyMs: latency)
        } catch { return offline }
    }

    func availableModels(_ instance: Instance, session: URLSession) async -> [String] {
        guard let base = URL(string: instance.url),
              let url = Self.endpoint(base: base, suffix: "v1/models") else { return [] }
        do {
            // Audit-round-D37: require 200 before decoding so a non-success
            // body that happens to match the shape can't populate the menu.
            let (data, http, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session)
            guard http.statusCode == 200 else { return [] }
            return (try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data))?.data?.map(\.id).sorted() ?? []
        } catch { return [] }
    }

    /// Path-preserving endpoint construction. Audit-round-D24: a reverse-
    /// proxied vLLM at `https://host/proxy/vllm` needs `https://host/proxy/vllm/metrics`,
    /// not `https://host/metrics` — `URL(string:relativeTo:)` with a leading
    /// slash discards the prefix.
    static func endpoint(base: URL, suffix: String) -> URL? {
        var path = base.path
        while path.hasSuffix("/") { path.removeLast() }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.path = path + "/" + suffix
        comps?.query = nil
        comps?.fragment = nil
        return comps?.url
    }

    /// Parse `vllm:gpu_memory_usage_bytes` specifically from Prometheus text exposition format.
    /// Audit-round-D7/D8/D23: exact metric-name match (no substring), value
    /// is the SECOND whitespace token, per-sample value range-checked,
    /// accumulator overflow-clamped.
    ///
    /// **Documented limitation**: assumes labels do NOT contain literal
    /// whitespace. vLLM's GPU-memory metric doesn't emit such labels in
    /// practice. A label like `{model="foo bar"}` would push the value into
    /// the wrong token position and the sample would be skipped silently.
    /// Accepting that limitation in favor of simpler parsing.
    static func parseGPUMemoryBytes(prometheusText: String) -> Int64 {
        let metricName = "vllm:gpu_memory_usage_bytes"
        var total: Int64 = 0
        for rawLine in prometheusText.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.count >= 2 else { continue }
            // First token is the metric name (with optional `{label=...}` block).
            let firstToken = tokens[0]
            let bareName: String
            if let braceIdx = firstToken.firstIndex(of: "{") {
                bareName = String(firstToken[firstToken.startIndex..<braceIdx])
            } else {
                bareName = firstToken
            }
            guard bareName == metricName else { continue }
            // Value is the SECOND token (a third optional token = timestamp).
            // Audit-round-D8 note: this assumes simple unquoted labels. A
            // label value containing literal whitespace (`{model="foo bar"}`)
            // would push `tokens[1]` into the label block — vLLM doesn't emit
            // such labels for this metric in practice, so we accept the
            // limitation in favor of simplicity.
            //
            // `Double(Int64.max)` rounds UP to a value slightly larger than
            // Int64.max, so a Double right at that boundary can pass the
            // comparison and still trap on conversion. Use a comfortable
            // margin below the boundary.
            let int64SafeMax: Double = 9.2233720368547e18   // ~Int64.max minus ~5 ulp
            guard let val = Double(tokens[1]),
                  val.isFinite, val >= 0, val < int64SafeMax else { continue }
            let sample = Int64(val)
            // Overflow-safe accumulation: clamp at Int64.max rather than trap.
            if Int64.max - total < sample {
                total = Int64.max
                break
            }
            total += sample
        }
        return total
    }

    /// v1.0.1: Parse `vllm:num_requests_running` from Prometheus text. Returns
    /// the count of requests currently being processed by the engine — used to
    /// flip the Generating state when the vLLM server is actively serving
    /// tokens RIGHT NOW (not just sitting at the registry with models loaded).
    ///
    /// Same parsing convention as `parseGPUMemoryBytes`: exact metric name match
    /// (no substring), value is the SECOND whitespace token of each sample line
    /// (after the labelled metric name). Sums across labeled samples so a
    /// future per-model breakdown (`{model="..."}`) is handled correctly.
    ///
    /// Returns 0 when:
    /// • metric not present (older vLLM, or proxy stripped /metrics)
    /// • all samples are 0 (no in-flight requests)
    /// • a sample is non-numeric or negative (defensive — should never happen)
    static func parseRequestsRunning(prometheusText: String) -> Int {
        let metricName = "vllm:num_requests_running"
        var running = 0
        prometheusText.enumerateLines { line, _ in
            // Skip comments and empty lines — common in Prometheus exposition.
            if line.isEmpty || line.hasPrefix("#") { return }
            // Match the metric name exactly. The line might be either
            // `vllm:num_requests_running 3.0` (unlabeled) or
            // `vllm:num_requests_running{model="..."} 3.0` (labeled).
            guard line.hasPrefix(metricName) else { return }
            // Cheap label guard: char immediately after the metric name must
            // be whitespace OR an opening `{` — otherwise it's a different
            // metric whose name happens to start with our prefix (e.g.
            // `vllm:num_requests_running_total` if such a thing existed).
            let afterName = line.dropFirst(metricName.count)
            guard let firstChar = afterName.first,
                  firstChar == " " || firstChar == "\t" || firstChar == "{" else { return }
            // Value is the LAST whitespace-separated token on the line.
            // (Last, not second — labels with internal spaces would break
            // the second-token rule. vLLM's running metric uses simple
            // labels so this is robust.)
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            guard let valueToken = tokens.last,
                  let value = Double(valueToken),
                  value.isFinite, value >= 0 else { return }
            // Per-sample value is a float like "3.0" or "0". Round and cap
            // at a reasonable maximum so a corrupted huge value can't
            // overflow our Int return.
            let capped = min(Int(value.rounded()), 1_000_000)
            running += capped
        }
        return running
    }
}
