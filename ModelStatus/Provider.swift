import Foundation

enum ServerState: Equatable, Sendable {
    case generating, active, idle, unreachable
}

struct LoadedModel: Equatable, Sendable {
    let name: String
    let vramBytes: Int64
    let expiresAt: String?
}

struct ServerStatus: Equatable, Sendable {
    let instance: Instance
    let detectedKind: ProviderKind   // What the probe actually found (may differ from instance.kind if .auto)
    let state: ServerState
    let loadedModels: [LoadedModel]
    let availableModelCount: Int
    let vramTotal: Int64
    let lastActive: Date?
    let cpuPercent: Double?
    let memoryMB: Int?
    let clientProcess: String?       // Process name of who's hitting the local server (e.g. "python", "curl")
    let latencyMs: Int?

    var firstModel: String? { loadedModels.first?.name }
}

/// Capability flags — UI gates actions on these via `caps.contains(.eject)` etc.
///
/// OptionSet rather than struct-of-bools so future capabilities can be added without
/// breaking every static preset's positional initializer. Each new flag is purely additive.
struct ProviderCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let eject              = ProviderCapabilities(rawValue: 1 << 0)
    static let loadModel          = ProviderCapabilities(rawValue: 1 << 1)
    static let listAvailable      = ProviderCapabilities(rawValue: 1 << 2)
    static let reportsVRAM        = ProviderCapabilities(rawValue: 1 << 3)
    static let reportsGenerating  = ProviderCapabilities(rawValue: 1 << 4)

    // Presets ----------------------------------------------------------------

    static let ollama:   ProviderCapabilities = [.eject, .loadModel, .listAvailable, .reportsVRAM, .reportsGenerating]
    static let lmStudio: ProviderCapabilities = [.eject, .loadModel, .listAvailable]
    static let vllm:     ProviderCapabilities = [.listAvailable, .reportsVRAM]
    static let mlx:      ProviderCapabilities = [.listAvailable, .reportsVRAM, .reportsGenerating]
    static let openAI:   ProviderCapabilities = [.listAvailable]
}

/// All inputs a `Provider.check(_:)` cycle needs, bundled into one value.
///
/// Audit-round-D6 refactor: the previous 7-parameter `check` signature mixed
/// per-instance fields (`instance`, `session`, `lastActive`) with derived-on-
/// the-spot local metrics (`isLocal`, `localCPU`, `localMemMB`,
/// `localClientProcess`). Bundling them keeps the call site honest and lets a
/// future remote-only provider ignore the local-only fields without changing
/// the protocol every time.
struct CheckRequest: Sendable {
    let instance: Instance
    let session: URLSession
    let isLocal: Bool
    let localCPU: Double?
    let localMemMB: Int?
    let localClientProcess: String?
    let lastActive: Date?
}

/// One implementation per backend type. Stateless — all per-instance state lives in Monitor.
protocol Provider: Sendable {
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }

    func probe(_ instance: Instance, session: URLSession) async -> Bool
    func check(_ request: CheckRequest) async -> ServerStatus
    func ejectModel(_ name: String, on instance: Instance, session: URLSession) async
    func loadModel(_ name: String, on instance: Instance, session: URLSession) async
    func availableModels(_ instance: Instance, session: URLSession) async -> [String]
}

extension Provider {
    func ejectModel(_ name: String, on instance: Instance, session: URLSession) async {}
    func loadModel(_ name: String, on instance: Instance, session: URLSession) async {}
}

/// Registry — order matters: probe stops at first match when .auto.
enum ProviderRegistry {
    // Order matters for .auto detection: MLX must come BEFORE OpenAI because both
    // accept /v1/models, but MLX has a tighter id-pattern + port-tied process
    // gate that OpenAI's catch-all would shadow if it ran first.
    static let all: [Provider] = [
        OllamaProvider(),
        LMStudioProvider(),
        VLLMProvider(),
        MLXProvider(),
        OpenAIProvider()    // Catch-all last
    ]

    static func provider(for kind: ProviderKind) -> Provider {
        switch kind {
        case .ollama:   return OllamaProvider()
        case .lmStudio: return LMStudioProvider()
        case .vllm:     return VLLMProvider()
        case .mlx:      return MLXProvider()
        case .openAI:   return OpenAIProvider()
        case .auto:     return OpenAIProvider()  // Fallback when probe finds nothing
        }
    }

    /// Probe-based auto-detect. Returns the first provider whose probe succeeds, or nil.
    static func detect(_ instance: Instance, session: URLSession) async -> Provider? {
        for p in all {
            if await p.probe(instance, session: session) { return p }
        }
        return nil
    }
}

/// Session delegate that refuses to follow HTTP redirects on telemetry calls.
/// Audit-round-D12: without this, `URLSession` would happily follow a 3xx
/// from a permitted host to a blocked metadata IP, undercutting the
/// `DNSResolutionGuard` pre-check.
final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // refuse the redirect
    }
}

/// Shared helpers for HTTP fetches with auth header injection + streaming response size cap.
enum HTTPHelpers {
    static let maxResponseBytes = 4 * 1024 * 1024
    /// Reused across get/post. URLSession's `bytes(for:delegate:)` accepts a
    /// per-call delegate, so a single instance is safe to share.
    static let noRedirectDelegate = NoRedirectSessionDelegate()

    /// Streaming GET. Aborts the download as soon as the byte count exceeds
    /// `maxResponseBytes` instead of buffering the entire body first. The
    /// `Content-Length` veto is still cheap when the server provides it.
    ///
    /// DNS-rebinding mitigation: if the URL's host resolves to a blocked
    /// metadata IP at this moment, abort before any data crosses the wire.
    /// TOCTOU is still possible against URLSession's own resolution, but the
    /// attack window shrinks from every poll to a single in-flight race.
    static func get(_ url: URL, instanceID: UUID, session: URLSession,
                    timeout: TimeInterval = 5) async throws -> (Data, HTTPURLResponse, Int) {
        // Audit-round-D16: reject non-HTTP(S) URLs up front so a programmatic
        // construction error can't slip a `file:`/`ftp:`/other-scheme request
        // through. URLValidator already gates user input at config time; this
        // is a defense in depth at the helper boundary.
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        if let host = url.host, DNSResolutionGuard.resolvesToBlockedAddress(host) {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        if let h = Keychain.authHeader(for: instanceID), !h.isEmpty {
            req.setValue(h, forHTTPHeaderField: "Authorization")
        }
        let start = Date()
        // Audit-round-D12: pass the no-redirect delegate so a 3xx response
        // from a permitted host can't redirect us to a blocked metadata IP.
        let (bytes, resp) = try await session.bytes(for: req, delegate: noRedirectDelegate)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // Veto on advertised length first — saves us iterating one wasted byte.
        if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
           let len = Int(lenStr), len > maxResponseBytes {
            throw URLError(.dataLengthExceedsMaximum)
        }
        // Stream into a Data buffer; abort the moment we exceed the cap.
        var data = Data()
        data.reserveCapacity(min(maxResponseBytes, 64 * 1024))
        for try await byte in bytes {
            if data.count >= maxResponseBytes {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        return (data, http, latency)
    }

    /// POST with the same response-size cap as `get`. Streams the response and
    /// aborts the moment the cap is exceeded. Audit-round-8 fix: the previous
    /// version used `session.data(for:)`, which buffers the whole body and
    /// undercut the shared "all HTTP fetches are capped" guarantee.
    static func post(_ url: URL, body: [String: Any], instanceID: UUID,
                     session: URLSession, timeout: TimeInterval = 10) async throws -> HTTPURLResponse {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        if let host = url.host, DNSResolutionGuard.resolvesToBlockedAddress(host) {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let h = Keychain.authHeader(for: instanceID), !h.isEmpty {
            req.setValue(h, forHTTPHeaderField: "Authorization")
        }
        // Propagate JSON serialization failures rather than silently sending no body.
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = timeout
        let (bytes, resp) = try await session.bytes(for: req, delegate: noRedirectDelegate)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
           let len = Int(lenStr), len > maxResponseBytes {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var count = 0
        for try await _ in bytes {
            count += 1
            if count > maxResponseBytes {
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        return http
    }
}

/// Local process probing — shared by all providers when the instance host is loopback.
enum LocalProbe {
    static func isLocal(_ url: String) -> Bool {
        guard var h = URL(string: url)?.host else { return false }
        // Audit-round-D13: defensively strip IPv6 brackets if the underlying
        // URL parser left them. URLComponents normally strips them but
        // `URL(string:).host` behavior has varied across SDKs.
        h = h.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") {
            h = String(h.dropFirst().dropLast())
        }
        if h.hasSuffix(".") { h.removeLast() }
        // `0.0.0.0` and `::` are the IPv4/IPv6 *unspecified* addresses, used
        // as a wildcard bind. We treat them as local because in practice they
        // appear when a local server binds to all interfaces — the client
        // (this app) connects via loopback. Audit-round-D17.
        if h == "localhost" || h == "0.0.0.0" || h == "::" { return true }
        // IPv4 path — `inet_aton` accepts a.b.c.d, a.b.c, a.b, a (and hex/oct).
        var v4 = in_addr()
        if h.withCString({ inet_aton($0, &v4) }) == 1 {
            let hostOrder = UInt32(bigEndian: v4.s_addr)
            // 127.0.0.0/8 — high octet == 127.
            return (hostOrder >> 24) == 127
        }
        // IPv6 path — inet_pton parses every textual form, including
        // `[0:0:0:0:0:0:0:1]` (URLComponents strips the brackets) and
        // `::ffff:127.0.0.1` (IPv4-mapped). Compare against canonical loopback.
        var v6 = in6_addr()
        if h.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            // Canonical ::1 has 15 zero bytes followed by 0x01.
            var buf = [UInt8](repeating: 0, count: 16)
            withUnsafeBytes(of: v6) { rawBuf in
                buf = Array(rawBuf.bindMemory(to: UInt8.self))
            }
            if buf == [0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,1] { return true }
            // IPv4-mapped form: ::ffff:a.b.c.d. Check that high 80 bits are 0,
            // next 16 are 0xffff, then bottom 32 is IPv4-shaped — and the IPv4
            // half is in 127/8.
            let highZero = buf[0...9].allSatisfy { $0 == 0 }
            let ffMarker = buf[10] == 0xff && buf[11] == 0xff
            if highZero && ffMarker && buf[12] == 127 { return true }
        }
        return false
    }

    static func cpuFor(processKeyword: String) async -> Double? {
        await shellMetricDouble(args: ["-eo", "pcpu,comm"], keyword: processKeyword)
    }

    static func memoryMBFor(processKeyword: String) async -> Int? {
        guard let kb = await shellMetricDouble(args: ["-eo", "rss,comm"], keyword: processKeyword) else { return nil }
        return Int(kb / 1024)
    }

    /// Return the process name of whoever is currently talking to a local server on `port`.
    /// Despite the surface meaning of "client", returning the IP would always be 127.0.0.1
    /// for loopback connections — the process name (e.g. "python", "curl", "Claude") is the
    /// useful identifier. Skips known SERVER process names (Ollama, LM Studio, vLLM,
    /// MLX, plus this app's own process) so non-Ollama backends don't get
    /// reported as their own client. Audit-round-D4.
    static func clientProcess(port: Int, excludeKeywords: [String] = []) async -> String? {
        guard let output = await runShell("/usr/sbin/lsof", args: ["-i", ":\(port)", "-n", "-P"]) else { return nil }
        // Server-process exclusion list (audit-round-D5): only include names
        // that are unambiguously server binaries. `python` and `node` were
        // previously listed because they're often used to RUN MLX/llama.cpp
        // servers — but they're also the most common API CLIENT names. Global
        // exclusion drops legitimate clients. Accept the small false-positive
        // (an MLX-as-python server may appear as its own client) over a broken
        // client-process display for the common Python/Node case.
        let serverProcessNames = [
            "ollama", "lmstudio", "lm-studio", "vllm",
            "mlx_lm", "mlx-omni"
        ]
        let normalizedExclusions = excludeKeywords.map { $0.lowercased() }
        for line in output.components(separatedBy: "\n") {
            let firstField = line.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased() ?? ""
            // Audit-round-D17: caller-provided exclusions compared
            // case-insensitively against the normalized first field, not
            // raw line prefixes (lsof formatting varies; case can drift).
            if normalizedExclusions.contains(where: { firstField.hasPrefix($0) }) { continue }
            // App self-exclusion (truncated by lsof to 9 chars).
            if line.contains("OllamaSta") || line.contains("ModelStat") { continue }
            // Server-process exclusion: don't report the server as its own client.
            if serverProcessNames.contains(where: { firstField.hasPrefix($0) }) { continue }
            // Audit-round-D47: for the CLIENT row, the REMOTE endpoint (right
            // of `->`) ends in `:<port>` — the local endpoint is an ephemeral
            // outbound port. The D46 fix had this inverted, biasing toward
            // server-side rows. `establishedConnectionPresent` correctly
            // wants the LOCAL side (server's listening socket), but
            // `clientProcess` wants the REMOTE side.
            if line.contains("ESTABLISHED"), line.contains("->"),
               Self.lineHasRemotePort(line, port: port),
               let proc = line.split(whereSeparator: { $0.isWhitespace }).first {
                return String(proc)
            }
        }
        return nil
    }

    /// Audit-round-D46/D47: lsof NAME column has the form `local->remote` where
    /// each side is `host:port`.
    nonisolated private static func lineHasLocalPort(_ line: String, port: Int) -> Bool {
        guard let arrowRange = line.range(of: "->") else { return false }
        let leftSlice = line[..<arrowRange.lowerBound]
        guard let local = leftSlice.split(whereSeparator: { $0.isWhitespace }).last else { return false }
        return local.hasSuffix(":\(port)")
    }

    /// Audit-round-D47: returns true iff the REMOTE side (right of `->`)
    /// ends in `:port` — the shape we want when looking for a CLIENT row
    /// connecting to a local listening server.
    nonisolated private static func lineHasRemotePort(_ line: String, port: Int) -> Bool {
        guard let arrowRange = line.range(of: "->") else { return false }
        let rightSlice = line[arrowRange.upperBound...]
        // The remote endpoint runs until whitespace or end-of-line.
        guard let remote = rightSlice.split(whereSeparator: { $0.isWhitespace }).first else { return false }
        return remote.hasSuffix(":\(port)")
    }

    static func establishedConnectionPresent(port: Int, excludingPids: Set<Int>) async -> Bool {
        let myPid = Int(ProcessInfo.processInfo.processIdentifier)
        // Audit-round-D46: query lsof's full NAME column so we can verify the
        // LOCAL endpoint owns the target port (left of `->`). The terse `-t`
        // form returns PIDs without addresses and can include processes whose
        // outbound connection happens to use the same remote port. Filter by
        // left-of-arrow port match.
        guard let output = await runShell("/usr/sbin/lsof",
                                          args: ["-i", "TCP:\(port)", "-s", "TCP:ESTABLISHED", "-n", "-P"]) else { return false }
        var pids = Set<Int>()
        for line in output.components(separatedBy: "\n") {
            guard line.contains("->"), Self.lineHasLocalPort(line, port: port) else { continue }
            // lsof column 1 is PID.
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, let pid = Int(fields[1]) else { continue }
            pids.insert(pid)
        }
        return !pids.subtracting(excludingPids.union([myPid])).isEmpty
    }

    static func pidsFor(processName: String) async -> Set<Int> {
        guard let out = await runShell("/usr/bin/pgrep", args: ["-x", processName]) else { return [] }
        return Set(out.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// Sum a `ps` numeric column (CPU%, RSS-KB) for processes whose **command
    /// basename** contains `keyword`. Audit-round-3 fix: matching the whole `ps`
    /// line — including args — caused `ollama` to grab the app's own process
    /// name (`OllamaStatus` legacy, `ModelStatus` current). We now isolate the
    /// command column and skip our own bundle's processes.
    ///
    /// Audit-round-5: distinguish "no matching process / shell failed" (nil)
    /// from "process found but its metric is zero" (0.0). An idle local server
    /// will routinely report 0% CPU — collapsing that into nil would tell the
    /// UI "unknown" when it should be "idle".
    private static func shellMetricDouble(args: [String], keyword: String) async -> Double? {
        guard !keyword.isEmpty else { return nil }   // Never match-all
        let needle = keyword.lowercased()
        guard let output = await runShell("/bin/ps", args: args) else { return nil }
        var total: Double = 0
        var matched = false
        let selfExcludes = ["modelstatus", "ollamastatus"]
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let fields = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 2 else { continue }
            // ps with `-o pcpu,comm` or `-o rss,comm` emits column 0 = metric,
            // column 1+ = command path. Match on the LAST path component so
            // `/Applications/Ollama.app/Contents/MacOS/ollama` matches `ollama`
            // but `/Users/.../ModelStatus.app/Contents/MacOS/ModelStatus`
            // matches its own name (which we exclude).
            let cmdField = fields[1].lowercased()
            let basename = cmdField.split(separator: "/").last.map(String.init) ?? cmdField
            if selfExcludes.contains(where: { basename.contains($0) }) { continue }
            guard basename.contains(needle) else { continue }
            matched = true
            if let val = Double(fields[0]) { total += val }
        }
        return matched ? total : nil
    }

    /// Maximum stdout bytes a single shell invocation may produce. Beyond this
    /// the child is SIGTERM'd and what we have so far is returned. Keeps a
    /// runaway / noisy binary from forcing unbounded memory use.
    static let maxShellOutputBytes = 4 * 1024 * 1024

    /// Hardened (v0.2 D-revised): streams stdout via `readabilityHandler`,
    /// drains any remaining pipe data once the child exits before resuming
    /// (so output isn't truncated when the child dies before the readability
    /// callback drains its last chunk), caps the buffer at `maxShellOutputBytes`,
    /// and escalates SIGTERM → SIGKILL on a two-stage deadline. A single-fire
    /// latch ensures the continuation resumes exactly once even when multiple
    /// resolution paths race.
    ///
    /// Scope-down note (per v0.2 security blocker B3): we kill the immediate child only,
    /// not the process group. Every caller in ModelStatus invokes a known binary with
    /// explicit argv (`/bin/ps`, `/usr/sbin/lsof`, `/usr/bin/pgrep`, `/usr/bin/open`,
    /// `/usr/bin/pkill`, `/opt/homebrew/bin/brew`). None of these fork grandchildren that
    /// outlive SIGKILL. If a future call site needs `/bin/sh -c`, add process-group kill
    /// via `posix_spawn` + `POSIX_SPAWN_SETPGROUP` first.
    static func runShell(_ path: String, args: [String], timeout: TimeInterval = 5) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            // Mutable state lives in a reference type so closures that fire on
            // arbitrary GCD threads (readabilityHandler, terminationHandler, kill
            // timers) can share it without Sendable copy semantics. Access is
            // serialized through `sync` — the @unchecked annotation is honest.
            final class State: @unchecked Sendable {
                var buffer = Data()
                var resumed = false
                var capExceeded = false
                var terminated = false
                var detached = false   // Audit-round-D50-hard: idempotent latch
            }
            let state = State()
            let sync = DispatchQueue(label: "modelstatus.runshell.sync")
            let readFH = pipe.fileHandleForReading

            // Audit-round-D14/D50-hard: detach SYNCHRONOUSLY and IDEMPOTENTLY
            // under the sync queue. FileHandle's `readabilityHandler = nil`
            // is documented safe from any thread, but doing it through the
            // single serialization queue both makes the ordering with
            // buffer-append callbacks explicit AND ensures only the first
            // detach call performs the nil-assignment — subsequent calls
            // become no-ops. The previous version could fire from the
            // readability callback, `tryFinish`, the proc.run failure path,
            // and the backstop, with no formal ordering guarantee between
            // them.
            let detachHandler: @Sendable () -> Void = {
                sync.sync {
                    guard !state.detached else { return }
                    state.detached = true
                    readFH.readabilityHandler = nil
                }
            }

            // Audit-round-D46: dedicated SIGKILL escalation for the
            // cap-exceeded path. If a child ignores SIGTERM after we hit the
            // 4 MiB stdout cap, the only existing escalation lives on the
            // general timeout schedule (timeout + 2s for SIGKILL). For a
            // noisy fast-emitting child, that can mean an extra 5–10s of
            // resource consumption. A cap-specific SIGKILL at +500ms keeps
            // the bound tight without changing the happy-path behavior.
            let capKillWorkItem = DispatchWorkItem {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
            readFH.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    // Writer side closed → no more data coming. Detach the handler so
                    // GCD stops dispatching. terminationHandler drains + resumes.
                    detachHandler()
                    return
                }
                let exceeded = sync.sync { () -> Bool in
                    if state.buffer.count + chunk.count > maxShellOutputBytes {
                        state.capExceeded = true
                        return true
                    }
                    state.buffer.append(chunk)
                    return false
                }
                if exceeded && proc.isRunning {
                    proc.terminate()
                    DispatchQueue.global(qos: .utility)
                        .asyncAfter(deadline: .now() + 0.5, execute: capKillWorkItem)
                }
            }

            // Single-fire finalizer. Called from terminationHandler, the SIGKILL
            // backstop, or — if the kernel somehow doesn't reap — a fallback timer.
            // Drains remaining pipe data ONLY when we're sure the writer side is
            // closed (process terminated OR we've explicitly given up). Audit-
            // round-3 fix: a blind `readToEnd()` from the never-terminated backstop
            // path could deadlock if the child was still alive and holding the pipe.
            //
            // Audit-round-4 fix: when `capExceeded` is set, return nil so callers
            // (ps / lsof / pgrep parsers) fail closed instead of acting on a
            // truncated mid-line buffer.
            //
            // Audit-round-6 fix: don't explicitly close `readFH` here. Closing
            // can race a still-queued `readabilityHandler` callback or a not-yet-
            // reaped child. The Pipe/Process owners deinit will close cleanly
            // once everything releases; that's the safe path.
            let tryFinish: @Sendable () -> Void = {
                // Audit-round-D21: single-fire latch first, then conditional
                // drain ONLY when the process has been observed terminated
                // (kernel closed the writer-side fd, so readToEnd returns
                // immediately without blocking — no hang risk). For paths
                // where termination wasn't observed (cap-exceeded mid-stream,
                // run-failure), skip the drain and resume with what we have.
                let shouldResume = sync.sync { () -> Bool in
                    if state.resumed { return false }
                    state.resumed = true
                    return true
                }
                guard shouldResume else { return }
                detachHandler()
                let terminated = sync.sync { state.terminated }
                if terminated {
                    // Wait for any in-flight readability callback to finish
                    // its sync.sync append before we drain. Then read the
                    // remaining bytes — the writer's closed at this point,
                    // so readToEnd is non-blocking.
                    sync.sync {}
                    if let tail = try? readFH.readToEnd(), !tail.isEmpty {
                        sync.sync {
                            if state.buffer.count + tail.count > maxShellOutputBytes {
                                state.capExceeded = true
                            } else {
                                state.buffer.append(tail)
                            }
                        }
                    }
                }
                let (buffer, capped) = sync.sync { (state.buffer, state.capExceeded) }
                if capped {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: String(data: buffer, encoding: .utf8))
                }
            }

            // Audit-round-D19: create the timeout work items + the
            // terminationHandler wrapping BEFORE proc.run() so a very fast
            // process can't exit in the window between run() and our
            // post-run setup. The handler installed here cancels the timers
            // when terminationHandler fires.
            let termWorkItem = DispatchWorkItem {
                if proc.isRunning { proc.terminate() }
            }
            let killWorkItem = DispatchWorkItem {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
            let backstopWorkItem = DispatchWorkItem {
                let alreadyTerminated = sync.sync { state.terminated }
                if !alreadyTerminated {
                    sync.sync { state.capExceeded = true }
                    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                }
                tryFinish()
            }
            proc.terminationHandler = { _ in
                termWorkItem.cancel()
                killWorkItem.cancel()
                backstopWorkItem.cancel()
                capKillWorkItem.cancel()
                sync.sync { state.terminated = true }
                tryFinish()
            }

            do {
                try proc.run()
            } catch {
                // Failure-path resume must go through the same single-fire latch
                // so a callback that already armed itself can't double-resume.
                // Audit-round-D17: detach + resume INSIDE the shouldResume
                // branch so a parallel callback path's teardown isn't
                // interfered with when the latch is already fired.
                let shouldResume = sync.sync { () -> Bool in
                    if state.resumed { return false }
                    state.resumed = true
                    return true
                }
                if shouldResume {
                    detachHandler()
                    continuation.resume(returning: nil)
                }
                return
            }

            // Schedule the timers. The work items were created above; the
            // terminationHandler wrapper cancels them on clean exit.
            let killQueue = DispatchQueue.global(qos: .utility)
            killQueue.asyncAfter(deadline: .now() + timeout, execute: termWorkItem)
            killQueue.asyncAfter(deadline: .now() + timeout + 2.0, execute: killWorkItem)
            killQueue.asyncAfter(deadline: .now() + timeout + 3.0, execute: backstopWorkItem)
        }
    }
}
