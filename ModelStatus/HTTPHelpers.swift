import Foundation
import OSLog

private let httpLog = Logger(subsystem: ConfigManager.bundleIdentifier, category: "http")

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
///
/// Architect-D53 split: lifted out of Provider.swift so the protocol/value-type file
/// stops mixing layers. Behavior unchanged.
enum HTTPHelpers {
    static let maxResponseBytes = 4 * 1024 * 1024
    /// Reused across get/post. URLSession's `bytes(for:delegate:)` accepts a
    /// per-call delegate, so a single instance is safe to share.
    static let noRedirectDelegate = NoRedirectSessionDelegate()

    /// Hosts that can never resolve to cloud metadata IPs, so the blocking
    /// `getaddrinfo` call in `DNSResolutionGuard` can be skipped. mDNS
    /// `.local` lookups are especially dangerous — they block the Swift
    /// Concurrency cooperative thread pool via `_mdns_search_ex → kevent`.
    static func isKnownSafeHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "127.0.0.1" || h == "::1" { return true }
        if h.hasSuffix(".local") || h.hasSuffix(".local.") { return true }
        if URLValidator.canonicalIPv4Numeric(h) != nil { return true }
        if URLValidator.canonicalIPv6(h) != nil { return true }
        return false
    }

    /// Resolves `.local` mDNS hostnames to their IPv4 address and rewrites
    /// the URL. NWConnection (used by URLSession) prefers IPv6 link-local
    /// addresses returned by mDNS, but often fails to connect because the
    /// scope ID (`%en0`) isn't propagated correctly through the HTTP stack.
    /// This causes every `.local` request to hang until timeout. Resolving
    /// to IPv4 up front sidesteps the issue entirely.
    ///
    /// The resolution runs on a detached task (not the cooperative pool)
    /// because `getaddrinfo` for `.local` names blocks on mDNS IPC.
    /// Results are cached for 60s per hostname.
    ///
    /// App Store (sandboxed) build: `Process()` is forbidden under the
    /// sandbox, so this resolution is disabled — `.local` hostnames pass
    /// through unchanged. Users of the App Store build must enter IP
    /// addresses directly for remote servers.
    #if !MODELSTATUS_APP_STORE
    private static let mdnsCache = MDNSCache()
    #endif

    static func resolveLocalURL(_ url: URL) async -> URL {
        #if MODELSTATUS_APP_STORE
        return url
        #else
        guard let host = url.host?.lowercased(),
              host.hasSuffix(".local") || host.hasSuffix(".local.") else {
            return url
        }
        if let ipv4 = await mdnsCache.resolve(host) {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = ipv4
            return components?.url ?? url
        }
        httpLog.notice("mDNS → IPv4 resolution failed for \(host, privacy: .public), using original URL")
        return url
        #endif
    }

    /// Internal GET implementation. Callers should use `get()` which pre-resolves
    /// `.local` hostnames to IPv4.
    private static func _get(_ url: URL, instanceID: UUID, session: URLSession,
                             timeout: TimeInterval = 5) async throws -> (Data, HTTPURLResponse, Int) {
        // Audit-round-D16: reject non-HTTP(S) URLs up front so a programmatic
        // construction error can't slip a `file:`/`ftp:`/other-scheme request
        // through. URLValidator already gates user input at config time; this
        // is a defense in depth at the helper boundary.
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        if let host = url.host, !Self.isKnownSafeHost(host),
           DNSResolutionGuard.resolvesToBlockedAddress(host) {
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

    /// Streaming GET with `.local` mDNS workaround. Resolves `.local` hostnames
    /// to IPv4 before hitting URLSession to avoid the IPv6 link-local hang.
    static func get(_ url: URL, instanceID: UUID, session: URLSession,
                    timeout: TimeInterval = 5) async throws -> (Data, HTTPURLResponse, Int) {
        return try await _get(await resolveLocalURL(url), instanceID: instanceID,
                              session: session, timeout: timeout)
    }

    /// POST with `.local` mDNS workaround.
    static func post(_ url: URL, body: [String: Any], instanceID: UUID,
                     session: URLSession, timeout: TimeInterval = 10) async throws -> HTTPURLResponse {
        return try await _post(await resolveLocalURL(url), body: body, instanceID: instanceID,
                               session: session, timeout: timeout)
    }

    private static func _post(_ url: URL, body: [String: Any], instanceID: UUID,
                              session: URLSession, timeout: TimeInterval = 10) async throws -> HTTPURLResponse {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        if let host = url.host, !Self.isKnownSafeHost(host),
           DNSResolutionGuard.resolvesToBlockedAddress(host) {
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

/// Thread-safe cache for mDNS → IPv4 resolution results. Entries expire
/// after 60s to track DHCP changes without hammering mDNS every poll.
/// Shells out to `dscacheutil` because both `getaddrinfo` and
/// `DNSServiceGetAddrInfo` hang inside ad-hoc signed app bundles (macOS
/// restricts mDNS IPC for unsigned/ad-hoc processes). The subprocess
/// approach works regardless of code signing since `dscacheutil` is a
/// system tool with its own entitlements.
///
/// Excluded from the App Store (sandboxed) build — `Process()` is not
/// available under the sandbox.
#if !MODELSTATUS_APP_STORE
private actor MDNSCache {
    private var entries: [String: (ip: String, expiry: Date)] = [:]

    func resolve(_ hostname: String) async -> String? {
        let key = hostname.lowercased()
        if let e = entries[key], e.expiry > Date() { return e.ip }

        let resolved: String? = await Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
            proc.arguments = ["-q", "host", "-a", "name", hostname]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Parse output like:
            // name: example.local
            // ip_address: 192.168.1.42
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ip_address:") {
                    let ip = trimmed.dropFirst("ip_address:".count)
                        .trimmingCharacters(in: .whitespaces)
                    // Only return IPv4
                    if ip.contains(".") && !ip.contains(":") {
                        return ip
                    }
                }
            }
            return nil
        }.value

        if let ip = resolved {
            entries[key] = (ip, Date().addingTimeInterval(60))
        }
        return resolved
    }
}
#endif
