import XCTest
@testable import OllamaStatus

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
}
