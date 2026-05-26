import Foundation
import ServiceManagement
import os

/// Wrapper around `SMAppService.mainApp` for the "Start ModelStatus at login"
/// feature. Architect-D53 #54: replaces the previous LaunchAgent plist +
/// launchctl bootstrap dance.
///
/// **Why SMAppService (macOS 13+):**
/// - **Works in the App Store sandbox.** The old LaunchAgent approach
///   required writing into `~/Library/LaunchAgents/`, which the sandbox
///   blocks. SMAppService is approved for sandboxed apps.
/// - **No external plist file shipped in the .app.** The system records the
///   registration; no `cp LaunchAgent/com.lucrativepictures.ModelStatus.plist
///   ~/Library/LaunchAgents/` step the user has to do by hand.
/// - **No `launchctl bootstrap`.** SMAppService handles enable/disable
///   atomically.
/// - **Survives app updates.** SMAppService persists the registration across
///   .app bundle replacement.
///
/// **Constraint:** `SMAppService.mainApp.register()` returns
/// `errSMAppServiceNotEligible` (or fails silently) when the app runs from a
/// location outside `/Applications` (e.g., `~/Downloads/ModelStatus.app` or a
/// dev-build path). In practice this means the user has to install the app
/// to `/Applications` before toggling Start at Login on. The error is
/// surfaced via OSLog so a diagnostic bundle captures the misconfiguration.
@MainActor
enum LoginItem {
    private static let logger = Logger(subsystem: ConfigManager.bundleIdentifier,
                                       category: "login-item")

    /// Whether the user has opted in via the Settings toggle.
    /// `SMAppService.mainApp.status == .enabled` is the source of truth; we
    /// don't mirror it in UserDefaults because the system can disable it for
    /// us (e.g., user toggled it off in System Settings → General → Login
    /// Items) and we'd present a stale state.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Toggle the login item to `enabled`. Returns true on success.
    /// Returns false (and logs the error) if registration fails — usually
    /// because the app isn't in `/Applications` yet.
    @discardableResult
    static func enable() -> Bool {
        do {
            try SMAppService.mainApp.register()
            logger.info("login item registered")
            return true
        } catch {
            logger.error("SMAppService.register failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Toggle the login item to `disabled`. Returns true on success.
    @discardableResult
    static func disable() -> Bool {
        do {
            try SMAppService.mainApp.unregister()
            logger.info("login item unregistered")
            return true
        } catch {
            logger.error("SMAppService.unregister failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// One-shot helper for the Settings checkbox handler.
    @discardableResult
    static func set(_ desired: Bool) -> Bool {
        desired ? enable() : disable()
    }

    /// Human-readable explanation for the error path. Shown in a small label
    /// next to the Settings checkbox when registration fails.
    static var failureHint: String {
        // SMAppService.mainApp.status values (macOS 13+):
        // .notRegistered, .enabled, .requiresApproval, .notFound
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return "Move ModelStatus.app to /Applications, then try again."
        case .requiresApproval:
            return "Approve ModelStatus in System Settings → General → Login Items."
        case .notFound:
            return "ModelStatus.app must be installed in /Applications for this to work."
        case .enabled:
            return ""
        @unknown default:
            return "Unknown SMAppService status; check Console.app for errors."
        }
    }
}
