import Foundation
import OSLog
import Security

private let discoveryLogger = Logger(subsystem: ConfigManager.bundleIdentifier, category: "discovery")

/// Verify a binary on disk passes static-signature validation AND is signed
/// by Tailscale's signing team with one of Tailscale's known bundle
/// identifiers. Audit-round-D13: in addition to the identifier match, we
/// now pin the Apple developer Team ID (`W5364U7YZB`) so a maliciously-
/// signed binary spoofing the bundle identifier with a different team's
/// certificate would be rejected.
///
/// Tradeoff: if Tailscale ever changes their signing Team ID, this check
/// will fail closed (the Tailscale scan path simply returns no peers, which
/// is the safe outcome — better than running an untrusted binary).
///
/// What this defends against:
///   • Unsigned binaries planted at the expected path.
///   • Tampered/invalid signatures.
///   • Signed binaries from an unrelated developer/team.
/// What it does NOT defend against:
///   • A binary actually signed by Tailscale that has been compromised
///     upstream. Out of scope at the OS-app-trust layer.
@_silgen_name("SecStaticCodeCreateWithPath")
private func _SecStaticCodeCreateWithPathShim(_ url: CFURL, _ flags: SecCSFlags, _ out: UnsafeMutablePointer<SecStaticCode?>) -> OSStatus

private func verifyCodeSignature(atPath path: String) -> Bool {
    let url = URL(fileURLWithPath: path) as CFURL
    var staticCode: SecStaticCode?
    guard _SecStaticCodeCreateWithPathShim(url, [], &staticCode) == errSecSuccess,
          let code = staticCode else { return false }
    // Step 1: generic validity (signed at all, not tampered).
    guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
    // Step 2: bundle-identifier + team-ID pinning. Tailscale ships under
    // two known bundle IDs; both are signed by team W5364U7YZB. Pinning
    // the team rejects a bundle-ID-spoofed binary signed by anyone else.
    // Audit-round-D14: single-line requirement string. The earlier raw
    // multi-line form had literal backslashes (raw strings don't honor `\`
    // as line-continuation), which `SecRequirementCreateWithString` would
    // reject — silently failing the whole Tailscale scan.
    let requirementText = #"(identifier "io.tailscale.ipn.macsys" or identifier "io.tailscale.ipn.macos") and anchor apple generic and certificate leaf[subject.OU] = "W5364U7YZB""#
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
          let req = requirement else { return false }
    return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
}

struct DiscoveredServer: Identifiable, Equatable, Hashable, Sendable {
    let host: String
    let port: Int
    let kind: ProviderKind
    let source: Source

    enum Source: String, Sendable { case lan, tailscale }

    /// Stable identity derived from the same fields used for equality and dedupe.
    /// Audit-round-3: a fresh `UUID()` per construction made SwiftUI list
    /// diffing replace identical rediscoveries — `host:port|kind|source` keeps
    /// the same row identity across scans.
    var id: String { "\(host):\(port)|\(kind.rawValue)|\(source.rawValue)" }

    var suggestedName: String {
        if source == .tailscale {
            let short = host.split(separator: ".").first.map(String.init) ?? host
            return "\(short) (\(kind.displayName))"
        }
        return "\(host) (\(kind.displayName))"
    }

    var url: String { Discovery.formatURL(host: host, port: port) }
}

/// One-shot network discovery. Probes the local /24 + Tailscale peers in parallel.
/// On-demand only — never auto-runs.
enum Discovery {
    /// Bracket IPv6 literals; pass IPv4/hostnames through unchanged. Idempotent —
    /// if the host is already bracketed (`[fd7a::1]`), don't double-bracket it.
    static func formatURL(host: String, port: Int) -> String {
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return "http://\(host):\(port)"
        }
        return host.contains(":") ? "http://[\(host)]:\(port)" : "http://\(host):\(port)"
    }

    /// Common ports for the supported providers. Discovery does a shallow
    /// HTTP-200 check; the user's added instance is resolved to a concrete
    /// provider on first poll via `ProviderRegistry.detect`. So 8080 / 10240
    /// are listed as `.openAI` here even though MLXProvider may end up handling
    /// them — the deep MLX checks (argv, id patterns) belong in MLXProvider.probe,
    /// not in a /24 port scan.
    static let probeMatrix: [(port: Int, kind: ProviderKind)] = [
        (11434, .ollama),
        (1234,  .lmStudio),
        (8080,  .openAI),     // mlx_lm.server default + many OpenAI-compat tools
        (10240, .openAI),     // mlx-omni-server default
        (8000,  .vllm),
        (5001,  .openAI)      // text-generation-webui
    ]

    static func scan(timeoutPerProbe: TimeInterval = 1.5) async -> [DiscoveredServer] {
        // v0.2.1: .notice level so Discovery activity shows in the in-app
        // LogViewer. Without this the user clicks Discover and sees no
        // record of the scan having run.
        discoveryLogger.notice("scan started (LAN /24 + Tailscale peers)")
        async let lan = scanLocalSubnet(timeoutPerProbe: timeoutPerProbe)
        async let tail = scanTailscalePeers(timeoutPerProbe: timeoutPerProbe)
        let lanResults = await lan
        let tailResults = await tail
        discoveryLogger.notice("scan results: LAN=\(lanResults.count), Tailscale=\(tailResults.count)")
        var combined = lanResults
        combined.append(contentsOf: tailResults)
        // Dedupe on the full identity tuple (host:port|kind|source). Matches the
        // semantics of `DiscoveredServer.id` and `==` so the three notions of
        // uniqueness stay aligned (audit-round-3).
        var seen = Set<String>()
        let deduped = combined.filter { seen.insert($0.id).inserted }
        discoveryLogger.notice("scan complete: \(deduped.count) unique server(s) discovered")
        return deduped
    }

    // MARK: - LAN /24 scan

    private static func scanLocalSubnet(timeoutPerProbe: TimeInterval) async -> [DiscoveredServer] {
        guard let mySubnet = currentSubnetBase() else {
            discoveryLogger.notice("LAN scan skipped: no active IPv4 interface (en0/en1) found")
            return []
        }
        discoveryLogger.notice("LAN scan: probing \(mySubnet).1-254 on common model-server ports")
        let hosts = (1...254).map { "\(mySubnet).\($0)" }
        return await probeHosts(hosts, source: .lan, timeoutPerProbe: timeoutPerProbe)
    }

    /// Read the first active non-loopback IPv4 interface address and derive
    /// the /24 base. Audit-round-D46 documented limitation: we explicitly
    /// assume a /24 LAN and only scan `en*` interfaces (Ethernet/Wi-Fi).
    ///
    /// Networks on /23, /22, /25, /16, or other masks will have a different
    /// host range than the 1..254 we probe. We accept this trade-off because:
    /// (1) /24 is the overwhelmingly common home/SOHO mask where this app
    /// runs, (2) probing /16 (~65k hosts) would be a denial-of-service on
    /// the LAN and our own URLSession pool, (3) reading the real netmask
    /// from `ifa_netmask` and skipping non-/24 nets is an option but adds
    /// complexity for a discovery feature that already gracefully degrades
    /// — users on non-/24 LANs simply add servers manually.
    ///
    /// `bridge*`, `utun*`, `awdl*`, etc. are intentionally skipped — they're
    /// usually internal interfaces (Thunderbolt-bridge, Tailscale, AWDL)
    /// whose IP space doesn't host LAN peers.
    private static func currentSubnetBase() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let sockaddr = cur.pointee.ifa_addr else { continue }
            let flags = Int32(cur.pointee.ifa_flags)
            let family = sockaddr.pointee.sa_family
            guard (flags & (IFF_UP|IFF_RUNNING)) == (IFF_UP|IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0,
                  family == AF_INET else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sockaddr,
                           socklen_t(sockaddr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                let parts = ip.split(separator: ".")
                if parts.count == 4 {
                    return "\(parts[0]).\(parts[1]).\(parts[2])"
                }
            }
        }
        return nil
    }

    // MARK: - Tailscale

    private static func scanTailscalePeers(timeoutPerProbe: TimeInterval) async -> [DiscoveredServer] {
        let tsPath = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        guard FileManager.default.fileExists(atPath: tsPath) else {
            discoveryLogger.notice("Tailscale scan skipped: /Applications/Tailscale.app not installed")
            return []
        }
        discoveryLogger.notice("Tailscale scan: querying peers via `tailscale status --json`")
        // Security: verify the binary at that path is codesigned by Tailscale
        // before executing it. Audit-round-D17 known limitation: there is a
        // narrow TOCTOU window between this verifyCodeSignature() call and
        // the LocalProbe.runShell() exec. A local attacker with write access
        // to `/Applications/Tailscale.app/Contents/MacOS/` could in principle
        // swap the binary between the two. Mitigating fully would require
        // verify-and-exec atomicity (e.g. fexecve on an fd we hold open),
        // which Foundation `Process` doesn't expose. Out of scope at this
        // layer — a local attacker with `/Applications` write access already
        // controls the user's account-level execution surface.
        guard verifyCodeSignature(atPath: tsPath) else {
            discoveryLogger.error("refusing to exec Tailscale binary — code signature verification failed for \(tsPath, privacy: .public)")
            return []
        }
        // Audit-round-D53-architect: route through LocalSystemAccess so the
        // sandboxed target gets nil and Tailscale discovery silently fails
        // (correct sandbox behavior — Process exec isn't allowed there).
        guard let json = await LocalSystemAccessProvider.current
                .runShell(tsPath, args: ["status", "--json"], timeout: 6) else { return [] }
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var hosts: [String] = []
        var seenHosts = Set<String>()
        if let peers = root["Peer"] as? [String: [String: Any]] {
            for (_, peer) in peers {
                guard let online = peer["Online"] as? Bool, online else { continue }
                // Audit-round-D16: probe ALL addresses for each online peer
                // — a peer with both IPv4 + IPv6 can have its primary
                // address unreachable in some network contexts while the
                // secondary is fine. The cost is that a multi-address peer
                // may produce multiple `DiscoveredServer` entries (one per
                // address that responded successfully). This is intentional:
                // dedupe at `DiscoveredServer.id` is by `host:port|kind|source`,
                // which differs by address — letting the user pick which
                // address to add. Document the trade-off rather than
                // hide it.
                if let ips = peer["TailscaleIPs"] as? [String] {
                    // Drop empties and dedupe so a peer with a duplicated
                    // address doesn't trigger redundant probes. Audit-round-D23:
                    // O(1) Set membership instead of O(n²) Array.contains.
                    for ip in ips {
                        let trimmed = ip.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty && !seenHosts.contains(trimmed) {
                            seenHosts.insert(trimmed)
                            hosts.append(trimmed)
                        }
                    }
                }
            }
        }
        return await probeHosts(hosts, source: .tailscale, timeoutPerProbe: timeoutPerProbe)
    }

    // MARK: - Concurrent probe

    private static let maxConcurrentProbes = 64

    private static func probeHosts(_ hosts: [String], source: DiscoveredServer.Source,
                                   timeoutPerProbe: TimeInterval) async -> [DiscoveredServer] {
        // Audit-round-D14: set the no-redirect delegate at SESSION level so
        // the redirect-decision callback is guaranteed to fire. The per-task
        // delegate form was correct in modern URLSession APIs but the
        // session-level form removes ambiguity.
        let delegate = NoRedirectDelegate()
        let session: URLSession = {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = timeoutPerProbe
            c.timeoutIntervalForResource = timeoutPerProbe + 0.5
            c.waitsForConnectivity = false
            return URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
        }()
        defer { session.finishTasksAndInvalidate() }

        var work: [(host: String, port: Int, kind: ProviderKind)] = []
        for host in hosts {
            for (port, kind) in probeMatrix {
                work.append((host, port, kind))
            }
        }

        return await withTaskGroup(of: DiscoveredServer?.self) { group in
            var inFlight = 0
            var iter = work.makeIterator()
            var found: [DiscoveredServer] = []

            // Prime the pump up to the concurrency cap
            while inFlight < maxConcurrentProbes, let w = iter.next() {
                group.addTask { await singleProbe(host: w.host, port: w.port, kind: w.kind, session: session, source: source) }
                inFlight += 1
            }
            // Drain + refill: one out, one in
            while let result = await group.next() {
                inFlight -= 1
                if let r = result { found.append(r) }
                if let w = iter.next() {
                    group.addTask { await singleProbe(host: w.host, port: w.port, kind: w.kind, session: session, source: source) }
                    inFlight += 1
                }
            }
            return found
        }
    }

    /// URLSessionTaskDelegate that refuses to follow HTTP redirects. Audit-round-D3:
    /// a probed LAN host that returns a 3xx pointing at another host can otherwise
    /// trick discovery into reporting the original host:port as a real model server.
    /// Worse, it would cause discovery to make follow-up requests to redirect targets
    /// outside the intended scan scope.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)   // refuse the redirect
        }
    }

    private static func singleProbe(host: String, port: Int, kind: ProviderKind,
                                    session: URLSession,
                                    source: DiscoveredServer.Source) async -> DiscoveredServer? {
        let path = (kind == .ollama) ? "/api/tags" : "/v1/models"
        // Route IPv6 literals through formatURL so brackets are added — otherwise
        // IPv6 Tailscale peer addresses silently fail URL parsing.
        guard let url = URL(string: "\(formatURL(host: host, port: port))\(path)") else { return nil }
        // Audit-round-D2 security finding: route through a streaming probe so a
        // hostile LAN host returning a giant body can't blow up memory during a
        // /24 scan (up to ~64 concurrent probes).
        // Audit-round-D3: refuse redirects + check status BEFORE draining body
        // so non-200 responses don't waste scan budget reading bytes we'll ignore.
        // Audit-round-D18: the redirect delegate is now configured at the
        // SESSION level (see probeHosts) so we don't need a per-request one.
        do {
            let (bytes, resp) = try await session.bytes(from: url)
            guard let http = resp as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else { return nil }
            // Audit-round-D16: collect with an OVER-cap (256 KB) so we can
            // detect a "truncated mid-JSON" case explicitly. Real /api/tags
            // and /v1/models payloads are typically <10 KB; if a response
            // exceeds 256 KB we treat it as "too large to validate as a
            // model-server response" and reject rather than parse a partial.
            let parseCap = 256 * 1024
            var preview = Data()
            var truncated = false
            for try await byte in bytes {
                preview.append(byte)
                if preview.count > parseCap {
                    truncated = true
                    break
                }
            }
            if truncated { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: preview) as? [String: Any] else {
                return nil
            }
            if kind == .ollama {
                guard json["models"] is [Any] else { return nil }
            } else {
                // OpenAI-compat: object="list" + data is an array
                guard (json["object"] as? String) == "list",
                      json["data"] is [Any] else { return nil }
            }
            return DiscoveredServer(host: host, port: port, kind: kind, source: source)
        } catch {}
        return nil
    }
}
