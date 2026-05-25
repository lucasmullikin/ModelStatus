import XCTest
@testable import ModelStatus

final class FormattersTests: XCTestCase {
    func testBytesGB() {
        XCTAssertEqual(Formatters.bytes(2_147_483_648), "2.0 GB")
    }

    func testBytesMB() {
        XCTAssertEqual(Formatters.bytes(524_288_000), "500 MB")
    }

    func testBytesZero() {
        XCTAssertEqual(Formatters.bytes(0), "")
    }

    func testElapsedSeconds() {
        let d = Date().addingTimeInterval(-30)
        XCTAssertEqual(Formatters.elapsed(since: d), "30s ago")
    }

    func testCompactLineIdle() {
        let inst = Instance(name: "Local", url: "http://127.0.0.1:11434")
        let status = ServerStatus(instance: inst, detectedKind: .ollama, state: .idle,
                                  loadedModels: [], availableModelCount: 0, vramTotal: 0,
                                  lastActive: nil, cpuPercent: nil, memoryMB: nil,
                                  clientIP: nil, latencyMs: nil)
        XCTAssertTrue(Formatters.compactLine(status: status).contains("idle"))
    }

    func testCompactLineActive() {
        let inst = Instance(name: "M4 Pro", url: "http://192.168.1.50:11434")
        let model = LoadedModel(name: "llama3.2:8b", vramBytes: 8_589_934_592, expiresAt: nil)
        let status = ServerStatus(instance: inst, detectedKind: .ollama, state: .active,
                                  loadedModels: [model], availableModelCount: 5, vramTotal: 8_589_934_592,
                                  lastActive: nil, cpuPercent: nil, memoryMB: nil,
                                  clientIP: nil, latencyMs: nil)
        let line = Formatters.compactLine(status: status)
        XCTAssertTrue(line.contains("M4 Pro"))
        XCTAssertTrue(line.contains("llama3.2:8b"))
        XCTAssertTrue(line.contains("8.0 GB"))
    }
}
