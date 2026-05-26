import Foundation
import os

// Audit-round-D2: use the canonical bundle subsystem so this provider's logs
// are visible in the in-app LogViewer (which filters on
// ConfigManager.bundleIdentifier). The previous "com.modelstatus" subsystem
// silently routed these messages off the All-category predicate.
private let log = Logger(subsystem: ConfigManager.bundleIdentifier, category: "provider.mlx")

/// Response shape for MLX-flavored OpenAI-compatible `/v1/models`. We pull in
/// `owned_by` (mlx-omni-server sets it to "mlx-omni") on top of the standard id
/// field so id-pattern + ownership can both contribute to disambiguation.
///
/// Internal (not file-private) so the helper functions below can take Entry as a
/// parameter type without access-modifier violations — tests use @testable import.
struct MLXModelsResponse: Codable {
    struct Entry: Codable {
        let id: String
        let owned_by: String?
    }
    let data: [Entry]?
}

/// MLX provider for Apple-silicon native runtimes — `mlx_lm.server` and
/// `mlx-omni-server`. Both expose OpenAI `/v1/models`, both load exactly one
/// model per process (no eject / no load endpoints), and both are usually
/// fronted by a single `--model` argv flag we can mine for the canonical id.
///
/// Detection layers (cheap → expensive):
///   1. `/v1/models` parses as OpenAI shape.
///   2. At least one listed id matches MLX patterns and *none* match llama.cpp
///      GGUF quant patterns (which can be served by llama.cpp on the same port).
///   3. If loopback: the PID actually bound to the probed port has an argv that
///      mentions `mlx_lm.server`, `mlx-omni-server`, or `mlx_lm/server.py`.
struct MLXProvider: Provider {
    let kind: ProviderKind = .mlx
    // Use the shared preset so capability surface stays consistent with the
    // other providers' declarations.
    let capabilities: ProviderCapabilities = .mlx

    // MARK: - probe

    func probe(_ instance: Instance, session: URLSession) async -> Bool {
        // Audit-round-3: when the URL omits a port for a LOCAL MLX server, we
        // rewrite to include the default 8080 so the HTTP request and the
        // `lsof` process check agree. Without this, `http://localhost` would
        // request port 80 (scheme default) while we check the MLX process
        // on 8080 — guaranteed mismatch.
        let probeURLString = Self.localPortNormalizedURL(instance.url)
        guard let base = URL(string: probeURLString),
              let url = URL(string: "/v1/models", relativeTo: base) else { return false }
        do {
            let (data, http, _) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session, timeout: 3)
            guard http.statusCode == 200,
                  let resp = try? JSONDecoder().decode(MLXModelsResponse.self, from: data),
                  let entries = resp.data, !entries.isEmpty else { return false }

            // GGUF in any id → llama.cpp, refuse outright.
            if entries.contains(where: { Self.idLooksLikeGGUF($0) }) { return false }

            // Audit-round-D29: local/remote split — for LOCAL endpoints,
            // skip the MLX-shape ID gate and rely entirely on argv inspection
            // (matches check() / availableModels()). A `mlx_lm.server
            // --model Qwen/Qwen3-...` is valid MLX whose model ID won't
            // match `mlx-community/` or `owned_by == mlx-omni`. For REMOTE
            // endpoints we can't inspect process state, so keep the ID
            // heuristic as the only signal.
            if LocalProbe.isLocal(instance.url) {
                let port = base.port ?? Self.defaultPort(base.absoluteString)
                guard let proc = await Self.localProcessOnPort(port) else { return false }
                return Self.argvLooksLikeMLX(proc.args)
            }
            guard entries.contains(where: { Self.idLooksLikeMLX($0) }) else { return false }
            return true
        } catch { return false }
    }

    /// For LOCAL HTTP URLs missing an explicit port, prepend `:8080` (MLX default).
    /// Returns the original string unchanged for any URL that already has a
    /// port, that isn't loopback, or that uses HTTPS (where the implied port
    /// is 443, not 8080).
    ///
    /// Audit-round-D50-hard: previously the helper rewrote `https://localhost`
    /// to `https://localhost:8080`, silently retargeting an HTTPS URL away
    /// from its implied port 443. Now we only normalize when the scheme is
    /// HTTP (the form MLX actually exposes locally).
    static func localPortNormalizedURL(_ raw: String) -> String {
        guard LocalProbe.isLocal(raw),
              let comps = URLComponents(string: raw),
              comps.port == nil,
              (comps.scheme?.lowercased() ?? "") == "http" else { return raw }
        var rewritten = comps
        rewritten.port = 8080
        return rewritten.string ?? raw
    }

    // MARK: - check

    func check(_ request: CheckRequest) async -> ServerStatus {
        let instance = request.instance
        let session = request.session
        // Audit-round-D23: derive locality from the URL the same way probe()
        // does, instead of trusting the caller-supplied isLocal flag. If they
        // diverge, the local-process verification path would otherwise be
        // bypassed for a loopback URL whose flag says remote.
        let isLocal = LocalProbe.isLocal(instance.url)
        let localCPU = request.localCPU
        let localMemMB = request.localMemMB
        let localClientProcess = request.localClientProcess
        let lastActive = request.lastActive
        let offline = ServerStatus(instance: instance, detectedKind: .mlx, state: .unreachable,
                                   loadedModels: [], availableModelCount: 0, vramTotal: 0,
                                   lastActive: nil, cpuPercent: nil, memoryMB: nil,
                                   clientProcess: nil, latencyMs: nil)
        // Audit-round-4: use the same port-normalized URL probe() does, so a
        // local `http://localhost`-style config doesn't end up requesting port
        // 80 here (scheme default) while probe() targets 8080. Inconsistent
        // ports across the provider's HTTP calls cause "detected then offline".
        let normalizedURL = Self.localPortNormalizedURL(instance.url)
        guard let base = URL(string: normalizedURL),
              let url = URL(string: "/v1/models", relativeTo: base) else { return offline }

        do {
            let (data, http, latency) = try await HTTPHelpers.get(url, instanceID: instance.id, session: session)
            guard http.statusCode == 200 else { return offline }
            let resp = try JSONDecoder().decode(MLXModelsResponse.self, from: data)
            guard let entries = resp.data, !entries.isEmpty else { return offline }
            if entries.contains(where: { Self.idLooksLikeGGUF($0) }) { return offline }
            // Audit-round-D28: for LOCAL endpoints the process verification
            // below is the authoritative signal — `mlx_lm.server --model
            // Qwen/Qwen3-...` is a valid MLX setup whose model ID won't
            // match `mlx-community/` or `owned_by == mlx-omni`. So we skip
            // the HTTP MLX-shape gate for local URLs and rely on argv.
            // Remote URLs still need the HTTP ID heuristic because we can't
            // inspect their process.
            if !isLocal {
                guard entries.contains(where: { Self.idLooksLikeMLX($0) }) else { return offline }
            }
            let port = base.port ?? Self.defaultPort(base.absoluteString)

            // Identify the resident model. argv is authoritative when local; /v1/models
            // is fallback (mlx-omni reports the loaded id there, mlx_lm sometimes echoes
            // the path).
            var loadedName: String?
            var pid: Int?
            var rss: Int64 = 0

            if isLocal {
                // Audit-round-D4: probe() requires a local MLX-looking process
                // — check() must enforce the same guarantee, otherwise a local
                // endpoint where lsof failed (no LISTEN row, permission denied,
                // port-reuse by an unrelated server) gets reported as active
                // MLX. Bail to offline if local process can't be confirmed.
                guard let proc = await Self.localProcessOnPort(port),
                      Self.argvLooksLikeMLX(proc.args) else { return offline }
                pid = proc.pid
                let argv = proc.args.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                loadedName = Self.extractModelArg(from: argv)
                rss = await Self.rssBytes(pid: proc.pid)
                log.debug("MLX local pid=\(proc.pid, privacy: .public) model=\(loadedName ?? "<none>", privacy: .public) rss=\(rss)")
            }
            // Pick the first MLX-shaped entry as the loaded model when argv
            // didn't surface one. Audit-round-D2: a mixed `/v1/models` response
            // (e.g. ["gpt-4o", "mlx-community/Foo-4bit"]) would otherwise have
            // us reporting `gpt-4o` as the loaded MLX model.
            if loadedName == nil {
                loadedName = entries.first(where: { Self.idLooksLikeMLX($0) })?.id
                    ?? entries.first?.id
            }

            let loaded: [LoadedModel] = loadedName.map { name in
                [LoadedModel(name: name, vramBytes: rss, expiresAt: nil)]
            } ?? []

            // Available count = union of resident model + local HF cache,
            // but only consult the cache for LOCAL instances. For a remote
            // MLX server, the operator's own `~/.cache/huggingface/hub` says
            // nothing about what the remote process can serve — counting it
            // would inflate the number with files the remote can't actually
            // load.
            var allNames: Set<String> = isLocal ? Set(Self.walkMLXCache()) : []
            if let n = loadedName { allNames.insert(n) }
            let availableCount = allNames.count

            // State machine: idle if nothing resident; generating if we see an
            // ESTABLISHED TCP peer AND the process is actually burning cycles;
            // active otherwise.
            let state: ServerState
            if loaded.isEmpty {
                state = .idle
            } else if isLocal,
                      let p = pid,
                      await LocalProbe.establishedConnectionPresent(port: port, excludingPids: [p]),
                      (localCPU ?? 0) > 20 {
                state = .generating
            } else {
                state = .active
            }

            return ServerStatus(instance: instance, detectedKind: .mlx, state: state,
                                loadedModels: loaded, availableModelCount: availableCount,
                                vramTotal: rss, lastActive: lastActive,
                                cpuPercent: localCPU, memoryMB: localMemMB,
                                clientProcess: localClientProcess, latencyMs: latency)
        } catch {
            log.debug("MLX check failed: \(String(describing: error), privacy: .public)")
            return offline
        }
    }

    // MARK: - availableModels

    func availableModels(_ instance: Instance, session: URLSession) async -> [String] {
        // /v1/models on MLX only ever returns the resident model; for LOCAL
        // instances the HF cache fills in the "what could be served if you
        // restart the process" catalog. For REMOTE instances, the local
        // cache says nothing about the remote process and would mislead the
        // UI, so we only use what `/v1/models` reports.
        //
        // Audit-round-6 + D3: gate BOTH the HTTP catalog AND the cache walk
        // on the same response-shape rules probe()/check() use. Previously
        // the cache walk fired for any local URL, so a local non-MLX endpoint
        // would still ship the user's HuggingFace MLX cache as the "available"
        // list. Now both paths only run when the HTTP shape gate confirms MLX.
        // Audit-round-D26: for LOCAL instances, do the process verification
        // BEFORE inserting any names — neither the HTTP catalog nor the
        // cache walk should be exposed unless the bound process is verified
        // MLX. For REMOTE instances, the HTTP shape gate is the only signal
        // we have.
        var names: Set<String> = []
        let normalizedURL = Self.localPortNormalizedURL(instance.url)
        // Audit-round-D28: same local/remote split as check(). For LOCAL,
        // skip the MLX-shape ID gate (the argv check below is stronger).
        // For REMOTE, the gate is required.
        let isLocalEndpoint = LocalProbe.isLocal(instance.url)
        guard let base = URL(string: normalizedURL),
              let url = URL(string: "/v1/models", relativeTo: base),
              let (data, http, _) = try? await HTTPHelpers.get(url, instanceID: instance.id, session: session),
              http.statusCode == 200,
              let resp = try? JSONDecoder().decode(MLXModelsResponse.self, from: data),
              let entries = resp.data,
              !entries.contains(where: { Self.idLooksLikeGGUF($0) }) else {
            return []
        }
        if !isLocalEndpoint {
            guard entries.contains(where: { Self.idLooksLikeMLX($0) }) else { return [] }
        }
        // Local-process verification gate for local URLs.
        var localProcessConfirmed = false
        if isLocalEndpoint {
            let port = base.port ?? Self.defaultPort(base.absoluteString)
            if let proc = await Self.localProcessOnPort(port),
               Self.argvLooksLikeMLX(proc.args) {
                localProcessConfirmed = true
            } else {
                return []   // local but no MLX process → don't expose anything
            }
        }
        // Insert HTTP-derived names. For LOCAL endpoints (argv-confirmed
        // above), trust whatever the server reports. For REMOTE endpoints,
        // filter to MLX-shaped IDs only so a mixed response doesn't leak
        // unrelated provider names.
        if isLocalEndpoint {
            entries.forEach { names.insert($0.id) }
        } else {
            entries.filter { Self.idLooksLikeMLX($0) }.forEach { names.insert($0.id) }
        }
        // Walk local cache only when local-process verification passed.
        if localProcessConfirmed {
            Self.walkMLXCache().forEach { names.insert($0) }
        }
        return names.sorted()
    }

    // MARK: - Helpers (internal for unit-test access)

    static func idLooksLikeMLX(_ model: MLXModelsResponse.Entry) -> Bool {
        // Strong positive signals only: owner is mlx-omni OR id starts with
        // the MLX community namespace. Audit-round-D24: bare `-4bit`/`-bf16`
        // suffix matching was misclassifying non-MLX quantized models on
        // remote OpenAI-compat endpoints (e.g. llama.cpp serving
        // `model-name-4bit.gguf` would skip the GGUF gate when remote and
        // pass as MLX). Suffix-only matching is no longer accepted.
        if (model.owned_by ?? "").lowercased() == "mlx-omni" { return true }
        if model.id.lowercased().hasPrefix("mlx-community/") { return true }
        return false
    }

    static func idLooksLikeGGUF(_ model: MLXModelsResponse.Entry) -> Bool {
        let lower = model.id.lowercased()
        if lower.contains("gguf") { return true }
        // Llama.cpp quant suffixes — case sensitive in canonical form, but match loosely.
        let ggufQuants = ["q4_k_m", "q5_k_m", "q8_0"]
        return ggufQuants.contains { lower.contains($0) }
    }

    static func argvLooksLikeMLX(_ argv: String) -> Bool {
        let needles = ["mlx_lm.server", "mlx-omni-server", "mlx_lm/server.py"]
        return needles.contains { argv.contains($0) }
    }

    /// Returns (pid, full-argv-string) for the local process bound to `port`, or nil.
    /// We hit `lsof -i :PORT -n -P` to find the PID, then `ps -p PID -o args=` for argv.
    ///
    /// **Documented limitation** (audit-round-D27): if multiple processes
    /// have LISTEN rows on the same port for different addresses (e.g. one
    /// on `0.0.0.0` and another on `::1`), this returns whichever lsof
    /// surfaces first. In practice MLX servers bind a single socket, so
    /// the multi-listener case is rare; users with weird setups should
    /// set the instance `kind` manually rather than relying on auto-detect.
    static func localProcessOnPort(_ port: Int) async -> (pid: Int, args: String)? {
        guard let lsofOut = await LocalProbe.runShell("/usr/sbin/lsof",
                                                      args: ["-i", ":\(port)", "-n", "-P"]) else { return nil }
        // Look specifically for a LISTEN row — that's the server, not a client connection.
        var listenPid: Int?
        for line in lsofOut.components(separatedBy: "\n") {
            guard line.contains("LISTEN") else { continue }
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.count >= 2, let p = Int(fields[1]) { listenPid = p; break }
        }
        guard let pid = listenPid else { return nil }
        guard let psOut = await LocalProbe.runShell("/bin/ps", args: ["-p", String(pid), "-o", "args="]) else {
            return nil
        }
        let args = psOut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !args.isEmpty else { return nil }
        return (pid, args)
    }

    /// Pull the value of `--model` (or `--model=X`) out of an argv array.
    ///
    /// LIMITATION: The caller currently splits `ps -o args=` output on whitespace,
    /// so model paths containing spaces are truncated at the first space. Real-world
    /// MLX model identifiers (e.g. `mlx-community/Llama-3-8B-4bit`) don't have spaces,
    /// so this is acceptable for the supported case. Users with space-bearing local
    /// paths should set the instance kind manually in Settings rather than relying
    /// on argv-mining.
    static func extractModelArg(from argv: [String]) -> String? {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--model", i + 1 < argv.count { return argv[i + 1] }
            if a.hasPrefix("--model=") { return String(a.dropFirst("--model=".count)) }
            i += 1
        }
        return nil
    }

    /// RSS for a PID in bytes (ps reports KB on macOS, we multiply by 1024).
    static func rssBytes(pid: Int) async -> Int64 {
        guard let out = await LocalProbe.runShell("/bin/ps", args: ["-p", String(pid), "-o", "rss="]) else { return 0 }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kb = Int64(trimmed) else { return 0 }
        return kb * 1024
    }

    /// Walk `~/.cache/huggingface/hub` for `models--mlx-community--*` directories
    /// and reconstruct the canonical `mlx-community/Foo-4bit` form for each one.
    ///
    /// Uses `FileManager.enumerator` (skipping descendants) so we can stop after
    /// 500 matching entries WITHOUT first materializing the full directory
    /// listing in memory. Audit-round-3 fix: the previous `contentsOfDirectory`
    /// version still read the entire listing before applying the cap.
    static func walkMLXCache() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hub = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        guard FileManager.default.fileExists(atPath: hub.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: hub,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                log.debug("walkMLXCache enumerator error: \(error.localizedDescription, privacy: .public)")
                return true   // keep going
            }
        ) else { return [] }

        let prefix = "models--mlx-community--"
        let cap = 500
        var collected: [String] = []
        collected.reserveCapacity(cap)
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            collected.append("mlx-community/" + String(name.dropFirst(prefix.count)))
            if collected.count >= cap { break }
        }
        return collected.sorted()
    }

    /// Default port for MLX servers when the URL omits one. Scheme-aware so an
    /// `https://localhost` URL maps to the HTTPS implied port `443`, matching
    /// what `localPortNormalizedURL` does (HTTPS local URLs are NOT rewritten
    /// to `:8080`). The previous version returned 8080 unconditionally, which
    /// created an HTTP/process port mismatch for port-less HTTPS loopback
    /// URLs — the probe would target `:443` while the process verification
    /// looked for an MLX process bound to `:8080`. Audit-round-D51-hard.
    ///
    /// `mlx_lm.server` defaults to `:8080`; `mlx-omni-server` requires the
    /// URL to include `:10240` explicitly (we can't infer it from a port-less
    /// URL string — by the time this is called the URL has no port).
    private static func defaultPort(_ urlString: String) -> Int {
        let lower = urlString.lowercased()
        if lower.hasPrefix("https://") { return 443 }
        return 8080
    }
}
