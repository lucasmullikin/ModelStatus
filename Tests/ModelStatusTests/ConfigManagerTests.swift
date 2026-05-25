import XCTest
@testable import ModelStatus

final class ConfigManagerTests: XCTestCase {
    func testAppConfigRoundtrip() throws {
        let cfg = AppConfig(
            instances: [
                Instance(name: "Local", url: "http://127.0.0.1:11434", kind: .ollama),
                Instance(name: "vLLM box", url: "http://192.168.1.99:8000", kind: .vllm)
            ],
            pollInterval: 5.0,
            notifyOnStateChange: true,
            compactMode: true
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded.instances.count, 2)
        XCTAssertEqual(decoded.instances[1].kind, .vllm)
        XCTAssertEqual(decoded.pollInterval, 5.0)
        XCTAssertTrue(decoded.notifyOnStateChange)
        XCTAssertTrue(decoded.compactMode)
    }

    func testLegacyDecode_OllamaStatusEra() throws {
        let legacy = """
        {
          "instances": [{"id":"00000000-0000-0000-0000-000000000001","name":"Local","url":"http://127.0.0.1:11434"}],
          "pollInterval": 2.0,
          "showURLs": true
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacy)
        XCTAssertEqual(decoded.instances.count, 1)
        XCTAssertEqual(decoded.instances[0].kind, .ollama)
        XCTAssertFalse(decoded.notifyOnStateChange)
        XCTAssertFalse(decoded.compactMode)
    }

    func testDefaultIsLocalhostOllama() {
        let d = AppConfig.default
        XCTAssertEqual(d.instances.count, 1)
        XCTAssertEqual(d.instances[0].url, "http://127.0.0.1:11434")
        XCTAssertEqual(d.instances[0].kind, .ollama)
        XCTAssertEqual(d.pollInterval, 5.0)
    }

    func testPollIntervalClosest() {
        XCTAssertEqual(PollInterval.closest(to: 2.5), .fast)
        XCTAssertEqual(PollInterval.closest(to: 4.0), .normal)
        XCTAssertEqual(PollInterval.closest(to: 9.0), .slow)
        XCTAssertEqual(PollInterval.closest(to: 150), .sleepy)
    }
}
