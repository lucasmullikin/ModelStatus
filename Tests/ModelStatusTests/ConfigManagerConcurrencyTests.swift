import XCTest
@testable import ModelStatus

/// Stress test for the @MainActor isolation introduced in v0.2 step B.
///
/// Under the pre-B `final class ConfigManager` + global access, this test would
/// race on `_config` mutation from concurrent contexts. Post-B, every access is
/// serialized through MainActor and TSAN should report clean.
///
/// Run with: `swift test --sanitize=thread`
@MainActor
final class ConfigManagerConcurrencyTests: XCTestCase {

    func testConcurrentReadsDoNotRace() async throws {
        // 100 concurrent reads from non-isolated tasks. Each MUST hop back to
        // MainActor — that's the protocol enforced by the @MainActor annotation.
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let count = await MainActor.run { ConfigManager.shared.instances.count }
                    return count
                }
            }
            var sum = 0
            for await c in group { sum += c }
            XCTAssertGreaterThan(sum, 0, "100 reads of a non-empty config should sum > 0")
        }
    }

    func testInterleavedReadsAndWritesAreSerialized() async throws {
        let starting = ConfigManager.shared.instances
        defer { ConfigManager.shared.instances = starting }

        let baseline = ConfigManager.shared.instances.count
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await MainActor.run {
                        var current = ConfigManager.shared.instances
                        current.append(Instance(
                            name: "stress-\(i)",
                            url: "http://127.0.0.1:\(11500 + i)",
                            kind: .ollama
                        ))
                        ConfigManager.shared.instances = current
                    }
                }
            }
        }
        let after = ConfigManager.shared.instances.count
        XCTAssertEqual(after, baseline + 100,
                       "Every write must be observed; lost updates indicate a race.")
    }

    func testActorBoundaryRead() async throws {
        // Simulate Monitor's call pattern: an actor reads ConfigManager
        // via MainActor.run. Ensures Sendable contract holds — Instance is
        // already Sendable, so the array crosses the boundary cleanly.
        actor Stub {
            func snapshot() async -> [Instance] {
                await MainActor.run { ConfigManager.shared.instances }
            }
        }
        let stub = Stub()
        let snap = await stub.snapshot()
        XCTAssertGreaterThanOrEqual(snap.count, 1)
    }

    func testSnapshotForPollCapturesAllFields() async throws {
        // Read snapshot + ground-truth values in a single MainActor hop so the
        // two reads can't drift between contexts.
        let (ctx, pi, vb, ic) = await MainActor.run {
            (
                ConfigManager.shared.snapshotForPoll(),
                ConfigManager.shared.pollInterval,
                ConfigManager.shared.verboseLogging,
                ConfigManager.shared.instances.count
            )
        }
        XCTAssertEqual(ctx.pollInterval, pi)
        XCTAssertEqual(ctx.verbose, vb)
        XCTAssertEqual(ctx.instances.count, ic)
        // timestamp is "now-ish" — within last second
        XCTAssertLessThan(Date().timeIntervalSince(ctx.timestamp), 1.0)
    }
}
