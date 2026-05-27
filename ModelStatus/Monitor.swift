import Foundation
import OSLog

private let logger = Logger(subsystem: ConfigManager.bundleIdentifier, category: "monitor")

/// Per-instance memo state, consolidated from 5 separate dicts in pre-v0.2.
/// Codable so a future version can persist across launches to avoid the
/// "Checking…" flash on cold start.
///
/// `detectionURL` was added in audit-round-2: it lets us invalidate the cached
/// `detectedKind` when the instance's URL changes (same id, different host →
/// must re-detect rather than reusing the old provider).
///
/// `lastExpiresByModel` keys the Ollama "Generating?" heuristic by model name
/// so a list reorder or multi-model load can't false-positive .generating.
struct InstanceState: Sendable, Codable {
    var lastActive: Date?
    var lastClient: String?
    var lastReachable: Bool?
    var lastExpiresByModel: [String: String] = [:]
    var detectedKind: ProviderKind?
    var detectionURL: String?
}

/// Orchestrates polling. One actor for the whole app — owns per-instance memo state
/// and dispatches each check to the appropriate Provider.
actor Monitor {
    private var pollTask: Task<Void, Never>?
    private var state: [UUID: InstanceState] = [:]
    /// Audit-round-D3: every startPolling()/stopPolling() bumps this. An older
    /// in-flight poll captures its generation and refuses to mutate state or
    /// emit callbacks if the captured value no longer matches — so a slow
    /// provider check from a previous configuration can't pollute the new one.
    private var pollGeneration: UInt64 = 0

    /// Architect-D53 #43 (B): event delivery via AsyncStream instead of
    /// closure callbacks. The previous closures-on-the-actor pattern required
    /// `dispatchCallbacks` to do a `main → self → main` actor hop just to
    /// re-check generation between capture and invocation — the architect
    /// called this "fighting Swift Concurrency." With AsyncStream the
    /// consumer Task owns the actor it runs on (AppDelegate spawns its
    /// for-await loop on `@MainActor`), and Monitor just yields synchronously
    /// from inside its own actor context. The generation guard now happens
    /// once, in the same critical section as state mutation, with no
    /// suspension between guard and yield.
    nonisolated let statusEvents: AsyncStream<[ServerStatus]>
    nonisolated let reachabilityEvents: AsyncStream<(Instance, Bool)>
    private let statusContinuation: AsyncStream<[ServerStatus]>.Continuation
    private let reachabilityContinuation: AsyncStream<(Instance, Bool)>.Continuation

    init() {
        // Codex-v1final fix: bounded buffer (.bufferingNewest) so a slow or
        // absent consumer can't grow memory unbounded. AppDelegate spawns a
        // single MainActor consumer for each stream; if it ever falls behind
        // (e.g. user opens Settings while many instances flap reachability),
        // we keep only the most recent 16 events and drop older ones.
        // 16 is generous for "newest poll cycle" semantics — the consumer
        // only really cares about the latest state, not the full history.
        var statusCont: AsyncStream<[ServerStatus]>.Continuation!
        statusEvents = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { statusCont = $0 }
        statusContinuation = statusCont
        var reachCont: AsyncStream<(Instance, Bool)>.Continuation!
        reachabilityEvents = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { reachCont = $0 }
        reachabilityContinuation = reachCont
    }

    // v1.0 fix: URLSession's internal DNS + connection-pool caches can hold
    // negative state indefinitely when a previously-reachable server has a
    // transient mDNS / Wi-Fi / sleep-wake hiccup. The session keeps polling
    // but every probe fails the same way because nothing forces a fresh
    // resolution. Curl from the same machine works because each invocation
    // creates a brand-new resolver state. Fix: time-bound the session to 5
    // minutes; after that, invalidate and recreate. Bounds stuck-state
    // recovery to ≤ 5 min without per-instance failure tracking complexity.
    private var session: URLSession = Monitor.makeSession()
    private var sessionCreatedAt: Date = Date()

    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 10
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    /// Called at the top of each poll cycle. If the URLSession is older than
    /// the rotation threshold, invalidate it (cancels in-flight tasks and
    /// flushes connection + DNS caches) and create a fresh one. New probes
    /// in this cycle use the fresh session.
    private func recycleSessionIfStale() {
        let age = Date().timeIntervalSince(sessionCreatedAt)
        guard age >= 300 else { return }  // 5 min
        logger.notice("rotating URLSession (age \(Int(age))s) to flush DNS + connection caches")
        session.invalidateAndCancel()
        session = Monitor.makeSession()
        sessionCreatedAt = Date()
    }

    func startPolling() {
        // Don't reset `state` — preserve memoized lastActive/detectedKind/etc.
        // across Settings-induced restarts. Stale entries for removed instances
        // are pruned at the top of every poll() cycle.
        pollTask?.cancel()
        pollGeneration &+= 1
        let myGen = pollGeneration
        // v0.2.1: .notice level so this shows in the in-app LogViewer (which
        // reads OSLogStore — by default the store only persists .notice and
        // above; .debug entries are filtered out).
        logger.notice("polling started (generation \(myGen))")
        pollTask = Task {
            while !Task.isCancelled {
                let ctx = await self.poll(generation: myGen)
                // Clamp: 1s lower bound, 600s upper bound, NaN/inf → 5s default
                let safe: TimeInterval = ctx.pollInterval.isFinite ? max(1, min(600, ctx.pollInterval)) : 5
                try? await Task.sleep(nanoseconds: UInt64(safe * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        // Bump generation so any in-flight poll suspends-then-resumes with a
        // stale token and refuses to yield events or mutate state.
        pollGeneration &+= 1
        logger.notice("polling stopped (generation \(self.pollGeneration))")
    }

    /// Returns the captured `PollContext` so the run-loop can use its `pollInterval`
    /// for the sleep — making the snapshot the single source of truth for the cycle.
    /// `generation` is captured at `startPolling` time and checked before any
    /// callback emission OR state mutation so a wedged-then-resumed older cycle
    /// can't overwrite the newer cycle's view of the world.
    private func poll(generation: UInt64) async -> PollContext {
        // v1.0: rotate URLSession every 5 min to flush DNS + connection caches.
        // Must run BEFORE any probe in this cycle so a stuck session can't
        // poison the entire poll.
        recycleSessionIfStale()
        // ConfigManager is @MainActor (v0.2 step B); a single MainActor hop per cycle
        // captures everything we need for the rest of poll() to run actor-local.
        let ctx = await MainActor.run { ConfigManager.shared.snapshotForPoll() }
        // Audit-round-D4: bail BEFORE pruning state. The earlier prune ran
        // unconditionally — an old poll resuming after a config change could
        // delete state for instances valid in the newer configuration.
        guard generation == pollGeneration else { return ctx }
        let validIds = Set(ctx.instances.map { $0.id })
        state = state.filter { validIds.contains($0.key) }
        let statuses = await withTaskGroup(of: ServerStatus.self) { group in
            for inst in ctx.instances { group.addTask { await self.check(inst, generation: generation) } }
            var r: [ServerStatus] = []
            for await s in group { r.append(s) }
            return r
        }
        var map: [UUID: ServerStatus] = [:]
        for s in statuses { map[s.instance.id] = s }
        let ordered = ctx.instances.compactMap { map[$0.id] }

        // Audit-round-D3: stale-generation guard. If startPolling / stopPolling
        // ran while this poll was suspended in the task group, the captured
        // generation no longer matches and we must NOT emit callbacks. The
        // per-check generation guard inside `check` already prevents
        // state mutation, so this is the callback-emission layer.
        guard generation == pollGeneration else { return ctx }

        // Audit-round-D36: snapshot the callbacks + reachability diff under
        // actor isolation, then dispatch to MainActor for invocation. The
        // callback contract is UI-facing (AppDelegate uses them to mutate
        // currentStatuses and rebuild the menu), and AppKit requires main-
        // thread execution.
        var reachabilityEvents: [(Instance, Bool)] = []
        for s in ordered {
            let reachable = s.state != .unreachable
            if state[s.instance.id]?.lastReachable != reachable {
                state[s.instance.id, default: InstanceState()].lastReachable = reachable
                reachabilityEvents.append((s.instance, reachable))
                // v0.2.1: surface reachability transitions as .notice so users
                // see them in the LogViewer. State changes are the events
                // that matter most for "what's my server doing right now?"
                // Architect-v1final defense-in-depth: scrub the URL before
                // emitting at .public level — even though URLValidator now
                // strips user:pass@ on instance creation, scrubURL belt-and-
                // suspenders against any pre-v0.2.1 instance that bypassed
                // validation OR a future regression that re-introduces
                // credentials in the URL field.
                logger.notice("\(s.instance.name, privacy: .public) (\(Anonymizer.scrubURL(s.instance.url), privacy: .public)) → \(reachable ? "reachable" : "UNREACHABLE", privacy: .public)")
            }
        }

        // v0.2.1: per-cycle summary at .notice so the LogViewer reflects
        // live activity. One line per poll cycle: how many instances, their
        // aggregate state breakdown. Concise enough to not clutter the log.
        let stateSummary = Dictionary(grouping: ordered, by: { $0.state })
            .map { "\($0.value.count) \(String(describing: $0.key))" }
            .sorted()
            .joined(separator: ", ")
        logger.notice("poll cycle: \(ordered.count) instances [\(stateSummary, privacy: .public)]")

        // Architect-D53 #43 (B): yield to AsyncStream continuations
        // synchronously from the actor. No actor hops between the generation
        // guard above and these yields — the consumer (AppDelegate's
        // for-await loop) runs on its own actor and handles MainActor hopping
        // independently. The D52-hard dispatchCallbacks main → self → main
        // dance is gone; the stale-callback race it fought against is
        // eliminated by structure rather than guarded around.
        for ev in reachabilityEvents { reachabilityContinuation.yield(ev) }
        statusContinuation.yield(ordered)
        return ctx
    }

    /// Audit-round-D4: takes the poll's generation token and re-checks it
    /// before every state mutation that follows a suspension point. An old
    /// `check` resuming after a config change must not overwrite memoized
    /// `detectedKind` / `lastClient` / `lastActive` / etc. for an instance
    /// whose URL may have already changed.
    private func check(_ instance: Instance, generation: UInt64) async -> ServerStatus {
        let provider = await resolveProvider(for: instance, generation: generation)
        // Audit-round-D53-architect: route core poll-time local inspections
        // through `LocalSystemAccessProvider.current` so the
        // sandboxed/App-Store target actually gets fail-closed behavior here.
        // Previously the protocol existed but was bypassed — all 50+ audit
        // rounds couldn't tell because the call sites went direct.
        let lsa = LocalSystemAccessProvider.current
        let isLocal = lsa.isLocal(instance.url)
        let port = URL(string: instance.url)?.port ?? defaultPort(for: provider.kind)

        let keyword = processKeyword(for: provider.kind)
        async let cpu: Double? = (isLocal && !keyword.isEmpty) ? lsa.cpuFor(processKeyword: keyword) : nil
        async let memMB: Int? = (isLocal && !keyword.isEmpty) ? lsa.memoryMBFor(processKeyword: keyword) : nil
        async let client: String? = isLocal ? lsa.clientProcess(port: port, excludeKeywords: []) : nil
        // Architect-D53 #45: pre-collect (pid, argv) ONLY when the resolved
        // provider declares `.needsLocalProcessArgv`. For MLX, this replaces 2
        // shell calls (lsof + ps args=) that previously fired per-poll inside
        // the provider itself. Other providers (Ollama / LM Studio / vLLM /
        // OpenAI) skip the work entirely.
        let wantsArgv = isLocal && provider.capabilities.contains(.needsLocalProcessArgv)
        async let processInfo: LocalProcessInfo? = wantsArgv ? lsa.localProcessOnPort(port) : nil

        let localCPU = await cpu
        let localMem = await memMB
        let observedClient = await client
        let observedProcessInfo = await processInfo
        guard generation == pollGeneration else {
            // Stale: don't touch state. Return a placeholder offline status.
            return ServerStatus(
                instance: instance, detectedKind: provider.kind, state: .unreachable,
                loadedModels: [], availableModelCount: 0, vramTotal: 0,
                lastActive: nil, cpuPercent: nil, memoryMB: nil,
                clientProcess: nil, latencyMs: nil
            )
        }
        if let c = observedClient { state[instance.id, default: InstanceState()].lastClient = c }
        let clientProcess = state[instance.id]?.lastClient

        var status = await provider.check(CheckRequest(
            instance: instance,
            session: session,
            isLocal: isLocal,
            localCPU: localCPU,
            localMemMB: localMem,
            localClientProcess: clientProcess,
            lastActive: state[instance.id]?.lastActive,
            localProcessInfo: observedProcessInfo
        ))
        // After the provider's own async work, generation could have moved.
        guard generation == pollGeneration else { return status }

        // Remote Ollama Generating detection: when Ollama bumps expires_at between polls
        // (because inference reset the keep_alive timer), elevate .active → .generating.
        // Doesn't fire if keep_alive=-1 since the timestamp never bumps. Honest fallback.
        //
        // Per-model tracking (audit-round-2): keep a dictionary by model name so list
        // reorder, multi-model load, or load/unload churn can't false-positive elevation
        // by comparing two unrelated models' timestamps.
        //
        // Memo lifecycle (audit-round-3): replace the memo for EVERY Ollama poll where
        // we have model data, including unreachable/idle/empty-loaded states. That way
        // stale entries don't survive an unload + reload of the same model name and
        // produce a spurious .generating on the next active poll.
        if status.detectedKind == .ollama {
            if status.state == .unreachable {
                state[instance.id, default: InstanceState()].lastExpiresByModel = [:]
            } else if status.state == .active, !status.loadedModels.isEmpty {
                var bumped = false
                var nextMap: [String: String] = [:]
                let prevMap = state[instance.id]?.lastExpiresByModel ?? [:]
                for m in status.loadedModels {
                    guard let exp = m.expiresAt else { continue }
                    nextMap[m.name] = exp
                    if let prev = prevMap[m.name], prev != exp { bumped = true }
                }
                state[instance.id, default: InstanceState()].lastExpiresByModel = nextMap
                if bumped {
                    status = ServerStatus(
                        instance: status.instance, detectedKind: status.detectedKind, state: .generating,
                        loadedModels: status.loadedModels, availableModelCount: status.availableModelCount,
                        vramTotal: status.vramTotal, lastActive: status.lastActive,
                        cpuPercent: status.cpuPercent, memoryMB: status.memoryMB,
                        clientProcess: status.clientProcess, latencyMs: status.latencyMs
                    )
                }
            } else {
                // .idle (no loaded models) or .generating coming straight from
                // the provider — clear the memo so the next .active poll starts
                // fresh and can't compare against stale data.
                state[instance.id, default: InstanceState()].lastExpiresByModel = [:]
            }
        }

        // Track last-active when a new active/generating state appears
        if status.state == .active || status.state == .generating {
            state[instance.id, default: InstanceState()].lastActive = Date()
        }

        // If user picked .auto and we resolved a specific kind, record it +
        // the URL fingerprint so a later URL change invalidates the memo.
        if instance.kind == .auto && status.state != .unreachable {
            state[instance.id, default: InstanceState()].detectedKind = status.detectedKind
            state[instance.id]?.detectionURL = instance.url
        }

        // Re-emit lastActive in the status if we have a memoized one
        if status.lastActive == nil, let t = state[instance.id]?.lastActive {
            status = ServerStatus(
                instance: status.instance, detectedKind: status.detectedKind, state: status.state,
                loadedModels: status.loadedModels, availableModelCount: status.availableModelCount,
                vramTotal: status.vramTotal, lastActive: t,
                cpuPercent: status.cpuPercent, memoryMB: status.memoryMB,
                clientProcess: status.clientProcess, latencyMs: status.latencyMs
            )
        }
        return status
    }

    private func resolveProvider(for instance: Instance, generation: UInt64) async -> Provider {
        if instance.kind != .auto {
            return ProviderRegistry.provider(for: instance.kind)
        }
        // Cache hit only if BOTH the kind was previously detected AND the URL
        // hasn't changed since that detection. URL change = different host or
        // port = potentially different backend → re-detect.
        if let cached = state[instance.id],
           let detected = cached.detectedKind,
           cached.detectionURL == instance.url {
            return ProviderRegistry.provider(for: detected)
        }
        if let p = await ProviderRegistry.detect(instance, session: session) {
            // Audit-round-D5: detection awaits the registry's probes — a poll
            // generation change during that suspension means the cached
            // detection result we'd write here may be for a stale URL. Skip
            // the cache write but still return the provider for THIS poll's
            // use (callers downstream gate their own state mutations on the
            // generation).
            if generation == pollGeneration {
                state[instance.id, default: InstanceState()].detectedKind = p.kind
                state[instance.id]?.detectionURL = instance.url
                // v0.2.1: surface auto-detection so the user sees what
                // backend the app picked. Only fires on first successful
                // probe (subsequent polls hit the cached branch above).
                logger.notice("auto-detected \(String(describing: p.kind), privacy: .public) for \(instance.name, privacy: .public) (\(Anonymizer.scrubURL(instance.url), privacy: .public))")
            }
            return p
        }
        // Fallback: try OpenAI generic so we at least report unreachable cleanly
        logger.notice("auto-detect failed for \(instance.name, privacy: .public) (\(Anonymizer.scrubURL(instance.url), privacy: .public)) — falling back to OpenAI-generic")
        return OpenAIProvider()
    }

    private func defaultPort(for kind: ProviderKind) -> Int {
        switch kind {
        case .ollama:                 return 11434
        case .lmStudio:               return 1234
        case .vllm:                   return 8000
        case .mlx:                    return 8080   // mlx_lm.server default; mlx-omni-server uses 10240
        case .openAI, .auto:          return 8080
        }
    }

    private func processKeyword(for kind: ProviderKind) -> String {
        switch kind {
        case .ollama:                 return "ollama"
        case .lmStudio:               return "lmstudio"
        case .vllm:                   return "vllm"
        case .mlx:                    return "mlx"  // matches mlx_lm.server / mlx-omni-server argv
        case .openAI, .auto:          return ""    // No process binding for generic
        }
    }

    // MARK: - Per-instance actions (eject / load) dispatched to the right provider

    func ejectModel(name: String, on instance: Instance) async {
        let provider = await resolveProvider(for: instance, generation: pollGeneration)
        guard provider.capabilities.contains(.eject) else {
            logger.notice("eject not supported by provider \(String(describing: provider.kind), privacy: .public)")
            return
        }
        logger.notice("eject model \(name, privacy: .public) on \(instance.name, privacy: .public)")
        await provider.ejectModel(name, on: instance, session: session)
    }

    func loadModel(name: String, on instance: Instance) async {
        let provider = await resolveProvider(for: instance, generation: pollGeneration)
        guard provider.capabilities.contains(.loadModel) else {
            logger.notice("load not supported by provider \(String(describing: provider.kind), privacy: .public)")
            return
        }
        logger.notice("load model \(name, privacy: .public) on \(instance.name, privacy: .public)")
        await provider.loadModel(name, on: instance, session: session)
    }

    func availableModels(for instance: Instance) async -> [String] {
        let provider = await resolveProvider(for: instance, generation: pollGeneration)
        return await provider.availableModels(instance, session: session)
    }

    func capabilities(for instance: Instance) async -> ProviderCapabilities {
        await resolveProvider(for: instance, generation: pollGeneration).capabilities
    }

    func detectedKind(for instance: Instance) async -> ProviderKind {
        if instance.kind != .auto { return instance.kind }
        // Audit-round-D5: only honor the cached kind when the cached URL
        // matches — otherwise the instance URL changed and the cached kind
        // is for a different backend.
        if let cached = state[instance.id],
           let detected = cached.detectedKind,
           cached.detectionURL == instance.url {
            return detected
        }
        return .openAI
    }

    // MARK: - Local Ollama control (kept for the menu's start/stop button)

    static func isLocalOllamaRunning() async -> Bool {
        // Audit-round-D53-architect: route through LocalSystemAccess so the
        // sandboxed target fails closed (returns false, which disables the
        // start/stop menu item — correct sandbox behavior).
        let lsa = LocalSystemAccessProvider.current
        guard let output = await lsa.runShell("/bin/ps", args: ["-axo", "comm"], timeout: 6) else { return false }
        return output.split(separator: "\n").contains {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasSuffix("/ollama") || t == "ollama"
        }
    }

    static func toggleLocalOllama(start: Bool) async {
        // Audit-round-D53-architect: route brew/open/pkill through the
        // LocalSystemAccess protocol — sandboxed builds become no-ops.
        let lsa = LocalSystemAccessProvider.current
        logger.notice("\(start ? "starting" : "stopping") local Ollama")
        let brewPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            ? "/opt/homebrew/bin/brew"
            : (FileManager.default.fileExists(atPath: "/usr/local/bin/brew") ? "/usr/local/bin/brew" : nil)

        if let brew = brewPath {
            _ = await lsa.runShell(brew, args: ["services", start ? "start" : "stop", "ollama"], timeout: 12)
            if await isLocalOllamaRunning() == start {
                logger.notice("ollama \(start ? "started" : "stopped") via brew services")
                return
            }
        }

        if start {
            let appPath = "/Applications/Ollama.app"
            if FileManager.default.fileExists(atPath: appPath) {
                _ = await lsa.runShell("/usr/bin/open", args: ["-g", appPath], timeout: 6)
                logger.notice("ollama start fallback: opened \(appPath, privacy: .public)")
            } else {
                logger.notice("ollama start failed: neither brew nor /Applications/Ollama.app available")
            }
        } else {
            _ = await lsa.runShell("/usr/bin/pkill", args: ["-x", "ollama"], timeout: 6)
            logger.notice("ollama stop fallback: pkill")
        }
    }
}
