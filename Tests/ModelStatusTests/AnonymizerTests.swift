import XCTest
@testable import ModelStatus

final class AnonymizerTests: XCTestCase {

    // Test C3 from tdd-guide v1.0 gate: parseAuthority unbracketed IPv6
    // colon-count guard. Regression test for `fe80::1` being mis-parsed as
    // host="fe80:" port=":1" in pre-v0.2.1 code.

    func testParseAuthority_UnbracketedIPv6_NotMisParsedAsHostPort() {
        let p = Anonymizer.parseAuthority("fe80::1")
        XCTAssertEqual(p.host, "fe80::1",
                       "Unbracketed IPv6 must be preserved as host, not split on colon")
        XCTAssertNil(p.port,
                     "Unbracketed IPv6 has no separate port — entire literal is host")
        XCTAssertFalse(p.bracketedIPv6,
                       "Unbracketed IPv6 must report bracketedIPv6=false (caller can re-bracket on render)")
        XCTAssertFalse(p.credentialsPresent)
    }

    func testParseAuthority_UnbracketedIPv6WithZone_AlsoPreserved() {
        // IPv6 zone identifiers like `fe80::1%en0` are valid; the % suffix
        // shouldn't confuse the colon-count guard.
        let p = Anonymizer.parseAuthority("fe80::1%en0")
        XCTAssertEqual(p.host, "fe80::1%en0")
        XCTAssertNil(p.port)
    }

    func testParseAuthority_BracketedIPv6WithPort_SplitCorrectly() {
        let p = Anonymizer.parseAuthority("[fd00::1]:11434")
        XCTAssertEqual(p.host, "fd00::1",
                       "Bracketed IPv6 host returned WITHOUT brackets (renderer re-brackets)")
        XCTAssertEqual(p.port, ":11434",
                       "Port includes leading colon")
        XCTAssertTrue(p.bracketedIPv6)
    }

    func testParseAuthority_BracketedIPv6JunkTail_PortTreatedAsNil() {
        // [fd00::1]secret — junk after `]` is not a valid `:<digits>` port.
        // Should NOT preserve "secret" as if it were a port.
        let p = Anonymizer.parseAuthority("[fd00::1]secret")
        XCTAssertEqual(p.host, "fd00::1")
        XCTAssertTrue(p.bracketedIPv6)
        XCTAssertNil(p.port,
                     "Tail 'secret' is not :<digits>; must be dropped not preserved as port")
    }

    func testParseAuthority_RegularHostPort_StillWorks() {
        let p = Anonymizer.parseAuthority("example.local:11434")
        XCTAssertEqual(p.host, "example.local")
        XCTAssertEqual(p.port, ":11434")
        XCTAssertFalse(p.bracketedIPv6)
    }

    func testParseAuthority_CredentialsStrippedAndRecorded() {
        let p = Anonymizer.parseAuthority("user:pass@host.local:8080")
        XCTAssertTrue(p.credentialsPresent)
        XCTAssertEqual(p.host, "host.local")
        XCTAssertEqual(p.port, ":8080")
    }

    // scrubURL invariants

    func testScrubURL_IdempotentOnAlreadyHashedHost() {
        // Already-scrubbed URLs should not be re-hashed (idempotency).
        let once = Anonymizer.scrubURL("http://example.local/api/tags")
        let twice = Anonymizer.scrubURL(once)
        XCTAssertEqual(once, twice, "scrubURL must be idempotent")
    }

    func testScrubURL_StripsCredentialsFromMalformedURL() {
        // The architect-v1final fix: credentials in URLs must never survive
        // through to ANY downstream consumer including .notice logs.
        let scrubbed = Anonymizer.scrubURL("http://admin:s3cret@host.local:8080/api")
        XCTAssertFalse(scrubbed.contains("admin"),
                       "Username must not survive scrubURL output")
        XCTAssertFalse(scrubbed.contains("s3cret"),
                       "Password must not survive scrubURL output")
    }
}
