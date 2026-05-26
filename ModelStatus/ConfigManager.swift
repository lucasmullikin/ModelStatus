import Foundation
import Darwin
import OSLog

private let cfgLogger = Logger(subsystem: "com.lucasmullikin.ModelStatus", category: "config")

enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case auto      // Auto-detect on first probe
    case ollama
    case openAI    // Generic OpenAI-compatible (/v1/models)
    case lmStudio  // LM Studio (/api/v0/models, supports unload)
    case vllm      // vLLM (adds /metrics for telemetry)
    case mlx       // mlx_lm.server / mlx-omni-server (single-model, read-only)

    var displayName: String {
        switch self {
        case .auto:     return "Auto-detect"
        case .ollama:   return "Ollama"
        case .openAI:   return "OpenAI-compatible"
        case .lmStudio: return "LM Studio"
        case .vllm:     return "vLLM"
        case .mlx:      return "MLX"
        }
    }
}

struct Instance: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var url: String
    var kind: ProviderKind

    init(id: UUID = UUID(), name: String, url: String, kind: ProviderKind = .auto) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, name, url, kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.url = try c.decode(String.self, forKey: .url)
        self.kind = (try? c.decodeIfPresent(ProviderKind.self, forKey: .kind)) ?? .ollama
    }
}

struct AppConfig: Codable {
    var instances: [Instance]
    var pollInterval: TimeInterval
    var notifyOnStateChange: Bool
    var compactMode: Bool
    var verboseLogging: Bool

    static let `default` = AppConfig(
        instances: [Instance(name: "Local", url: "http://127.0.0.1:11434", kind: .ollama)],
        pollInterval: 5.0,
        notifyOnStateChange: false,
        compactMode: false,
        verboseLogging: false
    )

    enum CodingKeys: String, CodingKey {
        case instances, pollInterval, notifyOnStateChange, compactMode, verboseLogging
    }

    init(instances: [Instance], pollInterval: TimeInterval,
         notifyOnStateChange: Bool, compactMode: Bool, verboseLogging: Bool = false) {
        self.instances = instances
        self.pollInterval = pollInterval
        self.notifyOnStateChange = notifyOnStateChange
        self.compactMode = compactMode
        self.verboseLogging = verboseLogging
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.instances = try c.decode([Instance].self, forKey: .instances)
        self.pollInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .pollInterval) ?? 5.0
        self.notifyOnStateChange = try c.decodeIfPresent(Bool.self, forKey: .notifyOnStateChange) ?? false
        self.compactMode = try c.decodeIfPresent(Bool.self, forKey: .compactMode) ?? false
        self.verboseLogging = try c.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? false
    }
}

/// Per-poll-cycle snapshot of config + cycle metadata. Built once at the top of
/// `Monitor.poll()` (eventually via `MainActor.run` once ConfigManager is @MainActor)
/// and used in lieu of direct `ConfigManager.shared.X` reads from actor contexts.
///
/// Threaded through Monitor only today; the diagnostics pass (E) will extend this
/// to Provider.probe/check so the per-provider `verbose()` helper can read
/// `ctx.verbose` without crossing actor boundaries.
struct PollContext: Sendable {
    let verbose: Bool
    let pollInterval: TimeInterval
    let instances: [Instance]
    let timestamp: Date
}

enum PollInterval: TimeInterval, CaseIterable, Sendable {
    case fast = 2, normal = 5, slow = 10, lazy = 30, idle = 60, sleepy = 180

    var label: String {
        switch self {
        case .fast:   return "2s"
        case .normal: return "5s"
        case .slow:   return "10s"
        case .lazy:   return "30s"
        case .idle:   return "1m"
        case .sleepy: return "3m"
        }
    }

    static func closest(to value: TimeInterval) -> PollInterval {
        Self.allCases.min(by: { abs($0.rawValue - value) < abs($1.rawValue - value) }) ?? .normal
    }
}

@MainActor
final class ConfigManager {
    static let shared = ConfigManager()

    // Static constants are immutable and safe to read from any isolation domain.
    // Marking nonisolated makes that explicit so Logger(subsystem:) etc. stay synchronous.
    nonisolated static let bundleIdentifier = "com.lucasmullikin.ModelStatus"
    /// Pre-v0.2.1 bundle IDs we migrate config from on first launch under the
    /// new ID. Hard cut on the LLC → Individual rename happened in v0.2.1
    /// (decided 2026-05-26: shipping under Individual Apple Developer
    /// enrollment, no LLC reference in the bundle ID). The migration is
    /// graceful — any user who already has v0.2.0 installed keeps their
    /// server list + auth headers + preferences.
    nonisolated private static let legacyBundleIdentifiers = [
        "com.lucrativepictures.ModelStatus",   // v0.2.0 (briefly, pre-rename)
        "com.lucrativepictures.OllamaStatus",  // v0.1.x (pre-rename to ModelStatus)
        "com.local.ollamastatus"               // pre-v0.1 dev builds
    ]

    private let configURL: URL
    private var _config: AppConfig

    /// Audit-round-D39: property setters now roll back to the previous
    /// value if `save()` fails, so in-memory state never diverges from
    /// what's on disk. Callers that care about success can use the
    /// explicit `set*` methods below.
    /// Codex-v1final fix: previously a public setter that allowed callers
    /// to wholesale-replace the AppConfig, bypassing the transactional
    /// addInstance/removeInstance/updateInstance paths (and their Keychain
    /// rollback safety). Now read-only externally; mutations must go
    /// through the explicit methods that handle Keychain consistency.
    var config: AppConfig { _config }

    /// Codex-v1final fix: instances is read-only externally for the same
    /// reason as `config` above. Callers that need to add/remove must use
    /// `addInstance(name:url:kind:authHeader:)` / `removeInstance(at:)` /
    /// `removeInstance(id:)` / `updateInstance(id:name:url:kind:)`.
    var instances: [Instance] { _config.instances }

    var pollInterval: TimeInterval {
        get { _config.pollInterval }
        set {
            let snapshot = _config.pollInterval
            _config.pollInterval = newValue
            if !save() { _config.pollInterval = snapshot }
        }
    }

    var notifyOnStateChange: Bool {
        get { _config.notifyOnStateChange }
        set {
            let snapshot = _config.notifyOnStateChange
            _config.notifyOnStateChange = newValue
            if !save() { _config.notifyOnStateChange = snapshot }
        }
    }

    var compactMode: Bool {
        get { _config.compactMode }
        set {
            let snapshot = _config.compactMode
            _config.compactMode = newValue
            if !save() { _config.compactMode = snapshot }
        }
    }

    var verboseLogging: Bool {
        get { _config.verboseLogging }
        set {
            let snapshot = _config.verboseLogging
            _config.verboseLogging = newValue
            if !save() { _config.verboseLogging = snapshot }
        }
    }

    /// Snapshot reader used by `Monitor.poll()` to capture config in a single hop.
    /// After v0.2 step B this becomes the only legal way to read config from non-MainActor contexts.
    func snapshotForPoll() -> PollContext {
        PollContext(
            verbose: _config.verboseLogging,
            pollInterval: _config.pollInterval,
            instances: _config.instances,
            timestamp: Date()
        )
    }

    private init() {
        let prefsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        configURL = prefsDir.appendingPathComponent("\(Self.bundleIdentifier).json")

        if let migrated = Self.loadWithMigration(target: configURL, in: prefsDir) {
            _config = migrated
        } else {
            _config = .default
        }
        save()
    }

    nonisolated private static func loadWithMigration(target: URL, in prefsDir: URL) -> AppConfig? {
        if let cfg = load(from: target) { return cfg }
        for legacy in legacyBundleIdentifiers {
            let legacyURL = prefsDir.appendingPathComponent("\(legacy).json")
            if let cfg = load(from: legacyURL) { return cfg }
        }
        return nil
    }

    nonisolated private static func load(from url: URL) -> AppConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    /// Audit-round-D37: returns Bool so mutating callers can roll back
    /// on persistence failure (specifically: undo a Keychain write if the
    /// config save fails, so the credential and the config-instance-list
    /// stay in sync).
    @discardableResult
    private func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(_config)
        } catch {
            cfgLogger.error("config encode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        do {
            try data.write(to: configURL, options: [.atomic, .completeFileProtection])
        } catch {
            cfgLogger.error("config write failed at \(self.configURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch {
            // chmod failure isn't fatal — Class A protection already in place.
            cfgLogger.notice("config chmod 0600 failed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    /// Persist the Keychain header BEFORE the config snapshot, and ONLY persist
    /// the instance when the Keychain write actually landed. Audit-round-3
    /// finding: a returned-true Keychain check stops a "credentials never
    /// stored but config thinks they were" failure mode (locked keychain,
    /// sandbox container without entitlement, etc.). Returns nil when the
    /// auth header was supplied but couldn't be saved.
    @discardableResult
    func addInstance(name: String, url: String, kind: ProviderKind = .auto, authHeader: String? = nil) -> Instance? {
        let inst = Instance(name: name, url: url, kind: kind)
        // Trim before the empty check so whitespace-only headers aren't stored.
        let trimmed = authHeader?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCredentials = (trimmed?.isEmpty == false)
        if let trimmed, hasCredentials {
            guard Keychain.setAuthHeader(trimmed, for: inst.id) else {
                cfgLogger.error("addInstance: refusing to save instance \(name, privacy: .public) — Keychain write for auth header failed")
                return nil
            }
        }
        _config.instances.append(inst)
        // Audit-round-D37+D39: if config save fails AFTER a successful Keychain
        // write, undo the Keychain write. Surface a Keychain-cleanup failure
        // explicitly rather than ignoring its return — an orphaned credential
        // for an instance that was never persisted is exactly the failure
        // mode the rollback is trying to prevent.
        if !save() {
            _config.instances.removeAll(where: { $0.id == inst.id })
            if hasCredentials {
                if !Keychain.setAuthHeader(nil, for: inst.id) {
                    cfgLogger.error("addInstance rollback: also failed to delete orphaned Keychain credential for \(name, privacy: .public)")
                }
            }
            cfgLogger.error("addInstance: rolled back \(name, privacy: .public) — config persistence failed")
            return nil
        }
        cfgLogger.notice("added server \(name, privacy: .public) (\(Anonymizer.scrubURL(url), privacy: .public)) kind=\(String(describing: kind), privacy: .public) auth=\(hasCredentials ? "set" : "none")")
        return inst
    }

    /// Audit-round-D38: transactional removal — save the config FIRST, only
    /// delete the Keychain credential after persistence succeeds. Roll back
    /// the in-memory removal on save failure so a transient disk-write error
    /// can't leave the user with a permanently-decredentialed instance.
    func removeInstance(at index: Int) {
        guard index >= 0 && index < _config.instances.count else { return }
        let removed = _config.instances[index]
        _config.instances.remove(at: index)
        if !save() {
            _config.instances.insert(removed, at: index)
            cfgLogger.error("removeInstance(at:): rolled back — config persistence failed")
            return
        }
        if !Keychain.setAuthHeader(nil, for: removed.id) {
            cfgLogger.error("removeInstance(at:): config saved but Keychain credential delete failed for instance \(removed.name, privacy: .public)")
        }
        cfgLogger.notice("removed server \(removed.name, privacy: .public) (\(Anonymizer.scrubURL(removed.url), privacy: .public))")
    }

    func removeInstance(id: UUID) {
        guard let removed = _config.instances.first(where: { $0.id == id }) else { return }
        let snapshot = _config.instances
        _config.instances.removeAll { $0.id == id }
        if !save() {
            _config.instances = snapshot
            cfgLogger.error("removeInstance(id:): rolled back — config persistence failed")
            return
        }
        if !Keychain.setAuthHeader(nil, for: removed.id) {
            cfgLogger.error("removeInstance(id:): config saved but Keychain credential delete failed for instance \(removed.name, privacy: .public)")
        }
        cfgLogger.notice("removed server \(removed.name, privacy: .public) (\(Anonymizer.scrubURL(removed.url), privacy: .public))")
    }

    func updateInstance(id: UUID, name: String? = nil, url: String? = nil, kind: ProviderKind? = nil) {
        guard let i = _config.instances.firstIndex(where: { $0.id == id }) else { return }
        let snapshot = _config.instances[i]
        if let name { _config.instances[i].name = name }
        if let url { _config.instances[i].url = url }
        if let kind { _config.instances[i].kind = kind }
        if !save() {
            _config.instances[i] = snapshot
            cfgLogger.error("updateInstance: rolled back — config persistence failed")
            return
        }
        let updated = _config.instances[i]
        cfgLogger.notice("updated server \(updated.name, privacy: .public) (\(Anonymizer.scrubURL(updated.url), privacy: .public)) kind=\(String(describing: updated.kind), privacy: .public)")
    }
}

/// SYNTACTIC URL validation. Catches obvious misconfigurations + a curated set
/// of cloud-metadata endpoints with full IPv4 canonicalization (decimal/octal/
/// hex/shortened forms all fold to the same numeric blocklist check).
///
/// **Not a full SSRF defense**: a hostname that resolves to a blocked IP at
/// connect time is not detected HERE. Runtime defense lives in
/// `HTTPHelpers.get` / `HTTPHelpers.post`, both of which invoke
/// `DNSResolutionGuard.resolvesToBlockedAddress` immediately before the
/// outbound request. The two layers together cover: (a) literal-IP misconfig
/// (URLValidator) and (b) hostname → blocked-IP rebinding (DNSResolutionGuard).
/// Audit-round-D23: layering documented explicitly so callers don't mistake
/// URLValidator as the only SSRF gate.
enum URLValidator {
    enum Issue: Error, LocalizedError {
        case invalid, unsupportedScheme, missingHost, suspiciousHost
        var errorDescription: String? {
            switch self {
            case .invalid: return "Not a valid URL."
            case .unsupportedScheme: return "Only http:// and https:// URLs are supported."
            case .missingHost: return "URL must include a hostname."
            case .suspiciousHost: return "Host is not allowed (cloud metadata endpoints are blocked)."
            }
        }
    }

    private static let schemeRegex = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9+.-]*:")
    // Host:port shorthand — `letters/digits/.-` followed by `:digits`. Audit-round-D2:
    // detected before the scheme regex so `localhost:11434` is treated as a
    // host and gets `http://` prepended, while `mailto:user@x` still falls
    // through to the scheme-allowlist rejection path.
    private static let hostPortShorthandRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9][A-Za-z0-9.\-]*:\d+(?:/|$)"#)

    /// Hostnames blocked at config-validation time. IPv4 is handled separately via
    /// `inet_aton` canonicalization so decimal/octal/hex/shortened forms can't slip past.
    /// `internal` so `DNSResolutionGuard` can reuse it at request time.
    static let blockedHostnames: Set<String> = [
        "metadata.google.internal",
        "metadata"               // GCP shortcut
    ]

    /// Network-order numeric form of cloud-metadata IPv4 endpoints to block.
    /// `inet_aton` accepts every alternate textual encoding (`2852039166`,
    /// `0xa9.0xfe.0xa9.0xfe`, `0251.0376.0251.0376`, etc.) and folds them all to
    /// the same `in_addr.s_addr`, so we compare numerically. `fileprivate` so
    /// the public `blockedIPv4Numerics` re-export controls external access.
    fileprivate static let blockedIPv4Numeric: Set<UInt32> = [
        0xA9FEA9FE       // 169.254.169.254 — AWS / Azure / GCP IMDS
    ]

    /// IPv6 metadata endpoints. Compared after `inet_pton`/`inet_ntop` round-trip
    /// so "[fd00:ec2::254]" and "[fd00:ec2:0:0:0:0:0:254]" both normalize to the
    /// same canonical form.
    fileprivate static let blockedIPv6Canonical: Set<String> = [
        "fd00:ec2::254"
    ]

    static func validate(_ raw: String) -> Result<String, Issue> {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .failure(.invalid) }
        // Two-step scheme detection (audit-round-D2):
        //  1. If the input looks like host:port shorthand (`localhost:11434`),
        //     prepend `http://` so it parses as a normal HTTP URL.
        //  2. Otherwise, if it has an explicit scheme (`mailto:`, `file:/`,
        //     `ftp://`, `javascript:` …) leave it alone — the allowlist below
        //     will reject anything other than http/https.
        //  3. Otherwise (bare hostname / IP), prepend `http://`.
        let range = NSRange(s.startIndex..., in: s)
        if hostPortShorthandRegex.firstMatch(in: s, range: range) != nil {
            s = "http://" + s
        } else if schemeRegex.firstMatch(in: s, range: range) == nil {
            s = "http://" + s
        }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else {
            return .failure(.invalid)
        }
        if scheme != "http" && scheme != "https" { return .failure(.unsupportedScheme) }
        guard let rawHost = url.host, !rawHost.isEmpty else { return .failure(.missingHost) }
        // Canonicalize: lowercase, strip trailing dot.
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if blockedHostnames.contains(host) { return .failure(.suspiciousHost) }
        // IPv4 canonicalization catches every textual representation of a blocked address.
        if let numeric = canonicalIPv4Numeric(host),
           blockedIPv4Numeric.contains(numeric) { return .failure(.suspiciousHost) }
        // IPv6 canonicalization handles ::-compression + uppercase variants.
        if let canon = canonicalIPv6(host),
           blockedIPv6Canonical.contains(canon) { return .failure(.suspiciousHost) }
        // Codex-v1final fix: ALSO block IPv4-mapped IPv6 literals like
        // `[::ffff:169.254.169.254]`. `canonicalIPv6` normalizes these as
        // IPv6 but `blockedIPv6Canonical` doesn't include the IPv4-mapped
        // forms of metadata endpoints. Extract the embedded IPv4 and check
        // it against the blocked-IPv4 set.
        if let mappedV4 = ipv4MappedFromIPv6(host),
           blockedIPv4Numeric.contains(mappedV4) { return .failure(.suspiciousHost) }
        // Architect-v1final fix: strip user:password@ credentials from the
        // ACCEPTED URL before it's persisted. We never want auth credentials
        // baked into the URL we'll later emit at .notice level (LogViewer,
        // Console.app, anywhere). Credentials belong in the Keychain via
        // Settings → Edit Auth, NOT in the URL itself.
        var stripped = s
        if let url2 = URL(string: stripped),
           (url2.user != nil || url2.password != nil),
           var comps = URLComponents(url: url2, resolvingAgainstBaseURL: false) {
            comps.user = nil
            comps.password = nil
            if let out = comps.string { stripped = out }
        }
        return .success(stripped)
    }

    /// Returns the host-order numeric IPv4 embedded in an IPv4-mapped IPv6
    /// literal (e.g. `::ffff:169.254.169.254`), or nil if not an IPv4-mapped
    /// form. Used by `validate(_:)` to block `[::ffff:169.254.169.254]`-style
    /// metadata-endpoint bypasses.
    static func ipv4MappedFromIPv6(_ host: String) -> UInt32? {
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) == 1 }) else { return nil }
        // IPv4-mapped IPv6 form: first 80 bits zero, next 16 are 0xFFFF, last 32 are IPv4.
        let bytes = withUnsafeBytes(of: &addr) { Array($0.bindMemory(to: UInt8.self)) }
        guard bytes.count == 16 else { return nil }
        let firstTenZero = bytes[0..<10].allSatisfy { $0 == 0 }
        let ffMarker = bytes[10] == 0xFF && bytes[11] == 0xFF
        guard firstTenZero && ffMarker else { return nil }
        // Bytes 12..15 are the IPv4 in network byte order. Convert to host-order
        // numeric to match canonicalIPv4Numeric's output domain.
        let v4 = (UInt32(bytes[12]) << 24)
               | (UInt32(bytes[13]) << 16)
               | (UInt32(bytes[14]) << 8)
               |  UInt32(bytes[15])
        return v4
    }

    /// Returns the host-order 32-bit numeric form of an IPv4 textual address using
    /// `inet_aton`, which folds dotted-decimal, decimal, octal (`0`-prefix), hex
    /// (`0x`-prefix), and shortened (a.b.c / a.b / a) forms into the same value.
    /// `internal` so HTTPHelpers can reuse it for runtime DNS-resolution checks.
    static func canonicalIPv4Numeric(_ host: String) -> UInt32? {
        var addr = in_addr()
        // `inet_aton` returns 1 on success; on failure leaves `addr` untouched.
        guard host.withCString({ inet_aton($0, &addr) }) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    /// Normalize an IPv6 textual literal (no brackets) to its canonical form via
    /// `inet_pton` → `inet_ntop`. Returns nil for non-IPv6 input.
    /// `internal` so HTTPHelpers can reuse it.
    static func canonicalIPv6(_ host: String) -> String? {
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) == 1 }) else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let result = withUnsafePointer(to: &addr) { ptr -> String? in
            guard inet_ntop(AF_INET6, ptr, &buf, socklen_t(buf.count)) != nil else { return nil }
            return String(cString: buf)
        }
        return result
    }

    /// Host-blocklist exposed for runtime checks (HTTPHelpers pre-resolve).
    static let blockedIPv4Numerics: Set<UInt32> = blockedIPv4Numeric
    static let blockedIPv6Canonicals: Set<String> = blockedIPv6Canonical
}

/// DNS-rebinding SSRF guard: resolve `host` via `getaddrinfo` and check every
/// returned address against the same blocklists `URLValidator` uses for
/// literal addresses at config time. Returns `true` if any resolved IP is
/// blocked. Best-effort defense in depth — there's still a TOCTOU window
/// between this resolution and URLSession's, but the attack surface shrinks
/// from "every poll" to "exact race within milliseconds".
///
/// Failure to resolve (offline, DNS down) returns `false` — we don't fail
/// closed on resolver errors because that would block every poll the first
/// time the network blips.
enum DNSResolutionGuard {
    static func resolvesToBlockedAddress(_ host: String) -> Bool {
        // Audit-round-D36: canonicalize the hostname (lowercase + strip
        // trailing dot) and check the SAME hostname blocklist URLValidator
        // uses, before falling through to literal-IP and DNS-resolved-IP
        // checks. Without this layering, runtime callers would catch
        // numeric-IP misconfig but miss `metadata.google.internal.` (mixed
        // case / trailing dot) etc.
        var canonicalHost = host.lowercased()
        if canonicalHost.hasSuffix(".") { canonicalHost.removeLast() }
        if URLValidator.blockedHostnames.contains(canonicalHost) { return true }
        // Literal IP forms: check the blocklist directly. Defense-in-depth in
        // case a config predating URLValidator's tightening or a programmatic
        // URL construction skipped the syntactic guard. Audit-round-D7.
        if let numeric = URLValidator.canonicalIPv4Numeric(canonicalHost) {
            return URLValidator.blockedIPv4Numerics.contains(numeric)
        }
        if let canon = URLValidator.canonicalIPv6(canonicalHost) {
            return URLValidator.blockedIPv6Canonicals.contains(canon)
        }

        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { getaddrinfo($0, nil, &hints, &result) }
        guard status == 0, let head = result else { return false }
        defer { freeaddrinfo(head) }

        var blocked = false
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let info = cursor {
            let ai = info.pointee
            if let sa = ai.ai_addr {
                if ai.ai_family == AF_INET {
                    sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        let raw = UInt32(bigEndian: sin.pointee.sin_addr.s_addr)
                        if URLValidator.blockedIPv4Numerics.contains(raw) { blocked = true }
                    }
                } else if ai.ai_family == AF_INET6 {
                    sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                        var copy = sin6.pointee.sin6_addr
                        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        if inet_ntop(AF_INET6, &copy, &buf, socklen_t(buf.count)) != nil {
                            let canon = String(cString: buf)
                            if URLValidator.blockedIPv6Canonicals.contains(canon) { blocked = true }
                        }
                    }
                }
            }
            if blocked { break }
            cursor = ai.ai_next
        }
        return blocked
    }
}
