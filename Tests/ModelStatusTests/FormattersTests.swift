import XCTest
@testable import OllamaStatus

final class FormattersTests: XCTestCase {
    func testBytesGB() {
        XCTAssertEqual(Formatters.bytes(2_147_483_648), "2.0 GB")
    }

    func testBytesMB() {
        XCTAssertEqual(Formatters.bytes(524_288_000), "500 MB")
    }

    func testElapsedSeconds() {
        let d = Date().addingTimeInterval(-30)
        XCTAssertEqual(Formatters.elapsed(since: d), "30s ago")
    }

    func testElapsedMinutes() {
        let d = Date().addingTimeInterval(-150)
        let s = Formatters.elapsed(since: d)
        XCTAssertTrue(s.hasPrefix("2m "), "expected '2m …'; got '\(s)'")
        XCTAssertTrue(s.hasSuffix(" ago"))
    }

    func testElapsedHours() {
        let d = Date().addingTimeInterval(-3700)
        let s = Formatters.elapsed(since: d)
        XCTAssertTrue(s.hasPrefix("1h "), "expected '1h …'; got '\(s)'")
    }

    func testBarFull() {
        XCTAssertEqual(Formatters.bar(fraction: 1.0, width: 8), "████████")
    }

    func testBarEmpty() {
        XCTAssertEqual(Formatters.bar(fraction: 0.0, width: 8), "░░░░░░░░")
    }

    func testBarHalf() {
        XCTAssertEqual(Formatters.bar(fraction: 0.5, width: 8), "████░░░░")
    }

    func testBarClamps() {
        XCTAssertEqual(Formatters.bar(fraction: 2.0, width: 4), "████")
        XCTAssertEqual(Formatters.bar(fraction: -1.0, width: 4), "░░░░")
    }
}
