import XCTest
@testable import ModelStatus

/// CLI rendering is a pure function over `[ServerStatus]` so it's testable
/// without spinning up Monitor or hitting the network. The headless poll path
/// (`StatusCLI.run`) reuses the real Monitor and is exercised manually /
/// in integration, not here.
final class StatusCLITests: XCTestCase {

    private func makeStatus(
        name: String = "Local",
        url: String = "http://127.0.0.1:11434",
        kind: ProviderKind = .ollama,
        state: ServerState = .idle,
        models: [LoadedModel] = [],
        available: Int = 0,
        vram: Int64 = 0,
        cpu: Double? = nil,
        mem: Int? = nil,
        latency: Int? = nil
    ) -> ServerStatus {
        ServerStatus(instance: Instance(name: name, url: url, kind: kind),
                     detectedKind: kind, state: state,
                     loadedModels: models, availableModelCount: available, vramTotal: vram,
                     lastActive: nil, cpuPercent: cpu, memoryMB: mem,
                     clientProcess: nil, latencyMs: latency)
    }

    // MARK: - state labels

    func testStateLabelsAreStableMachineStrings() {
        XCTAssertEqual(StatusCLI.stateLabel(.generating), "generating")
        XCTAssertEqual(StatusCLI.stateLabel(.active), "active")
        XCTAssertEqual(StatusCLI.stateLabel(.idle), "idle")
        XCTAssertEqual(StatusCLI.stateLabel(.unreachable), "unreachable")
    }

    // MARK: - text rendering

    func testRenderTextOneLinePerInstance() {
        let out = StatusCLI.renderText([
            makeStatus(name: "Local", state: .idle),
            makeStatus(name: "M4 Pro", url: "http://192.168.1.42:11434", state: .unreachable)
        ])
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(out.contains("Local"))
        XCTAssertTrue(out.contains("idle"))
        XCTAssertTrue(out.contains("M4 Pro"))
        XCTAssertTrue(out.contains("unreachable"))
    }

    func testRenderTextShowsLoadedModelAndVRAM() {
        let model = LoadedModel(name: "llama3.2:8b", vramBytes: 8_589_934_592, expiresAt: nil)
        let out = StatusCLI.renderText([
            makeStatus(name: "M4 Pro", state: .active, models: [model], available: 5, vram: 8_589_934_592)
        ])
        XCTAssertTrue(out.contains("llama3.2:8b"))
        XCTAssertTrue(out.contains("8.0 GB"))
    }

    func testRenderTextEmptyIsFriendly() {
        let out = StatusCLI.renderText([])
        XCTAssertTrue(out.lowercased().contains("no servers"))
    }

    // MARK: - JSON rendering

    func testRenderJSONIsValidArrayWithExpectedKeys() throws {
        let model = LoadedModel(name: "qwen2.5:7b", vramBytes: 4_000_000_000, expiresAt: nil)
        let json = StatusCLI.renderJSON([
            makeStatus(name: "Local", kind: .ollama, state: .generating,
                       models: [model], available: 3, vram: 4_000_000_000,
                       cpu: 42.5, mem: 1024, latency: 12)
        ])
        let data = json.data(using: .utf8)!
        let arr = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertEqual(arr.count, 1)
        let row = arr[0]
        XCTAssertEqual(row["name"] as? String, "Local")
        XCTAssertEqual(row["url"] as? String, "http://127.0.0.1:11434")
        XCTAssertEqual(row["detectedKind"] as? String, "ollama")
        XCTAssertEqual(row["state"] as? String, "generating")
        XCTAssertEqual(row["availableModelCount"] as? Int, 3)
        XCTAssertEqual(row["cpuPercent"] as? Double, 42.5)
        XCTAssertEqual(row["memoryMB"] as? Int, 1024)
        XCTAssertEqual(row["latencyMs"] as? Int, 12)
        let models = row["loadedModels"] as! [[String: Any]]
        XCTAssertEqual(models.first?["name"] as? String, "qwen2.5:7b")
        XCTAssertEqual(models.first?["vramBytes"] as? Int64, 4_000_000_000)
    }

    func testRenderJSONNonNilExpiresAtSurvivesEncoding() throws {
        // Guards the Optional/NSNull bridging: a non-nil expiresAt must not
        // make JSONSerialization bail to "[]".
        let model = LoadedModel(name: "m", vramBytes: 1, expiresAt: "2026-01-01T00:00:00Z")
        let json = StatusCLI.renderJSON([makeStatus(state: .active, models: [model])])
        let arr = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [[String: Any]]
        XCTAssertEqual(arr.count, 1, "non-nil expiresAt must not collapse the array")
        let m = (arr[0]["loadedModels"] as! [[String: Any]]).first!
        XCTAssertEqual(m["expiresAt"] as? String, "2026-01-01T00:00:00Z")
    }

    func testRenderJSONAllNilOptionalsBecomeNull() throws {
        let json = StatusCLI.renderJSON([makeStatus(state: .idle)])
        let row = try (JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [[String: Any]])[0]
        XCTAssertTrue(row["cpuPercent"] is NSNull)
        XCTAssertTrue(row["memoryMB"] is NSNull)
        XCTAssertTrue(row["clientProcess"] is NSNull)
        XCTAssertTrue(row["latencyMs"] is NSNull)
    }

    func testRenderJSONNonFiniteCPUBecomesNullNotCollapse() throws {
        // A NaN cpuPercent must not make JSONSerialization throw and collapse
        // the whole output — it should render as null with rows intact.
        let json = StatusCLI.renderJSON([makeStatus(state: .active, cpu: Double.nan)])
        let arr = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [[String: Any]]
        XCTAssertEqual(arr.count, 1)
        XCTAssertTrue(arr[0]["cpuPercent"] is NSNull)
    }

    func testRenderJSONInfiniteCPUBecomesNull() throws {
        let json = StatusCLI.renderJSON([makeStatus(state: .active, cpu: Double.infinity)])
        let arr = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [[String: Any]]
        XCTAssertTrue(arr[0]["cpuPercent"] is NSNull)
    }

    func testRenderJSONEmptyIsEmptyArray() throws {
        let json = StatusCLI.renderJSON([])
        let arr = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [[String: Any]]
        XCTAssertEqual(arr.count, 0)
    }

    func testRenderJSONOmitsNilNumericsAsNull() throws {
        let json = StatusCLI.renderJSON([makeStatus(state: .idle)])
        // cpu/mem/latency are nil → encoded as JSON null, key present.
        let arr = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [[String: Any]]
        XCTAssertTrue(arr[0]["cpuPercent"] is NSNull)
    }

    // MARK: - argument parsing

    func testParseArgsStatusPlain() {
        let cmd = StatusCLI.parse(["ModelStatus", "status"])
        XCTAssertEqual(cmd, .status(json: false))
    }

    func testParseArgsStatusJSON() {
        XCTAssertEqual(StatusCLI.parse(["ModelStatus", "status", "--json"]), .status(json: true))
    }

    func testParseArgsHelp() {
        XCTAssertEqual(StatusCLI.parse(["ModelStatus", "--help"]), .help)
        XCTAssertEqual(StatusCLI.parse(["ModelStatus", "-h"]), .help)
    }

    func testParseArgsNoSubcommandLaunchesGUI() {
        XCTAssertEqual(StatusCLI.parse(["ModelStatus"]), .gui)
    }

    func testParseArgsUnknownLaunchesGUI() {
        // Unknown flags (e.g. macOS passing -NSDocumentRevisionsDebugMode) must
        // NOT hijack normal app launch.
        XCTAssertEqual(StatusCLI.parse(["ModelStatus", "-NSDocumentRevisionsDebugMode", "YES"]), .gui)
    }
}
