import Foundation

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
