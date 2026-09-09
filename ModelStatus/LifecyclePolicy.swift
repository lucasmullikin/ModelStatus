import Foundation

/// Pure decision function for the approved-server dormant lifecycle.
///
/// A previously-approved server is kept and polled even after it goes
/// unreachable, so it auto-reappears the moment it answers again — this is
/// *monitoring a known URL*, not network discovery, so it adds no background
/// LAN/Tailscale scanning and keeps the on-demand-only privacy promise intact.
///
/// Timeline for one instance (ref = lastSeenReachable ?? addedAt):
///   reachable .......................... markReachable (revives if archived)
///   unreachable, < 24h down ............ none (dormant — greyed in menu)
///   unreachable, >= 24h down ........... archive (hidden from menu)
///   archived, reachable again .......... revive (silent reappear)
///   archived, > 30d ago ................ hardDelete (config + Keychain)
enum LifecyclePolicy {

    /// Hide-from-menu / archive threshold. Unreachable longer than this and a
    /// visible server becomes archived.
    static let dormantWindow: TimeInterval = 24 * 3600
    /// How long an archived (soft-forgotten) server is remembered for silent
    /// auto-revival before it's hard-deleted.
    static let archiveRetention: TimeInterval = 30 * 24 * 3600
    /// How often archived URLs are re-checked for revival (used by Monitor,
    /// not by `classify`).
    static let revivalInterval: TimeInterval = 600

    enum Transition: Equatable {
        case none           // no state change
        case markReachable  // set lastSeenReachable = now; clear archivedAt if set
        case archive        // set archivedAt = now (hide from menu)
        case revive         // clear archivedAt; set lastSeenReachable = now
        case hardDelete     // remove instance entirely (config + Keychain)
    }

    /// Decide the transition for one instance given the current poll result.
    /// `enabled` is the user's `autoManageDormant` toggle — when false, the
    /// only transition allowed is `markReachable` (so re-enabling later has
    /// fresh data); servers never auto-archive or auto-delete.
    static func classify(
        now: Date,
        addedAt: Date,
        lastSeenReachable: Date?,
        archivedAt: Date?,
        reachable: Bool,
        enabled: Bool
    ) -> Transition {
        if reachable {
            // A reachable archived server revives; a reachable visible one
            // just refreshes its lastSeen timestamp.
            return archivedAt != nil ? .revive : .markReachable
        }

        // Unreachable from here down.
        guard enabled else { return .none }

        if let archivedAt {
            // Already hidden — only decision left is whether to forget it.
            let archivedFor = max(0, now.timeIntervalSince(archivedAt))
            return archivedFor > archiveRetention ? .hardDelete : .none
        }

        // Visible + unreachable: dormant until the window elapses.
        let ref = lastSeenReachable ?? addedAt
        let down = max(0, now.timeIntervalSince(ref))   // clamp clock skew
        return down >= dormantWindow ? .archive : .none
    }
}
