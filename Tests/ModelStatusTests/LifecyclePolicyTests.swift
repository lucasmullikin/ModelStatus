import XCTest
@testable import ModelStatus

/// LifecyclePolicy.classify is a pure function over time + reachability, so the
/// full transition truth table is testable without Monitor, network, or disk.
final class LifecyclePolicyTests: XCTestCase {

    private let h = 3600.0
    private func date(_ secsAgo: Double, from now: Date) -> Date { now.addingTimeInterval(-secsAgo) }

    // MARK: reachable

    func testReachableVisibleStaysVisible() {
        let now = Date()
        let t = LifecyclePolicy.classify(now: now, addedAt: date(10*h, from: now),
                                         lastSeenReachable: date(2*h, from: now),
                                         archivedAt: nil, reachable: true, enabled: true)
        XCTAssertEqual(t, .markReachable)
    }

    func testReachableArchivedRevives() {
        let now = Date()
        let t = LifecyclePolicy.classify(now: now, addedAt: date(100*h, from: now),
                                         lastSeenReachable: date(50*h, from: now),
                                         archivedAt: date(40*h, from: now), reachable: true, enabled: true)
        XCTAssertEqual(t, .revive)
    }

    // MARK: dormant window

    func testUnreachableJustUnderDormantWindowStaysDormant() {
        let now = Date()
        let t = LifecyclePolicy.classify(now: now, addedAt: date(48*h, from: now),
                                         lastSeenReachable: date(23.9*h, from: now),
                                         archivedAt: nil, reachable: false, enabled: true)
        XCTAssertEqual(t, .none, "23.9h unreachable must remain dormant, not archive")
    }

    func testUnreachableOverDormantWindowArchives() {
        let now = Date()
        let t = LifecyclePolicy.classify(now: now, addedAt: date(48*h, from: now),
                                         lastSeenReachable: date(24.1*h, from: now),
                                         archivedAt: nil, reachable: false, enabled: true)
        XCTAssertEqual(t, .archive)
    }

    // MARK: archived retention

    func testArchivedUnreachableUnderRetentionStays() {
        let now = Date()
        let t = LifecyclePolicy.classify(now: now, addedAt: date(1000*h, from: now),
                                         lastSeenReachable: date(900*h, from: now),
                                         archivedAt: date(29*24*h, from: now), reachable: false, enabled: true)
        XCTAssertEqual(t, .none, "29 days archived is still under the 30d retention")
    }

    func testArchivedUnreachableOverRetentionHardDeletes() {
        let now = Date()
        let t = LifecyclePolicy.classify(now: now, addedAt: date(2000*h, from: now),
                                         lastSeenReachable: date(1900*h, from: now),
                                         archivedAt: date(31*24*h, from: now), reachable: false, enabled: true)
        XCTAssertEqual(t, .hardDelete)
    }

    // MARK: never-reachable ghost

    func testNeverReachableGhostArchivesFromAddedAt() {
        let now = Date()
        // Added 25h ago, never reached → dormant clock runs from addedAt.
        let t = LifecyclePolicy.classify(now: now, addedAt: date(25*h, from: now),
                                         lastSeenReachable: nil,
                                         archivedAt: nil, reachable: false, enabled: true)
        XCTAssertEqual(t, .archive)
    }

    func testFreshlyAddedUnreachableStaysDormant() {
        let now = Date()
        let t = LifecyclePolicy.classify(now: now, addedAt: date(1*h, from: now),
                                         lastSeenReachable: nil,
                                         archivedAt: nil, reachable: false, enabled: true)
        XCTAssertEqual(t, .none)
    }

    // MARK: clock skew

    func testClockSkewRefInFutureNeverArchives() {
        let now = Date()
        // lastSeenReachable in the FUTURE (clock moved back) → negative downtime.
        let t = LifecyclePolicy.classify(now: now, addedAt: date(100*h, from: now),
                                         lastSeenReachable: now.addingTimeInterval(5*h),
                                         archivedAt: nil, reachable: false, enabled: true)
        XCTAssertEqual(t, .none, "negative downtime from clock skew must never archive")
    }

    // MARK: toggle off

    func testDisabledAlwaysNoneEvenWhenWouldArchive() {
        let now = Date()
        let t = LifecyclePolicy.classify(now: now, addedAt: date(48*h, from: now),
                                         lastSeenReachable: date(40*h, from: now),
                                         archivedAt: nil, reachable: false, enabled: false)
        XCTAssertEqual(t, .none)
    }

    func testDisabledStillMarksReachable() {
        // Even with auto-manage off, a reachable poll should refresh lastSeen
        // so re-enabling later has accurate data.
        let now = Date()
        let t = LifecyclePolicy.classify(now: now, addedAt: date(48*h, from: now),
                                         lastSeenReachable: date(40*h, from: now),
                                         archivedAt: nil, reachable: true, enabled: false)
        XCTAssertEqual(t, .markReachable)
    }
}
