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

    // MARK: - v1.0.1 lifecycle fields

    func testLifecycleFieldsRoundtrip() throws {
        let added = Date(timeIntervalSince1970: 1_700_000_000)
        let seen = Date(timeIntervalSince1970: 1_700_001_000)
        let archived = Date(timeIntervalSince1970: 1_700_002_000)
        let inst = Instance(name: "X", url: "http://h:1", kind: .ollama,
                            addedAt: added, lastSeenReachable: seen, archivedAt: archived)
        let decoded = try JSONDecoder().decode(Instance.self, from: JSONEncoder().encode(inst))
        XCTAssertEqual(decoded.addedAt, added)
        XCTAssertEqual(decoded.lastSeenReachable, seen)
        XCTAssertEqual(decoded.archivedAt, archived)
        XCTAssertFalse(decoded.isVisible)
    }

    func testLegacyInstanceWithoutLifecycleFieldsDecodes() throws {
        // Pre-v1.0.1 config has no addedAt/lastSeenReachable/archivedAt.
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000009","name":"Old","url":"http://127.0.0.1:11434","kind":"ollama"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Instance.self, from: legacy)
        XCTAssertNil(decoded.lastSeenReachable)
        XCTAssertNil(decoded.archivedAt)
        XCTAssertTrue(decoded.isVisible, "legacy instance must default to visible")
        // addedAt backfilled to ~now so it isn't instantly archived.
        XCTAssertLessThan(abs(decoded.addedAt.timeIntervalSinceNow), 5)
    }

    func testAutoManageDormantDefaultsTrueAndRoundtrips() throws {
        XCTAssertTrue(AppConfig.default.autoManageDormant)
        // Legacy config without the key defaults to true.
        let legacy = """
        {"instances":[{"id":"00000000-0000-0000-0000-000000000001","name":"L","url":"http://127.0.0.1:11434"}],"pollInterval":5.0}
        """.data(using: .utf8)!
        XCTAssertTrue(try JSONDecoder().decode(AppConfig.self, from: legacy).autoManageDormant)
    }
}
