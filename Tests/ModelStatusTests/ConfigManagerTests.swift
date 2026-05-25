import XCTest
@testable import OllamaStatus

final class ConfigManagerTests: XCTestCase {
    func testAppConfigRoundtrip() throws {
        let cfg = AppConfig(
            instances: [
                OllamaInstance(name: "Local", url: "http://127.0.0.1:11434"),
                OllamaInstance(name: "Remote", url: "https://ollama.example.com")
            ],
            pollInterval: 3.5,
            showURLs: false,
            notifyOnStateChange: true
        )

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(decoded.instances.count, 2)
        XCTAssertEqual(decoded.instances[0].name, "Local")
        XCTAssertEqual(decoded.instances[1].url, "https://ollama.example.com")
        XCTAssertEqual(decoded.pollInterval, 3.5)
        XCTAssertEqual(decoded.showURLs, false)
        XCTAssertEqual(decoded.notifyOnStateChange, true)
    }

    func testDecodesLegacyConfigWithoutNotifyFlag() throws {
        let legacy = """
        {
          "instances": [{"id":"00000000-0000-0000-0000-000000000001","name":"Local","url":"http://127.0.0.1:11434"}],
          "pollInterval": 2.0,
          "showURLs": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacy)
        XCTAssertEqual(decoded.notifyOnStateChange, false, "missing key must default to false")
        XCTAssertEqual(decoded.instances.count, 1)
    }

    func testDefaultIsLocalhostOnly() {
        let d = AppConfig.default
        XCTAssertEqual(d.instances.count, 1)
        XCTAssertEqual(d.instances[0].url, "http://127.0.0.1:11434")
    }

    func testOllamaInstanceCodableRejectsExtraFields() throws {
        // Legacy authHeader field should be ignored on decode (Keychain-only now).
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"x","url":"http://127.0.0.1:11434","authHeader":"Bearer xxx"}
        """.data(using: .utf8)!
        let inst = try JSONDecoder().decode(OllamaInstance.self, from: json)
        XCTAssertEqual(inst.name, "x")
    }
}
