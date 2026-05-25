import Foundation
import UserNotifications
import OSLog

private let logger = Logger(subsystem: ConfigManager.bundleIdentifier, category: "updater")

/// Lightweight GitHub Releases poll. No dependencies, no auto-install — just
/// a notification when a newer tag appears upstream.
///
/// - Checks at most once per 24h on success (transient failures don't lock out checks).
/// - Never re-notifies for the same tag (UserDefaults memoization, written after notify succeeds).
/// - Semver-aware pre-release comparison: v0.2.0 > v0.2.0-beta.
enum UpdateChecker {
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/lucasmullikin/ModelStatus/releases/latest"
    )!
    private static let lastSeenVersionKey = "ModelStatus.UpdateChecker.lastSeenVersion"
    private static let lastCheckTimeKey   = "ModelStatus.UpdateChecker.lastCheckTime"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlUrl: String
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
        }
    }

    /// Parsed semver-ish version. Strips leading "v"; preserves pre-release identifier
    /// (everything after the first hyphen) so we can apply the semver rule
    /// "release > matching pre-release".
    struct Version: Equatable {
        let numeric: [Int]
        let preRelease: String?

        static func parse(_ raw: String) -> Version? {
            var s = raw
            if s.hasPrefix("v") { s.removeFirst() }
            var pre: String? = nil
            if let h = s.firstIndex(of: "-") {
                pre = String(s[s.index(after: h)...])
                s = String(s[s.startIndex..<h])
            }
            let parts = s.split(separator: ".").map { String($0) }
            // Reject if any numeric component fails to parse — return nil to mark as incomparable.
            var nums: [Int] = []
            for p in parts {
                guard let n = Int(p) else { return nil }
                nums.append(n)
            }
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
            // Numeric equal — release > pre-release
            switch (preRelease, other.preRelease) {
            case (nil, nil):    return false
            case (nil, _):      return true   // self is release, other is pre → self > other
            case (_, nil):      return false  // self is pre, other is release → self < other
            case (let a?, let b?): return a > b
            }
        }
    }

    /// Call from AppDelegate.applicationDidFinishLaunching (force=false) and from the
    /// "Check for Updates…" menu item (force=true).
    static func check(force: Bool = false) async {
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
            // Mark successful check time only after a 200 OK + decode.
            let release = try JSONDecoder().decode(LatestRelease.self, from: data)
            UserDefaults.standard.set(now, forKey: lastCheckTimeKey)

            let current = currentVersion()
            guard let currentV = Version.parse(current), let latestV = Version.parse(release.tagName) else {
                logger.debug("update check: unparseable version (\(current, privacy: .public) vs \(release.tagName, privacy: .public))")
                if force { await notifyError("Couldn't parse version strings") }
                return
            }

            if !latestV.isNewer(than: currentV) {
                logger.debug("update check: \(release.tagName, privacy: .public) not newer than \(current, privacy: .public)")
                if force { await notifyUpToDate(current: current) }
                return
            }

            // Don't re-notify for the same tag, unless force=true
            let lastSeen = UserDefaults.standard.string(forKey: lastSeenVersionKey)
            if lastSeen == release.tagName, !force { return }

            // Fire the notification BEFORE marking lastSeen, so a failed schedule doesn't
            // silently suppress re-notification.
            let scheduled = await notifyUpdateAvailable(latestTag: release.tagName,
                                                       url: release.htmlUrl,
                                                       current: current)
            if scheduled {
                UserDefaults.standard.set(release.tagName, forKey: lastSeenVersionKey)
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

    /// Lazy permission request. macOS only shows the prompt once per app lifetime;
    /// subsequent calls are no-ops if user already responded.
    private static func ensurePermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
}
