import XCTest
@testable import ModelStatus

final class UpdateCheckerTests: XCTestCase {
    func testParseStripsVPrefix() {
        XCTAssertEqual(UpdateChecker.Version.parse("v0.1.0")?.numeric, [0, 1, 0])
        XCTAssertEqual(UpdateChecker.Version.parse("0.1.0")?.numeric, [0, 1, 0])
    }

    func testParsePreservesPreRelease() {
        XCTAssertEqual(UpdateChecker.Version.parse("v0.1.0-beta")?.preRelease, "beta")
        XCTAssertEqual(UpdateChecker.Version.parse("v1.2.3-rc.1")?.preRelease, "rc.1")
        XCTAssertNil(UpdateChecker.Version.parse("v1.0.0")?.preRelease)
    }

    func testParseRejectsNonNumeric() {
        XCTAssertNil(UpdateChecker.Version.parse("v0.x.0"))
        XCTAssertNil(UpdateChecker.Version.parse("not-a-version"))
    }

    func testIsNewerNumeric() {
        let a = UpdateChecker.Version.parse("v0.2.0")!
        let b = UpdateChecker.Version.parse("v0.1.0")!
        XCTAssertTrue(a.isNewer(than: b))
        XCTAssertFalse(b.isNewer(than: a))
    }

    func testIsNewerEqualNumeric() {
        let a = UpdateChecker.Version.parse("v0.1.0")!
        let b = UpdateChecker.Version.parse("v0.1.0")!
        XCTAssertFalse(a.isNewer(than: b))
        XCTAssertFalse(b.isNewer(than: a))
    }

    /// Semver rule: release > matching pre-release.
    func testReleaseIsNewerThanPreRelease() {
        let release = UpdateChecker.Version.parse("v0.2.0")!
        let beta = UpdateChecker.Version.parse("v0.2.0-beta")!
        XCTAssertTrue(release.isNewer(than: beta))
        XCTAssertFalse(beta.isNewer(than: release))
    }

    /// A v0.1.0-beta user should see v0.1.0 stable as an update.
    func testCurrentBetaSeesStableRelease() {
        let current = UpdateChecker.Version.parse("v0.1.0-beta")!
        let latest = UpdateChecker.Version.parse("v0.1.0")!
        XCTAssertTrue(latest.isNewer(than: current))
    }

    func testDifferentLengths() {
        let a = UpdateChecker.Version.parse("v1")!
        let b = UpdateChecker.Version.parse("v0.99.99")!
        XCTAssertTrue(a.isNewer(than: b))
    }
}
