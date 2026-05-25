import Foundation
import OSLog

private let discoveryLogger = Logger(subsystem: ConfigManager.bundleIdentifier, category: "discovery")

struct DiscoveredServer: Identifiable, Equatable, Sendable {
    let id = UUID()
    let host: String
    let port: Int
    let kind: ProviderKind
    let source: Source

    enum Source: String, Sendable { case lan, tailscale }

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
    /// Bracket IPv6 literals; pass IPv4/hostnames through unchanged.
    static func formatURL(host: String, port: Int) -> String {
        host.contains(":") ? "http://[\(host)]:\(port)" : "http://\(host):\(port)"
    }

    /// Common ports for the four supported providers.
    static let probeMatrix: [(port: Int, kind: ProviderKind)] = [
        (11434, .ollama),
        (1234,  .lmStudio),
        (8080,  .openAI),
        (8000,  .vllm),
        (5001,  .openAI)      // text-generation-webui
    ]

    static func scan(timeoutPerProbe: TimeInterval = 1.5) async -> [DiscoveredServer] {
        async let lan = scanLocalSubnet(timeoutPerProbe: timeoutPerProbe)
        async let tail = scanTailscalePeers(timeoutPerProbe: timeoutPerProbe)
        var combined = await lan
        combined.append(contentsOf: await tail)
        // Dedupe by host:port
        var seen = Set<String>()
        return combined.filter { seen.insert("\($0.host):\($0.port)").inserted }
    }

    // MARK: - LAN /24 scan

    private static func scanLocalSubnet(timeoutPerProbe: TimeInterval) async -> [DiscoveredServer] {
        guard let mySubnet = currentSubnetBase() else {
            discoveryLogger.debug("no IPv4 found for en0/en1; skipping LAN scan")
            return []
        }
        let hosts = (1...254).map { "\(mySubnet).\($0)" }
        return await probeHosts(hosts, source: .lan, timeoutPerProbe: timeoutPerProbe)
    }

    /// Read en0/en1 IPv4 address and return "192.168.1" for a /24.
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
        guard FileManager.default.fileExists(atPath: tsPath) else { return [] }
        guard let json = await LocalProbe.runShell(tsPath, args: ["status", "--json"]) else { return [] }
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var hosts: [String] = []
        if let peers = root["Peer"] as? [String: [String: Any]] {
            for (_, peer) in peers {
                guard let online = peer["Online"] as? Bool, online else { continue }
                if let ips = peer["TailscaleIPs"] as? [String], let first = ips.first {
                    hosts.append(first)
                }
            }
        }
        return await probeHosts(hosts, source: .tailscale, timeoutPerProbe: timeoutPerProbe)
    }

    // MARK: - Concurrent probe

    private static let maxConcurrentProbes = 64

    private static func probeHosts(_ hosts: [String], source: DiscoveredServer.Source,
                                   timeoutPerProbe: TimeInterval) async -> [DiscoveredServer] {
        let session: URLSession = {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = timeoutPerProbe
            c.timeoutIntervalForResource = timeoutPerProbe + 0.5
            c.waitsForConnectivity = false
            return URLSession(configuration: c)
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

    private static func singleProbe(host: String, port: Int, kind: ProviderKind,
                                    session: URLSession,
                                    source: DiscoveredServer.Source) async -> DiscoveredServer? {
        let path = (kind == .ollama) ? "/api/tags" : "/v1/models"
        guard let url = URL(string: "http://\(host):\(port)\(path)") else { return nil }
        do {
            let (_, resp) = try await session.data(from: url)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                return DiscoveredServer(host: host, port: port, kind: kind, source: source)
            }
        } catch {}
        return nil
    }
}
