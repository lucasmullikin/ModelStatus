import Foundation
import Darwin

/// Local-process identification for a port-bound listener. The Sendable struct
/// lets Monitor pre-collect this per-poll and hand it off to providers via
/// `CheckRequest` instead of each provider shelling out for itself.
///
/// Architect-D53 #45 hoist: previously MLXProvider's `localProcessOnPort`
/// static was called from inside `probe`, `check`, and `availableModels` —
/// each adding 2 shell calls (lsof + ps). Now Monitor.check fetches once
/// per poll and the provider consumes the cached value.
struct LocalProcessInfo: Sendable, Equatable {
    let pid: Int
    let args: String
}

/// Local process probing — shared by all providers when the instance host is loopback.
///
/// Architect-D53 split: lifted out of Provider.swift. Internal `runShell(...)`
/// calls now route through the dedicated `Shell.run(...)` namespace; the
/// public surface (LocalProbe.isLocal / cpuFor / memoryMBFor / clientProcess /
/// establishedConnectionPresent / pidsFor) is unchanged.
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
        guard let output = await Shell.run("/usr/sbin/lsof", args: ["-i", ":\(port)", "-n", "-P"]) else { return nil }
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
        guard let output = await Shell.run("/usr/sbin/lsof",
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
        guard let out = await Shell.run("/usr/bin/pgrep", args: ["-x", processName]) else { return [] }
        return Set(out.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// Returns the (pid, full argv string) for the process bound LISTENing on
    /// `port`, or nil. Architect-D53 #45: hoisted from MLXProvider so Monitor
    /// can pre-collect once per poll instead of each provider running lsof +
    /// ps independently.
    ///
    /// **Documented limitation** (audit-round-D27): if multiple processes
    /// have LISTEN rows on the same port for different addresses (e.g. one
    /// on `0.0.0.0` and another on `::1`), this returns whichever lsof
    /// surfaces first. In practice servers bind a single socket, so the
    /// multi-listener case is rare.
    static func localProcessOnPort(_ port: Int) async -> LocalProcessInfo? {
        guard let lsofOut = await Shell.run("/usr/sbin/lsof",
                                            args: ["-i", ":\(port)", "-n", "-P"]) else { return nil }
        // LISTEN row — that's the server, not a client connection.
        var listenPid: Int?
        for line in lsofOut.components(separatedBy: "\n") {
            guard line.contains("LISTEN") else { continue }
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.count >= 2, let p = Int(fields[1]) { listenPid = p; break }
        }
        guard let pid = listenPid else { return nil }
        guard let psOut = await Shell.run("/bin/ps", args: ["-p", String(pid), "-o", "args="]) else { return nil }
        let args = psOut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !args.isEmpty else { return nil }
        return LocalProcessInfo(pid: pid, args: args)
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
        guard let output = await Shell.run("/bin/ps", args: args) else { return nil }
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
}
