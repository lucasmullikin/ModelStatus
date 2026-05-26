import Foundation
import CryptoKit
import Security
import Darwin
import OSLog

private let anonLog = Logger(subsystem: "com.lucrativepictures.ModelStatus", category: "anonymizer")

/// Hostname/URL/free-text scrubber for diagnostic bundles.
///
/// Salt rationale (v0.2 security review): we hash hostnames with a per-install
/// random salt so two bundles from different users don't collide on the same
/// `host-<hex>` token (which would otherwise let an aggregator correlate them).
/// The salt lives in the Keychain and never ships in the bundle.
///
/// In-memory caching matters here: if Keychain write fails (locked keychain,
/// sandboxed temp container, etc.) we still hold the generated salt for the
/// lifetime of this process so every `hashHost()` call in a single export
/// produces stable tokens.
enum Anonymizer {
    private static let keychainService = "com.lucrativepictures.ModelStatus.anon"
    private static let keychainAccount = "salt"
    private static let saltByteCount = 8

    // MARK: - Salt

    private static let cacheLock = NSLock()
    private static var cachedSalt: Data?

    /// Load the per-install salt — first from in-memory cache, then Keychain,
    /// otherwise generate + persist. Even if Keychain write fails the freshly
    /// generated salt is cached in memory so per-export hash stability holds.
    static func loadOrCreateSalt() -> Data {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedSalt { return cached }
        if let existing = readSalt() {
            cachedSalt = existing
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: saltByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, saltByteCount, &bytes)
        guard status == errSecSuccess else {
            // Audit-round-7: be honest about what an empty-salt fallback means.
            // This is NOT "fail closed" — it's a documented degradation:
            //
            //   • Within this process: hostHash is still stable (good).
            //   • Across processes / bundles: the same host hashes to the same
            //     unsalted SHA-256 → cross-correlation becomes possible (bad).
            //
            // SecRandomCopyBytes effectively never fails on macOS — if it does,
            // something is very wrong system-wide and the privacy degradation
            // is the lesser evil compared to crashing diagnostic-bundle export.
            //
            // Audit-round-10: log loudly so the degradation is observable in
            // Console.app rather than silent. Operator can decide to abort
            // an export if they see this.
            anonLog.error("SecRandomCopyBytes failed (status=\(status, privacy: .public)); diagnostic-bundle hashes are unsalted for this process — cross-bundle correlation is possible.")
            cachedSalt = Data()
            return Data()
        }
        let salt = Data(bytes)
        _ = writeSalt(salt)   // best-effort; in-memory cache is the real source of truth
        cachedSalt = salt
        return salt
    }

    private static func readSalt() -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, !data.isEmpty else { return nil }
        return data
    }

    /// Returns true if persistence succeeded. Caller doesn't care — the in-memory
    /// cache is authoritative for the running process — but the return lets us
    /// not silently swallow real errors if we ever want to surface them.
    @discardableResult
    private static func writeSalt(_ data: Data) -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            let attrs = baseQuery.merging([
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: data
            ]) { _, new in new }
            return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    // MARK: - Hashing

    /// SHA-256 over `salt || canonical(host).utf8`, full 32-byte (64 hex char) output.
    /// Security review explicitly said do NOT truncate — 8-char truncation
    /// is brute-forceable for short hostnames within a known LAN.
    ///
    /// Canonicalization (audit-round-4): DNS hostnames are case-insensitive
    /// (`Example.local` and `example.local` should hash equal), and IPv6
    /// literals have many textually-distinct equivalent forms (`2001:db8::1`
    /// vs `2001:0db8:0:0:0:0:0:1`). Without canonicalization the same logical
    /// host would show up under different tokens depending on which spelling
    /// the log line happened to use.
    static func hashHost(_ host: String) -> String {
        let canonical = canonicalize(host)
        let salt = loadOrCreateSalt()
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(canonical.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical form for hashing: lowercase + strip trailing dot for DNS,
    /// inet_pton/inet_ntop round-trip for IPv6 literals. Zone IDs (`%en0`) are
    /// preserved because two interfaces could legitimately share a link-local
    /// address. URL-encoded zone separators (`%25`) are normalized to `%` so
    /// `[fe80::1%25en0]` and `[fe80::1%en0]` hash to the same token.
    private static func canonicalize(_ host: String) -> String {
        // Audit-round-6: collapse %25 → % so a percent-encoded zone separator
        // (commonly seen in URL forms of link-local addresses) doesn't produce
        // a different canonical form than the literal `%` form.
        var working = host
        if working.contains("%25") {
            working = working.replacingOccurrences(of: "%25", with: "%")
        }
        // Split off zone ID if present so we can normalize the address half.
        let (addr, zone): (String, String?) = {
            if let pct = working.firstIndex(of: "%") {
                return (String(working[working.startIndex..<pct]),
                        String(working[working.index(after: pct)...]))
            }
            return (working, nil)
        }()
        // IPv6 canonicalization via inet_pton → inet_ntop. Falls through to
        // DNS canonicalization on failure.
        var v6 = in6_addr()
        if addr.withCString({ inet_pton(AF_INET6, $0, &v6) == 1 }) {
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let normalized = withUnsafePointer(to: &v6) { ptr -> String? in
                guard inet_ntop(AF_INET6, ptr, &buf, socklen_t(buf.count)) != nil else { return nil }
                return String(cString: buf)
            }
            if let n = normalized {
                // Lowercase the zone identifier in this branch too — matches
                // the DNS/IPv4 path below so `fe80::1%en0` and `fe80::1%EN0`
                // canonicalize identically.
                return zone.map { "\(n)%\($0.lowercased())" } ?? n
            }
        }
        // DNS or IPv4 textual: lowercase + strip trailing dot. Audit-round-D2:
        // the zone ID is also lowercased so `fe80::1%en0` and `fe80::1%EN0`
        // canonicalize identically (zone identifiers on macOS are interface
        // names and BSD treats them case-insensitively).
        var lower = addr.lowercased()
        if lower.hasSuffix(".") { lower.removeLast() }
        return zone.map { "\(lower)%\($0.lowercased())" } ?? lower
    }

    // MARK: - URL scrubbing

    /// `host-` followed by exactly 64 lowercase hex characters — the shape
    /// `hashHost()` produces. Used to make `scrubURL` idempotent (don't rehash
    /// an already-hashed host).
    ///
    /// Known limitation (audit-round-D14): a real input that literally has
    /// the shape `host-<64-hex>` would be treated as already-anonymized and
    /// pass through unchanged. DNS hostnames using exactly that 64-hex
    /// suffix shape don't exist in any real namespace we know about (the
    /// digits + length + lowercase requirement narrows the space to 16^64
    /// strings that happen to look like SHA-256 hex), so we accept the
    /// trade-off in favor of preserving idempotency: running scrub twice
    /// on the same text produces stable output, which is the more common
    /// real-world need.
    private static let hashedHostRegex = try! NSRegularExpression(
        pattern: #"^host-[0-9a-f]{64}$"#)

    private static func isHashedHost(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return hashedHostRegex.firstMatch(in: s, range: range) != nil
    }

    /// Schemes for which scrubURL attempts host-from-path recovery on a
    /// hostless URL. Mailto, file, etc. are deliberately excluded — their
    /// "first path segment" is not a hostname.
    private static func isNetworkScheme(_ scheme: String) -> Bool {
        let s = scheme.lowercased()
        return s == "http" || s == "https" || s == "ws" || s == "wss" || s == "ftp" || s == "ftps"
    }

    /// Fallback for URL-shaped strings that URLComponents refused to parse
    /// (invalid percent-encoding, etc.). Strips credentials, query, and
    /// fragment via regex so a malformed URL can't smuggle secrets through.
    private static let malformedURLLikePattern = try! NSRegularExpression(
        pattern: #"(?i)^(https?|wss?|ftps?):"#)
    // Matches `scheme://user:pass@`, hostless `scheme:user:pass@`, and
    // single-slash `scheme:/user:pass@` forms. Audit-round-D44: aligned with
    // malformedHostPattern's `(?://|/)?` alternation so the credential
    // regex doesn't fall behind when single-slash forms appear.
    private static let malformedCredentialPattern = try! NSRegularExpression(
        pattern: #"([a-zA-Z][a-zA-Z0-9+.-]*:(?://|/)?)[^/@\s:]+:[^/@\s]+@"#)
    /// Best-effort host extraction for malformed network URLs. Looks for the
    /// authority span between `scheme://` (or hostless `scheme:` without //)
    /// and the first `/?#` terminator.
    ///
    /// Audit-round-D42: the `(?://)?` clause optionally consumes `//`, but
    /// the AUTHORITY capture (`[^/?#\s]+`) must NOT include a leading `/`
    /// from a `scheme:/host/...` form. The regex already excludes `/` from
    /// the authority class, so `scheme:/host` matches with `://` empty and
    /// then matches a single leading `/` followed by `host` — wait, that's
    /// the bug. Fix: tolerate ONE optional `/` between scheme: and authority
    /// for the hostless single-slash form, but don't capture it as part of
    /// the host. Use a non-capturing alternation: `(?://|/)?`.
    private static let malformedHostPattern = try! NSRegularExpression(
        pattern: #"(?i)((?:https?|wss?|ftps?):(?://|/)?)([^/?#\s]+)"#)

    /// Audit-round-D46/D50-hard: matches a `@<host-shape>` token (no port)
    /// that may appear AFTER an authority terminator in malformed input —
    /// e.g. `http://user/secret@example.local/path`. We hash the host part
    /// so the hostname doesn't leak through the credential-straddling edge
    /// case.
    ///
    /// Three alternatives cover the common host shapes:
    /// 1. `@<bracketed IPv6>` — `@[::1]`, `@[fe80::1%en0]`
    /// 2. `@<IPv4 literal>` — `@127.0.0.1`, `@192.168.1.10`
    /// 3. `@<hostname>` — DNS labels with optional dots (handles bare
    ///    `@localhost`, `@host.local`, FQDN forms).
    /// `looksLikeHost()` is the final gate so a stray `@word` doesn't get
    /// hashed.
    private static let straddledCredHostPattern = try! NSRegularExpression(
        pattern: #"@(?:\[[0-9A-Fa-f:%.]+\]|\d{1,3}(?:\.\d{1,3}){3}|[A-Za-z0-9][A-Za-z0-9.-]*)"#)

    private static func scrubMalformedURLLike(_ raw: String) -> String {
        let nsr = NSRange(raw.startIndex..., in: raw)
        guard malformedURLLikePattern.firstMatch(in: raw, range: nsr) != nil else { return raw }
        var s = raw
        // Audit-round-D40: more aggressive credential stripping for malformed
        // input — locate the scheme prefix and look for the LAST `@` between
        // the scheme separator and the next URL terminator on the same line.
        // The regex-only approach missed credentials containing `/`, `?`, `#`.
        // Audit-round-D44: scheme prefix tolerates `://`, `:/`, or just `:`.
        if let schemeMatch = s.range(of: #"(?i)^(?:https?|wss?|ftps?):(?://|/)?"#, options: .regularExpression) {
            let afterScheme = schemeMatch.upperBound
            // Audit-round-D42: bound the credential `@` search at the
            // EARLIEST of whitespace, `/`, `?`, or `#` — these all terminate
            // the authority. An `@` inside a query value (`?email=a@b`) or
            // fragment is not a credential separator.
            let terminators: Set<Character> = [" ", "\t", "\n", "\r", "/", "?", "#"]
            var endIdx = s.endIndex
            for idx in s.indices[afterScheme..<s.endIndex] where terminators.contains(s[idx]) {
                endIdx = idx; break
            }
            let span = afterScheme..<endIdx
            if let atIdx = s[span].lastIndex(of: "@") {
                s.replaceSubrange(afterScheme..<atIdx, with: "<redacted>")
            }
        }
        // Audit-round-D46: defense-in-depth scan for `@<host-like>` patterns
        // appearing AFTER the authority terminator. Malformed inputs like
        // `http://user/secret@example.local/path` carry credentials that
        // straddle `/`, `?`, or `#` — the spec calls these invalid, but a
        // host-shaped string after `@` is still a privacy leak if echoed
        // verbatim. Hash any such host so `example.local` doesn't survive.
        //
        // Audit-round-D52-hard: limit the scan to the AUTHORITY+PATH region
        // (up to the first `?` or `#`) so a legitimate query value like
        // `?email=user@example.local` isn't transformed. The query and
        // fragment portions get stripped wholesale below, so we don't need
        // straddled-cred detection there.
        let preQueryEnd = s.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? s.endIndex
        let preQueryStr = String(s[s.startIndex..<preQueryEnd])
        let querySuffix = String(s[preQueryEnd..<s.endIndex])
        var preQueryScrubbed = preQueryStr
        preQueryScrubbed = replaceMatches(preQueryScrubbed, regex: Self.straddledCredHostPattern) { match in
            // Match shape: `@<host>` where host = letters/digits/dots/dashes
            // (no `:` because we don't want to consume ports here).
            guard let atIdx = match.firstIndex(of: "@") else { return match }
            let hostStart = match.index(after: atIdx)
            let host = String(match[hostStart...])
            guard !host.isEmpty, looksLikeHost(host) else { return match }
            return "@" + "host-" + hashHost(host)
        }
        s = preQueryScrubbed + querySuffix
        // Re-run the regex pass for any remaining standard `://user:pass@`
        // forms we may have missed (defensive — should be a no-op after the
        // explicit handling above).
        s = malformedCredentialPattern.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1<redacted>@")
        // Audit-round-D18: also HASH the apparent host of `scheme://host/...`
        // forms so a malformed URL whose host is intact doesn't leak the host
        // name. Strip `<redacted>@` credentials first (handled above), then
        // replace the host span with `host-<sha>`.
        s = replaceMatches(s, regex: malformedHostPattern) { match in
            // Audit-round-D43: use the regex's TWO capture groups (prefix,
            // authority) instead of re-splitting the matched string by ":".
            // The `://` / `/` alternative now produces three possible
            // separator shapes, and string-search can pick the wrong one
            // (e.g. `http:/host` would split at `:` and capture `/host` as
            // authority). Re-run the regex against the match to read groups.
            let nsm = NSRange(match.startIndex..., in: match)
            guard let result = malformedHostPattern.firstMatch(in: match, range: nsm),
                  result.numberOfRanges >= 3,
                  let prefixRange = Range(result.range(at: 1), in: match),
                  let authorityRange = Range(result.range(at: 2), in: match) else {
                return match
            }
            let prefix = match[prefixRange]
            let authority = String(match[authorityRange])
            // Drop credentials before splitting host from port.
            let postCreds: String = {
                if let atIdx = authority.lastIndex(of: "@") {
                    return String(authority[authority.index(after: atIdx)...])
                }
                return authority
            }()
            guard !postCreds.isEmpty else { return match }
            // Audit-round-D20: split `host:port` so we hash only the HOST,
            // preserve the port. Otherwise the same logical host hashes
            // differently depending on whether a port was present in the
            // malformed input.
            let hostPart: String
            let portSuffix: String
            if postCreds.hasPrefix("[") {
                // Bracketed IPv6 authority: keep the brackets, find `:port` after `]`.
                if let closeBracket = postCreds.firstIndex(of: "]") {
                    let inside = String(postCreds[postCreds.index(after: postCreds.startIndex)..<closeBracket])
                    hostPart = "[" + inside + "]"
                    let tail = postCreds[postCreds.index(after: closeBracket)...]
                    portSuffix = String(tail)
                } else {
                    hostPart = postCreds
                    portSuffix = ""
                }
            } else if let colon = postCreds.lastIndex(of: ":"),
                      postCreds[postCreds.index(after: colon)...].allSatisfy({ $0.isASCII && $0.isNumber }) {
                hostPart = String(postCreds[postCreds.startIndex..<colon])
                portSuffix = String(postCreds[colon...])
            } else {
                hostPart = postCreds
                portSuffix = ""
            }
            // Strip brackets for hashing so [fd00::1] and fd00::1 hash equal.
            let hostForHash: String = {
                if hostPart.hasPrefix("[") && hostPart.hasSuffix("]") {
                    return String(hostPart.dropFirst().dropLast())
                }
                return hostPart
            }()
            // Audit-round-D22: preserve only when the ENTIRE host matches the
            // hashed-host shape — anchored, not a prefix. Previously a host
            // like `host-<64hex>.evil.example` would be treated as
            // already-anonymized and leak the suffix.
            if isHashedHost(hostForHash) {
                let credPrefix = authority.contains("@") ? "<redacted>@" : ""
                let outHost = hostPart.hasPrefix("[") ? "[\(hostForHash)]" : hostForHash
                return "\(prefix)\(credPrefix)\(outHost)\(portSuffix)"
            }
            // Audit-round-D51-hard: gate the hash on looksLikeHost. For
            // malformed inputs like `http://user/secret@example.local/path`
            // the regex captures `user` as the apparent authority — but
            // `user` is not a host, it's the credential portion that ended
            // up in the path because the URL is malformed. Hashing it
            // (a) loses the hint that the URL was malformed and (b) papers
            // over a real privacy leak that `straddledCredHostPattern`
            // handles correctly by hashing the LATER `@example.local`.
            // When the captured token doesn't look like a host, leave it
            // alone so the @host pattern downstream can claim it instead.
            guard looksLikeHost(hostForHash) else { return match }
            let hashedInner = "host-\(hashHost(hostForHash))"
            let hashed = hostPart.hasPrefix("[") ? "[\(hashedInner)]" : hashedInner
            let credPrefix = authority.contains("@") ? "<redacted>@" : ""
            return "\(prefix)\(credPrefix)\(hashed)\(portSuffix)"
        }
        // Strip from the EARLIEST of `?` or `#` to end. Audit-round-D26: if
        // `#` comes first (malformed `path#frag?token=`), the previous
        // `?`-first logic left `#frag` visible. Walk both, pick the lower
        // index, truncate.
        let q = s.firstIndex(of: "?")
        let f = s.firstIndex(of: "#")
        let cut: String.Index? = {
            switch (q, f) {
            case (let q?, let f?): return min(q, f)
            case (let q?, nil):    return q
            case (nil,    let f?): return f
            case (nil, nil):       return nil
            }
        }()
        if let cut { s = String(s[s.startIndex..<cut]) }
        return s
    }

    /// Heuristic for "does this string look like a hostname / IP literal".
    /// Used by the hostless-URL path recovery so we don't rewrite plain
    /// path segments (`healthz`, `v1`, `v1.2`, `build.123`, `api`) as if
    /// they were hostnames. Audit-round-D15: tightened from
    /// "contains a dot" to "validates as IP or has a DNS-name shape".
    private static func looksLikeHost(_ s: String) -> Bool {
        if s.isEmpty { return false }
        if isHashedHost(s) { return true }
        // Audit-round-D36: explicit `localhost` recognition. A hostless URL
        // like `http:localhost/path` should anonymize the host token.
        if s.lowercased() == "localhost" { return true }
        // Bracketed: only host-like if the inside actually validates as IPv6.
        // Audit-round-D20: previously any `[...]` was accepted, which would
        // anonymize non-host bracketed path segments like `[build-123]`.
        if s.hasPrefix("[") && s.hasSuffix("]") {
            let inner = String(s.dropFirst().dropLast())
            return isValidIPv6(inner)
        }
        // Validates as canonical dotted-quad IPv4 (strict — inet_pton rejects
        // the shorthand forms `127.1` / `1.2.3` that inet_aton accepts, so
        // version-like path segments don't accidentally trigger host hashing).
        var v4 = in_addr()
        if s.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        // Validates as IPv6 (covers `::1`, `fe80::1`, zone-bearing forms).
        // Audit-round-D27: route through isValidIPv6 so `fe80::1%en0` is
        // recognized as host-shaped (it strips the zone before validating).
        if s.contains(":") && isValidIPv6(s) { return true }
        // DNS-shape (audit-round-D24, tightened): require a recognized TLD-
        // like trailing label. The previous "any non-numeric 2+ char suffix"
        // was too loose — `release.beta` / `build.123` triggered. Now the
        // suffix must be a known TLD/internal network suffix OR validate as
        // a real IPv4 (caught above).
        //
        // `local` is included intentionally: in real macOS deployments
        // `build.local`, `host.local`, etc. ARE legitimate Bonjour hostnames
        // and SHOULD be hashed. The user can opt out of hostname
        // anonymization at export time if they need them visible.
        let knownSuffixes: Set<String> = [
            "com", "net", "org", "io", "dev", "co", "ai", "app", "local",
            "internal", "lan", "home", "arpa", "edu", "gov", "mil"
        ]
        let parts = s.split(separator: ".").map(String.init)
        if parts.count >= 2,
           let last = parts.last,
           knownSuffixes.contains(last.lowercased()) {
            return true
        }
        return false
    }

    /// Scrub a URL string: hash host, drop credentials/query/fragment, keep scheme/port/path.
    ///
    /// **Path preservation is intentional** (audit-round-D41): URL paths are
    /// often valuable diagnostic context (`/api/tags`, `/v1/models`,
    /// `/healthz`) that helps a maintainer understand what the app was
    /// doing. Sensitive identifiers in paths (api keys baked into the path,
    /// user names in REST routes) are NOT scrubbed by this layer — the user
    /// is responsible for not configuring instance URLs that embed secrets
    /// in the path. The free-text Authorization/JSON-secret/bare-kv passes
    /// catch credentials in the more common locations.
    /// Non-URL input is returned unchanged (defensive — caller may pass arbitrary strings).
    /// Idempotent: applying twice produces the same output. A host that already
    /// matches the `host-<64 hex>` shape is left as-is.
    ///
    /// Audit-round-12: even for hostless authority forms (`scheme://user:pass@/`
    /// or `http:example.local/path?token=x`), still strip credentials, query,
    /// and fragment. The previous "no host → return raw" path was conservative
    /// but it preserved credentials and query data the README promises to drop.
    static func scrubURL(_ raw: String) -> String {
        // Audit-round-D37: a previously-scrubbed URL using bracketed-IPv6
        // syntax (`http://[host-<64hex>]/path`) survives `URLComponents`
        // parsing but fails to re-serialize because `host-...` isn't a
        // valid IPv6 literal. Detect and short-circuit so idempotent
        // scrubbing on that shape doesn't downgrade to the `<scrub-failed>`
        // placeholder.
        if raw.contains("[host-"),
           let rng = raw.range(of: #"\[host-[0-9a-f]{64}\]"#, options: .regularExpression),
           rng.lowerBound != raw.startIndex || rng.upperBound != raw.endIndex {
            // Strip credentials/query/fragment via the malformed-fallback
            // path which uses regex (doesn't choke on the bracketed token).
            return scrubMalformedURLLike(raw)
        }
        guard var comps = URLComponents(string: raw) else {
            // Audit-round-D16: URLComponents rejected it but the input still
            // SMELLS LIKE a URL (has a network scheme + ://). Don't return
            // raw — it may contain credentials/query/fragment. Fall back to
            // regex-based credential + query + fragment stripping.
            return scrubMalformedURLLike(raw)
        }
        // Reject inputs that URLComponents accepted but that lack any URL shape
        // (e.g. a bare word like "localhost"). We require a scheme to be safe.
        guard comps.scheme != nil else { return raw }

        // Hash host if present; for hostless URL-shaped strings, hash whatever
        // host-like identifier lives in the path's first component too. Audit-
        // round-D3: `http:example.local/path` parses with .host == nil and
        // .path == "example.local/path", which previously left `example.local`
        // visible. Detect and rewrite.
        if let host = comps.host, !host.isEmpty, !isHashedHost(host) {
            // URLComponents already strips IPv6 brackets when reading .host;
            // setting it back lets URLComponents re-bracket as needed.
            comps.host = "host-\(hashHost(host))"
        } else if comps.host == nil && !comps.path.isEmpty,
                  Self.isNetworkScheme(comps.scheme ?? "") {
            // Audit-round-D5: only attempt host-from-path recovery for
            // network-bearing schemes. Otherwise `mailto:user@example.com` and
            // `file:/Users/me/x` would get their path's first segment hashed
            // as if it were a hostname — that's both incorrect and lossy.
            // Hostless URL-shaped input: the would-be host got tucked into the
            // path. Audit-round-D4: skip leading empty segments so
            // `http:/example.local/path` AND `http:example.local/path` both
            // hash `example.local`. Also honor isHashedHost so an already-
            // hashed placeholder isn't re-hashed (keeps idempotency).
            let rawSegments = comps.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            // Find the first non-empty segment; track the prefix of empty
            // segments so we can faithfully reconstruct the leading slashes.
            var leadingSlashes = ""
            var hostIdx: Int? = nil
            for (idx, seg) in rawSegments.enumerated() {
                if seg.isEmpty {
                    leadingSlashes += "/"
                } else {
                    hostIdx = idx
                    break
                }
            }
            if let hi = hostIdx {
                let rawHostLike = rawSegments[hi]
                let hostPlusPort: String
                let hadCredentials: Bool
                if let atIdx = rawHostLike.lastIndex(of: "@") {
                    hostPlusPort = String(rawHostLike[rawHostLike.index(after: atIdx)...])
                    hadCredentials = true
                } else {
                    hostPlusPort = rawHostLike
                    hadCredentials = false
                }
                // Audit-round-D38: split host from port BEFORE the
                // looksLikeHost check, otherwise `example.local:11434`
                // fails the suffix test (it ends in digits, not `.local`)
                // and the host stays visible in the path.
                let hostLike: String
                let portSuffix: String
                if hostPlusPort.hasPrefix("[") {
                    if let closeBracket = hostPlusPort.firstIndex(of: "]") {
                        let inside = String(hostPlusPort[hostPlusPort.index(after: hostPlusPort.startIndex)..<closeBracket])
                        hostLike = "[" + inside + "]"
                        portSuffix = String(hostPlusPort[hostPlusPort.index(after: closeBracket)...])
                    } else {
                        hostLike = hostPlusPort
                        portSuffix = ""
                    }
                } else if let colon = hostPlusPort.lastIndex(of: ":"),
                          hostPlusPort[hostPlusPort.index(after: colon)...].allSatisfy({ $0.isASCII && $0.isNumber }) {
                    hostLike = String(hostPlusPort[hostPlusPort.startIndex..<colon])
                    portSuffix = String(hostPlusPort[colon...])
                } else {
                    hostLike = hostPlusPort
                    portSuffix = ""
                }
                let restSegments = rawSegments.dropFirst(hi + 1)
                let rest = restSegments.isEmpty ? "" : "/" + restSegments.joined(separator: "/")
                if Self.looksLikeHost(hostLike) {
                    // Audit-round-D39: for bracketed IPv6, strip the
                    // brackets before hashing so the token matches the
                    // authority-form scrubURL path (which hashes the inner
                    // address only). Re-add brackets on the way out.
                    let bracketed = hostLike.hasPrefix("[") && hostLike.hasSuffix("]")
                    let hostForHash = bracketed
                        ? String(hostLike.dropFirst().dropLast())
                        : hostLike
                    let hashedInner = isHashedHost(hostForHash)
                        ? hostForHash
                        : "host-\(hashHost(hostForHash))"
                    let hashed = bracketed ? "[\(hashedInner)]" : hashedInner
                    comps.path = leadingSlashes + hashed + portSuffix + rest
                } else if hadCredentials {
                    // Not host-shaped, but credentials were present —
                    // overwrite the segment with the credential-stripped
                    // remainder (host + port + path) so the user:pass@
                    // doesn't leak.
                    comps.path = leadingSlashes + hostPlusPort + rest
                }
                // else: leave the path alone; query/fragment get stripped below.
            }
        }
        comps.user = nil
        comps.password = nil
        comps.query = nil          // SEC-blocker-2: drop entire query — even keys are sensitive
        comps.fragment = nil
        // Audit-round-D2: if serialization fails after we've already decided
        // the input was URL-shaped + sensitive, returning `raw` would leak
        // exactly the credentials/query/fragment we just stripped. Return a
        // conservative placeholder instead.
        return comps.string ?? "\(comps.scheme ?? "url")://<scrub-failed>"
    }

    // MARK: - Free-text scrubbing

    // Regex patterns are compiled once. Order matters: longer/more-specific
    // patterns run first so they don't get clobbered by greedier ones.
    private static let ipv4Pattern = try! NSRegularExpression(
        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\b"#)

    // Bracketed IPv6 (URL form): [fd00::1], [::1], [fe80::1%en0], [fe80::1%25en0]…
    // Audit-round-5: allow optional `%zone` suffix inside the brackets so
    // link-local addresses on a specific interface (very common on macOS) are
    // also scrubbed. The percent can be literal or URL-encoded as %25.
    private static let ipv6BracketedPattern = try! NSRegularExpression(
        pattern: #"\[[0-9a-fA-F:]+(?:%(?:25)?[A-Za-z0-9._-]+)?\]"#)

    // Bare IPv6 candidate: hex-and-colons tokens that LOOK plausibly like
    // IPv6. We don't trust the regex alone — every match runs through
    // `inet_pton(AF_INET6)` to confirm. This avoids the v0.2-audit issue
    // where `12:34` and `a:b` got mangled into ip-<hash>.
    //
    // Audit-round-4: broadened to a single tolerant pattern that captures any
    // contiguous run of `[0-9a-fA-F:.]+` containing at least two colons (so
    // `2001:db8::1` and `2001:db8:1::abcd` are both caught), plus an optional
    // `%zone` suffix. `inet_pton` does the real validation downstream.
    private static let ipv6BarePattern = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z:])[0-9A-Fa-f:.]+:[0-9A-Fa-f:.]+(?:%[A-Za-z0-9._-]+)?(?![0-9A-Za-z])"#)

    // Audit-round-11: `(?i)` makes the suffix alternation case-insensitive so
    // `Server.LOCAL` and `vm.Compute.AmazonAWS.Com` are matched. The optional
    // trailing dot accepts fully-qualified DNS names; `canonicalize()` strips
    // the dot before hashing so the FQDN and non-FQDN spellings hash equal.
    private static let hostnamePattern = try! NSRegularExpression(
        pattern: #"(?i)\b[A-Za-z0-9](?:[A-Za-z0-9\-]{0,62}\.)+(?:local|ts\.net|tailscale\.net|compute\.amazonaws\.com|googleusercontent\.com)\.?\b"#)

    // Authorization header — redact EVERYTHING after `Authorization:`. Audit-
    // round-D28: anchored `^` form misses formatted log lines that prefix
    // the header with timestamp/level/category. Match anywhere on the line
    // via word boundary so log-formatted Authorization values are caught too.
    private static let authHeaderPattern = try! NSRegularExpression(
        pattern: #"(?im)(\bAuthorization\s*:\s*).+$"#)

    // Query-string secrets: ?api_key=xxx, ?token=xxx, ?access_token=xxx, ?key=xxx, ?auth=xxx
    private static let querySecretPattern = try! NSRegularExpression(
        pattern: #"(?i)([?&](?:api[_-]?key|access[_-]?token|token|key|auth|password|secret)=)[^&\s"'<>]+"#)

    // Free-text URL pattern: any URL with a network-bearing scheme in a log
    // line. Gets routed through scrubURL() so the host hashes + the query /
    // fragment / credentials are stripped, even when the host doesn't match
    // the hard-coded suffix list.
    //
    // Audit-round-D11: also match hostless authority-style forms (`scheme:host…`
    // without the `//`) so `http:user:pass@example.local/path?token=x`
    // gets routed through scrubURL instead of leaving the user:pass@ visible.
    private static let freeTextURLPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:https?|wss?|ftps?):(?://)?[^\s'"<>]+"#)

    /// Spans already in `host-<hex>` / `ip-<hex>` form — produced by earlier
    /// passes. We swap them out for short non-matchable placeholders before
    /// running IPv4/IPv6 regex passes, then restore them. Keeps scrub
    /// idempotent on inputs containing previously-anonymized tokens (and on
    /// tokens whose hex happens to contain `10.0.0.1`-style substrings).
    private static let anonymizedSpanPattern = try! NSRegularExpression(
        pattern: #"\b(?:host|ip)-[0-9a-f]{64}\b"#)

    private static func maskAnonymizedSpans(_ input: String) -> (String, (String) -> String) {
        let nsrange = NSRange(input.startIndex..., in: input)
        let matches = anonymizedSpanPattern.matches(in: input, range: nsrange)
        guard !matches.isEmpty else { return (input, { $0 }) }
        // Audit-round-D21: use a per-call UUID prefix so the placeholder
        // shape can never appear in user input (UUIDs are unique per call).
        // Eliminates the global-replace collision with a literal
        // `\u{0001}MASK0\u{0001}` substring in the raw input.
        let token = UUID().uuidString
        var originals: [String] = []
        var masked = ""
        var cursor = input.startIndex
        for (i, m) in matches.enumerated() {
            guard let r = Range(m.range, in: input) else { continue }
            masked.append(contentsOf: input[cursor..<r.lowerBound])
            originals.append(String(input[r]))
            masked += "\u{0001}\(token)-MASK\(i)\u{0001}"
            cursor = r.upperBound
        }
        masked.append(contentsOf: input[cursor..<input.endIndex])
        let restore: (String) -> String = { s in
            var out = s
            for (i, orig) in originals.enumerated() {
                out = out.replacingOccurrences(of: "\u{0001}\(token)-MASK\(i)\u{0001}", with: orig)
            }
            return out
        }
        return (masked, restore)
    }

    /// Apply all redaction passes to a free-text string (log line, README, etc.).
    /// Idempotent — running twice produces the same output.
    static func scrub(_ text: String) -> String {
        var s = text

        // 1. Authorization headers first — they're complete log lines, not URL
        //    structures, so order doesn't conflict with the URL pass.
        s = replaceAll(s, regex: authHeaderPattern, replacement: "$1<redacted>")

        // 2. Full URLs in free text → routed through scrubURL so the host hashes
        //    and query/fragment/credentials are stripped even when the host
        //    doesn't match the suffix list. Done BEFORE the query-secret pass
        //    (audit-round-12) so URL boundary matching isn't disrupted by
        //    `<redacted>` markers inserted into URL query strings — which would
        //    leave the host and structure visible alongside the redacted value.
        //
        // Audit-round-9: trim trailing prose punctuation, but only strip
        // structural delimiters (`)` / `]`) when they're UNBALANCED — i.e.
        // when the URL contains more closers than openers. That preserves
        // the closing `]` of a bracketed IPv6 URL like `http://[fd00::1]`,
        // which the previous version was eating along with sentence
        // punctuation and breaking scrubURL.
        s = replaceMatches(s, regex: freeTextURLPattern) { match in
            var url = match
            var trailing = ""
            let alwaysStrip: Set<Character> = [".", ",", ";", ":", "!", "?"]
            while let last = url.last {
                if alwaysStrip.contains(last) {
                    trailing = String(last) + trailing
                    url.removeLast()
                    continue
                }
                if last == ")" || last == "]" {
                    let opener: Character = (last == ")") ? "(" : "["
                    let opens = url.filter { $0 == opener }.count
                    let closes = url.filter { $0 == last }.count
                    if closes > opens {
                        trailing = String(last) + trailing
                        url.removeLast()
                        continue
                    }
                }
                break
            }
            return Anonymizer.scrubURL(url) + trailing
        }

        // 3. Bare query-string secrets that weren't inside a full URL.
        //    Catches log lines like `params: ?token=abc` outside a URL context.
        s = replaceAll(s, regex: querySecretPattern, replacement: "$1<redacted>")

        // 4. Hostnames (specific suffixes) before IPs — a string like
        //    "10.0.0.1.mycorp.local" should land on the hostname rule.
        s = replaceWithHash(s, regex: hostnamePattern)

        // 5. IP passes. Order matters: IPv4 runs FIRST so a dotted-decimal
        // address like `10.0.0.1` is hashed before the bare-IPv6 pattern can
        // match it as a partial candidate. Bracketed IPv6 then bare IPv6.
        //
        // Already-anonymized spans are masked across each pass via a
        // placeholder swap. Audit-round-D24: re-mask BETWEEN IP passes so a
        // freshly-generated `ip-<hash>` token from the IPv4 pass can't be
        // matched by the IPv6 pass that follows.
        let (masked1, restore1) = Self.maskAnonymizedSpans(s)
        var s1 = replaceWithIPHash(masked1, regex: ipv4Pattern)
        s1 = restore1(s1)
        let (masked2, restore2) = Self.maskAnonymizedSpans(s1)
        var s2 = replaceIPv6Bracketed(masked2)
        s2 = replaceValidatedIPv6(s2)
        s = restore2(s2)

        return s
    }

    // MARK: - Regex helpers

    private static func replaceAll(_ input: String, regex: NSRegularExpression, replacement: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
    }

    /// Replace every match with `host-<hash-of-match>`. Walks matches in reverse
    /// so earlier replacements don't invalidate later NSRanges.
    private static func replaceWithHash(_ input: String, regex: NSRegularExpression) -> String {
        replaceMatches(input, regex: regex) { "host-\(hashHost($0))" }
    }

    private static func replaceWithIPHash(_ input: String, regex: NSRegularExpression) -> String {
        replaceMatches(input, regex: regex) { "ip-\(hashHost($0))" }
    }

    /// Bracketed IPv6: keep the brackets, hash the contents inside.
    private static func replaceIPv6Bracketed(_ input: String) -> String {
        replaceMatches(input, regex: ipv6BracketedPattern) { match in
            // Strip the [ and ] before validating + hashing for stable output.
            var inner = match
            if inner.hasPrefix("[") { inner.removeFirst() }
            if inner.hasSuffix("]") { inner.removeLast() }
            guard isValidIPv6(inner) else { return match }
            return "[ip-\(hashHost(inner))]"
        }
    }

    /// Bare IPv6: only replace candidates that `inet_pton` validates as real IPv6.
    /// Prevents tokens like `12:34` or `a:b` (or random `::` runs) from being
    /// silently mangled.
    private static func replaceValidatedIPv6(_ input: String) -> String {
        replaceMatches(input, regex: ipv6BarePattern) { match in
            isValidIPv6(match) ? "ip-\(hashHost(match))" : match
        }
    }

    /// Strip an optional `%zoneId` suffix, then ask the kernel via `inet_pton`
    /// whether the remaining text is a real IPv6 literal.
    private static func isValidIPv6(_ s: String) -> Bool {
        let bare = s.split(separator: "%", maxSplits: 1).first.map(String.init) ?? s
        var addr = in6_addr()
        return bare.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }

    /// Build the result by walking `input` forward and re-using only ranges from
    /// `input`. Avoids the audit-round-2 hazard where converting NSRanges (from
    /// the original string) against a progressively-mutated `result` could shift
    /// or invalidate later indices whenever a replacement changed UTF-16 length.
    private static func replaceMatches(_ input: String,
                                       regex: NSRegularExpression,
                                       transform: (String) -> String) -> String {
        let nsrange = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, range: nsrange)
        guard !matches.isEmpty else { return input }
        var result = ""
        result.reserveCapacity(input.count)
        var cursor = input.startIndex
        for m in matches {
            guard let r = Range(m.range, in: input) else { continue }
            // Skip degenerate / overlapping matches that begin before our cursor.
            if r.lowerBound < cursor { continue }
            result.append(contentsOf: input[cursor..<r.lowerBound])
            result.append(transform(String(input[r])))
            cursor = r.upperBound
        }
        result.append(contentsOf: input[cursor..<input.endIndex])
        return result
    }
}
