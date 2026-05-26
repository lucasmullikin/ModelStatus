import Foundation
import UserNotifications
import OSLog
import AppKit

private let logger = Logger(subsystem: ConfigManager.bundleIdentifier, category: "updater")

/// Lightweight value record of "what version did we last find, and where to go for it."
/// Read via `UpdateChecker.cachedAvailableUpdate()` — nil when no update is pending.
struct CachedUpdate: Equatable, Sendable {
    let tag: String
    let htmlURL: String
}

/// Lightweight GitHub Releases poll. No dependencies, no auto-install — just
/// a notification when a newer tag appears upstream.
///
/// - Checks at most once per 24h on success (transient failures don't lock out checks).
/// - Never re-notifies for the same tag (UserDefaults memoization, written after notify succeeds).
/// - Semver-aware pre-release comparison: v0.2.0 > v0.2.0-beta.
enum UpdateChecker {
    // Canonical update source. The repository slug is `ModelStatus` (the
    // product name); the local development path being named `OllamaStatus`
    // is a vestige from the v0.1 → v0.2 rename and isn't a hint about
    // upstream. If this app is forked, this URL is the only place to update.
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/lucasmullikin/ModelStatus/releases/latest"
    )!
    private static let lastSeenVersionKey   = "ModelStatus.UpdateChecker.lastSeenVersion"
    private static let lastSeenURLKey       = "ModelStatus.UpdateChecker.lastSeenURL"
    private static let lastCheckTimeKey     = "ModelStatus.UpdateChecker.lastCheckTime"
    private static let snoozeUntilKey       = "ModelStatus.UpdateChecker.snoozeUntil"
    private static let dismissedVersionsKey = "ModelStatus.UpdateChecker.dismissedVersions"
    private static let lastNotifiedVersionKey = "ModelStatus.UpdateChecker.lastNotifiedVersion"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlUrl: String
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
        }
    }

    /// Parsed semver-ish version. Strips leading "v"/"V"; preserves pre-release identifier
    /// (everything after the first hyphen) so we can apply the semver rule
    /// "release > matching pre-release".
    struct Version: Equatable {
        let numeric: [Int]
        let preRelease: String?

        static func parse(_ raw: String) -> Version? {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            // Case-insensitive "v" prefix per common tag conventions.
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            guard !s.isEmpty else { return nil }
            // SemVer §10 build metadata follows `+` and does NOT affect precedence.
            if let plus = s.firstIndex(of: "+") {
                s = String(s[s.startIndex..<plus])
                guard !s.isEmpty else { return nil }
            }
            // Audit-round-D23 note on Int conversion below: SemVer allows
            // arbitrarily-large numeric identifiers but realistic release tags
            // are well under Int.max. Rejecting >Int.max identifiers here
            // means an upstream tag like `999999999999999999999.0.0` is
            // treated as malformed, which is the correct user-visible result
            // for an obviously-invalid tag.
            var pre: String? = nil
            if let h = s.firstIndex(of: "-") {
                let prePart = String(s[s.index(after: h)...])
                // Audit-round-D2: reject a bare trailing hyphen (`1.2.3-`)
                // outright. The previous code silently treated empty
                // pre-release as no-pre-release and accepted `1.2.3-` as a
                // stable `1.2.3`.
                guard !prePart.isEmpty else { return nil }
                let segs = prePart.split(separator: ".", omittingEmptySubsequences: false)
                // Each pre-release identifier must:
                //   • be non-empty
                //   • contain only ASCII alphanumerics + hyphens (SemVer §9)
                //   • not be a numeric identifier with leading zeroes (SemVer §9 numeric rule)
                for seg in segs {
                    if seg.isEmpty { return nil }
                    if !Self.isValidPreReleaseIdentifier(String(seg)) { return nil }
                }
                pre = prePart
                s = String(s[s.startIndex..<h])
            }
            // omittingEmptySubsequences:false catches "1.", "1..2", "..1" — bare dots
            // are not valid semver. Each part must be a non-empty integer.
            // Audit-round-5: also reject core numeric identifiers with leading
            // zeroes (SemVer §2 disallows them) — `01.2.3` and `v1.02.3` are not
            // valid releases.
            let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty else { return nil }
            var nums: [Int] = []
            for p in parts {
                guard !p.isEmpty, let n = Int(p), n >= 0 else { return nil }
                if p.count > 1 && p.first == "0" { return nil }
                nums.append(n)
            }
            guard !nums.isEmpty else { return nil }
            return Version(numeric: nums, preRelease: pre)
        }

        /// Returns true if `self` > `other`. Implements semver pre-release rule:
        /// numeric equal AND self has no preRelease while other has preRelease → self > other.
        func isNewer(than other: Version) -> Bool {
            let n = max(numeric.count, other.numeric.count)
            for i in 0..<n {
                let a = i < numeric.count ? numeric[i] : 0
                let b = i < other.numeric.count ? other.numeric[i] : 0
                if a > b { return true }
                if a < b { return false }
            }
            // Numeric equal — release > pre-release, then per-identifier semver compare.
            switch (preRelease, other.preRelease) {
            case (nil, nil):    return false
            case (nil, _):      return true
            case (_, nil):      return false
            case (let a?, let b?):
                return Self.comparePreRelease(a, b) > 0
            }
        }

        /// SemVer §9 pre-release identifier validation: ASCII alphanumerics + hyphens,
        /// and a numeric identifier must not have leading zeroes (except literal "0").
        static func isValidPreReleaseIdentifier(_ id: String) -> Bool {
            guard !id.isEmpty else { return false }
            // Allowed chars: A-Z a-z 0-9 -
            for c in id.unicodeScalars {
                let ok = (c >= "0" && c <= "9")
                    || (c >= "A" && c <= "Z")
                    || (c >= "a" && c <= "z")
                    || c == "-"
                if !ok { return false }
            }
            // If purely numeric, reject leading zeroes (but allow exactly "0").
            if id.allSatisfy({ $0.isASCII && $0.isNumber }) {
                if id.count > 1 && id.first == "0" { return false }
            }
            return true
        }

        /// Semver §11.4 pre-release identifier comparison:
        ///   • split on "."
        ///   • numeric identifiers compared numerically
        ///   • non-numeric identifiers compared ASCII-lex
        ///   • numeric < non-numeric when types differ
        ///   • shorter set < longer set if all prior identifiers equal
        /// Returns 1 if a > b, -1 if a < b, 0 if equal.
        static func comparePreRelease(_ a: String, _ b: String) -> Int {
            let aParts = a.split(separator: ".").map(String.init)
            let bParts = b.split(separator: ".").map(String.init)
            let n = max(aParts.count, bParts.count)
            for i in 0..<n {
                if i >= aParts.count { return -1 }
                if i >= bParts.count { return 1 }
                let ap = aParts[i]
                let bp = bParts[i]
                // Audit-round-5: detect "numeric" by digit composition, not
                // `Int(ap)`. Arbitrarily-large SemVer numeric identifiers can
                // exceed Int.max and would silently fall back to lex compare.
                let aNum = ap.allSatisfy { $0.isASCII && $0.isNumber }
                let bNum = bp.allSatisfy { $0.isASCII && $0.isNumber }
                if aNum && bNum {
                    if ap != bp {
                        // Compare numeric strings: shorter is smaller (no leading
                        // zeros allowed in pre-release numerics, validated at parse).
                        if ap.count != bp.count { return ap.count < bp.count ? -1 : 1 }
                        return ap < bp ? -1 : 1
                    }
                } else if aNum, !bNum {
                    return -1
                } else if !aNum, bNum {
                    return 1
                } else if ap != bp {
                    return ap < bp ? -1 : 1
                }
            }
            return 0
        }
    }

    /// Call from AppDelegate.applicationDidFinishLaunching (force=false) and from the
    /// "Check for Updates…" menu item (force=true).
    ///
    /// Audit-round-3: App Store builds update via the App Store itself — polling
    /// GitHub Releases there only leads to misleading "update available" toasts
    /// pointing at a binary the user can't actually install. Short-circuit early.
    static func check(force: Bool = false) async {
        if isAppStoreInstalled() {
            if force { await notifyAppStoreInstall() }
            return
        }
        let now = Date()
        if !force, let last = UserDefaults.standard.object(forKey: lastCheckTimeKey) as? Date,
           now.timeIntervalSince(last) < checkInterval {
            return
        }

        var req = URLRequest(url: releasesURL)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                if force { await notifyError("Update check failed (no HTTP response)") }
                return
            }
            guard http.statusCode == 200 else {
                logger.debug("update check: HTTP \(http.statusCode)")
                if force {
                    if http.statusCode == 404 {
                        await notifyError("No releases published yet")
                    } else {
                        await notifyError("Update check failed (HTTP \(http.statusCode))")
                    }
                }
                return
            }
            // Mark successful check time only after a 200 OK + decode + version
            // parse. Audit-round-D2: writing lastCheckTime before version parsing
            // succeeds could lock background checks out for 24h on a malformed
            // upstream tag, delaying recovery once the tag is fixed.
            let release = try JSONDecoder().decode(LatestRelease.self, from: data)

            let current = currentVersion()
            guard let currentV = Version.parse(current), let latestV = Version.parse(release.tagName) else {
                logger.debug("update check: unparseable version (\(current, privacy: .public) vs \(release.tagName, privacy: .public))")
                if force { await notifyError("Couldn't parse version strings") }
                return
            }
            UserDefaults.standard.set(now, forKey: lastCheckTimeKey)

            if !latestV.isNewer(than: currentV) {
                logger.notice("update check: \(release.tagName, privacy: .public) not newer than \(current, privacy: .public) — up to date")
                if force { await notifyUpToDate(current: current) }
                return
            }

            // Persist what we found so the menu can offer a "View release" item even
            // if the user dismisses the banner. Source-of-truth for the menu UI.
            UserDefaults.standard.set(release.tagName, forKey: lastSeenVersionKey)
            UserDefaults.standard.set(release.htmlUrl, forKey: lastSeenURLKey)

            // Dismissed-tag handling: a manual "Check for Updates…" should still
            // give the user feedback even if they previously dismissed the latest
            // tag. Background checks stay quiet.
            let dismissed = UserDefaults.standard.stringArray(forKey: dismissedVersionsKey) ?? []
            if dismissed.contains(release.tagName) {
                if force {
                    await notifyDismissedButForced(latestTag: release.tagName, current: current)
                } else {
                    logger.notice("update check: tag \(release.tagName, privacy: .public) was dismissed by user; suppressing banner")
                }
                return
            }

            // Don't re-notify for the same tag we already notified about, unless force=true
            let lastNotified = UserDefaults.standard.string(forKey: lastNotifiedVersionKey)
            if lastNotified == release.tagName, !force { return }

            // Fire the notification BEFORE marking lastNotified, so a failed schedule doesn't
            // silently suppress re-notification.
            let scheduled = await notifyUpdateAvailable(latestTag: release.tagName,
                                                       url: release.htmlUrl,
                                                       current: current)
            if scheduled {
                UserDefaults.standard.set(release.tagName, forKey: lastNotifiedVersionKey)
            }
        } catch {
            logger.error("update check failed: \(error.localizedDescription, privacy: .public)")
            if force { await notifyError(error.localizedDescription) }
        }
    }

    private static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    /// Returns true if the notification was successfully scheduled.
    private static func notifyUpdateAvailable(latestTag: String, url: String, current: String) async -> Bool {
        await ensurePermission()
        let content = UNMutableNotificationContent()
        content.title = "ModelStatus update available"
        content.body = "v\(current) → \(latestTag) — tap to view release"
        content.userInfo = ["url": url]
        content.sound = .default
        let req = UNNotificationRequest(identifier: "modelstatus.update.\(latestTag)",
                                        content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(req)
            return true
        } catch {
            logger.error("notification add failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func notifyUpToDate(current: String) async {
        await ensurePermission()
        let content = UNMutableNotificationContent()
        content.title = "ModelStatus"
        content.body = "You’re up to date (v\(current))."
        let req = UNNotificationRequest(identifier: "modelstatus.update.uptodate",
                                        content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    private static func notifyError(_ message: String) async {
        await ensurePermission()
        let content = UNMutableNotificationContent()
        content.title = "ModelStatus update check failed"
        content.body = message
        let req = UNNotificationRequest(identifier: "modelstatus.update.error",
                                        content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    /// Force=true checked the network and found the latest tag is one the user
    /// already dismissed. Tell them so the click doesn't appear to do nothing.
    private static func notifyDismissedButForced(latestTag: String, current: String) async {
        await ensurePermission()
        let content = UNMutableNotificationContent()
        content.title = "ModelStatus"
        content.body = "Latest \(latestTag) was dismissed earlier (you’re on v\(current))."
        let req = UNNotificationRequest(identifier: "modelstatus.update.dismissed-but-forced",
                                        content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    /// App Store installs update via the Mac App Store, not GitHub Releases.
    /// Tell the user where to look instead of silently doing nothing.
    private static func notifyAppStoreInstall() async {
        await ensurePermission()
        let content = UNMutableNotificationContent()
        content.title = "ModelStatus"
        content.body = "App Store version — updates come from the Mac App Store, not GitHub."
        let req = UNNotificationRequest(identifier: "modelstatus.update.app-store",
                                        content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    /// Lazy permission request. macOS only shows the prompt once per app lifetime;
    /// subsequent calls are no-ops if user already responded.
    private static func ensurePermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    // MARK: - Cached-update accessors (read by AppDelegate to render menu items)

    /// Returns the most-recently-discovered update tag IF it is newer than the
    /// currently-running version, has not been dismissed, and is not snoozed.
    /// Returns nil otherwise.
    ///
    /// Pure synchronous read — safe to call from menu population on the main thread.
    static func cachedAvailableUpdate() -> CachedUpdate? {
        // Audit-round-D49: short-circuit on App Store installs the same way
        // `check()` does. Without this gate, a stale `lastSeenVersionKey`
        // from a pre-App-Store install could keep showing a GitHub release
        // banner on an App Store build, which would be misleading.
        if isAppStoreInstalled() { return nil }
        // Snooze hides the menu item for the snooze window — separate key from
        // `lastCheckTimeKey` so it doesn't drag the next background check around.
        if let snoozeUntil = UserDefaults.standard.object(forKey: snoozeUntilKey) as? Date,
           snoozeUntil > Date() { return nil }
        guard let tag = UserDefaults.standard.string(forKey: lastSeenVersionKey),
              let url = UserDefaults.standard.string(forKey: lastSeenURLKey) else { return nil }
        let dismissed = UserDefaults.standard.stringArray(forKey: dismissedVersionsKey) ?? []
        if dismissed.contains(tag) { return nil }
        guard let latest = Version.parse(tag),
              let current = Version.parse(currentVersion()),
              latest.isNewer(than: current) else { return nil }
        return CachedUpdate(tag: tag, htmlURL: url)
    }

    /// Hide the "update available" menu item for 7 days. Stored in its OWN
    /// UserDefaults key so the next background check still runs on its normal
    /// 24h cadence — when the user un-snoozes (or 7 days elapse), they see the
    /// latest tag immediately.
    static func snoozeCachedUpdate() {
        let snoozeUntil = Date().addingTimeInterval(7 * 24 * 60 * 60)
        UserDefaults.standard.set(snoozeUntil, forKey: snoozeUntilKey)
        logger.notice("update snoozed until \(snoozeUntil, privacy: .public)")
    }

    /// Add the cached tag to the dismissed list — `cachedAvailableUpdate()` returns nil
    /// going forward, and the next check won't notify even if the tag is still latest.
    /// Capped at 16 entries to keep UserDefaults small; oldest entry drops off.
    static func dismissCachedUpdate() {
        guard let tag = UserDefaults.standard.string(forKey: lastSeenVersionKey) else { return }
        var list = UserDefaults.standard.stringArray(forKey: dismissedVersionsKey) ?? []
        if list.contains(tag) { return }
        list.append(tag)
        if list.count > 16 { list = Array(list.suffix(16)) }
        UserDefaults.standard.set(list, forKey: dismissedVersionsKey)
        logger.notice("update tag \(tag, privacy: .public) dismissed")
    }

    // MARK: - Install-source detection (drives "how to upgrade" messaging)

    /// True if either Homebrew prefix is present on disk. We can't tell whether *this
    /// specific app* came from brew vs. a direct download — Cask doesn't leave a
    /// receipt in the bundle — so this gate is "is brew on this machine at all,"
    /// which is the right question for the menu hint ("you have brew; here's the
    /// upgrade command").
    static func isHomebrewInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            || FileManager.default.fileExists(atPath: "/usr/local/bin/brew")
    }

    /// True if the running bundle has a Mac App Store receipt. App Store builds
    /// don't update via GitHub Releases — they update via the App Store itself —
    /// so when this is true the menu hides the manual upgrade hint entirely.
    /// Memoized: receipt path doesn't change at runtime.
    private static let _isAppStoreInstalled: Bool = {
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
            && url.lastPathComponent == "receipt"
    }()
    static func isAppStoreInstalled() -> Bool { _isAppStoreInstalled }

    /// Copy `brew upgrade --cask modelstatus` to the user's pasteboard.
    static func copyBrewUpgradeCommand() {
        let cmd = "brew upgrade --cask modelstatus"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
    }
}
