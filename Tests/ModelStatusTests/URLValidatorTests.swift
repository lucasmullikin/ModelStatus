import XCTest
@testable import ModelStatus

final class URLValidatorTests: XCTestCase {
    func testValidHTTPURL() {
        switch URLValidator.validate("http://127.0.0.1:11434") {
        case .success(let s): XCTAssertEqual(s, "http://127.0.0.1:11434")
        case .failure: XCTFail("expected success")
        }
    }

    func testValidHTTPSURL() {
        switch URLValidator.validate("https://ollama.example.com") {
        case .success(let s): XCTAssertEqual(s, "https://ollama.example.com")
        case .failure: XCTFail("expected success")
        }
    }

    func testAutoPrependsHTTP() {
        switch URLValidator.validate("192.168.1.50:11434") {
        case .success(let s): XCTAssertEqual(s, "http://192.168.1.50:11434")
        case .failure: XCTFail("expected success — http should be auto-prepended")
        }
    }

    func testRejectsFileScheme() {
        if case .success = URLValidator.validate("file:///etc/passwd") {
            XCTFail("file:// must be rejected")
        }
    }

    func testRejectsAWSMetadata() {
        if case .success = URLValidator.validate("http://169.254.169.254/latest/meta-data/") {
            XCTFail("AWS metadata endpoint must be rejected")
        }
    }

    func testRejectsGCPMetadata() {
        if case .success = URLValidator.validate("http://metadata.google.internal/") {
            XCTFail("GCP metadata endpoint must be rejected")
        }
    }

    func testRejectsGCPMetadataTrailingDot() {
        if case .success = URLValidator.validate("http://metadata.google.internal./") {
            XCTFail("metadata host with trailing dot must be rejected")
        }
    }

    func testRejectsGCPMetadataShortcut() {
        if case .success = URLValidator.validate("http://metadata/computeMetadata/v1/") {
            XCTFail("'metadata' short host must be rejected")
        }
    }

    func testRejectsMailtoScheme() {
        if case .success = URLValidator.validate("mailto:foo@example.com") {
            XCTFail("mailto: must be rejected")
        }
    }

    func testRejectsJavascriptScheme() {
        if case .success = URLValidator.validate("javascript:alert(1)") {
            XCTFail("javascript: must be rejected")
        }
    }

    func testRejectsFTPScheme() {
        if case .success = URLValidator.validate("ftp://example.com/") {
            XCTFail("ftp:// must be rejected")
        }
    }

    func testRejectsEmpty() {
        if case .success = URLValidator.validate("") {
            XCTFail("empty string must be rejected")
        }
    }

    func testTrimsWhitespace() {
        switch URLValidator.validate("   http://localhost:11434   ") {
        case .success(let s): XCTAssertEqual(s, "http://localhost:11434")
        case .failure: XCTFail("whitespace should be trimmed")
        }
    }

    // MARK: - Host:port shorthand (audit-round-D2)

    /// `localhost:11434` is the most common user-typed Ollama endpoint. It must
    /// be treated as host:port shorthand, NOT as scheme `localhost:`.
    func testAcceptsLocalhostPortShorthand() {
        switch URLValidator.validate("localhost:11434") {
        case .success(let s): XCTAssertEqual(s, "http://localhost:11434")
        case .failure: XCTFail("localhost:port must be accepted as host:port shorthand")
        }
    }

    /// Hostname-with-port shorthand (`my-server:8000`) for self-hosted endpoints.
    func testAcceptsHostnamePortShorthand() {
        switch URLValidator.validate("my-server:8000") {
        case .success(let s): XCTAssertEqual(s, "http://my-server:8000")
        case .failure: XCTFail("hostname:port must be accepted as host:port shorthand")
        }
    }

    // MARK: - IPv4 metadata canonicalization (audit-round-D2)

    /// The AWS/Azure IMDS address as a single 32-bit decimal: 169<<24 | 254<<16 | 169<<8 | 254
    func testRejectsAWSMetadataDecimalNumeric() {
        if case .success = URLValidator.validate("http://2852039166/") {
            XCTFail("decimal-numeric form of 169.254.169.254 must be rejected")
        }
    }

    func testRejectsAWSMetadataHexPerOctet() {
        if case .success = URLValidator.validate("http://0xa9.0xfe.0xa9.0xfe/") {
            XCTFail("hex-per-octet form of 169.254.169.254 must be rejected")
        }
    }

    func testRejectsAWSMetadataOctalPerOctet() {
        if case .success = URLValidator.validate("http://0251.0376.0251.0376/") {
            XCTFail("octal-per-octet form of 169.254.169.254 must be rejected")
        }
    }

    /// IPv6 compressed equivalent of the AWS metadata address.
    func testRejectsAWSMetadataIPv6Compressed() {
        if case .success = URLValidator.validate("http://[fd00:ec2:0:0:0:0:0:254]/") {
            XCTFail("uncompressed IPv6 form of fd00:ec2::254 must be rejected")
        }
    }
}
