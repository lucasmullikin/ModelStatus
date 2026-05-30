import XCTest
@testable import ModelStatus

/// v1.0.1: Tests for `VLLMProvider.parseRequestsRunning(prometheusText:)`,
/// the new activity-detection parser that flips a vLLM instance from Active
/// to Generating when the engine is currently processing tokens.
final class VLLMProviderTests: XCTestCase {

    func testReturnsZeroOnEmpty() {
        XCTAssertEqual(VLLMProvider.parseRequestsRunning(prometheusText: ""), 0)
    }

    func testReturnsZeroWhenMetricMissing() {
        // Only the GPU memory metric present — our new parser must not
        // accidentally match it.
        let text = """
        # HELP vllm:gpu_memory_usage_bytes GPU memory usage in bytes
        # TYPE vllm:gpu_memory_usage_bytes gauge
        vllm:gpu_memory_usage_bytes 1.234e+10
        """
        XCTAssertEqual(VLLMProvider.parseRequestsRunning(prometheusText: text), 0)
    }

    func testParsesUnlabeledSample() {
        let text = """
        # HELP vllm:num_requests_running Number of requests currently being processed.
        # TYPE vllm:num_requests_running gauge
        vllm:num_requests_running 3.0
        """
        XCTAssertEqual(VLLMProvider.parseRequestsRunning(prometheusText: text), 3)
    }

    func testParsesIntegerValue() {
        // vLLM emits floats but the parser should handle plain ints too
        let text = "vllm:num_requests_running 7"
        XCTAssertEqual(VLLMProvider.parseRequestsRunning(prometheusText: text), 7)
    }

    func testZeroRequestsRunningStaysZero() {
        // The metric is present but value is 0 — server is up but resting
        let text = "vllm:num_requests_running 0"
        XCTAssertEqual(VLLMProvider.parseRequestsRunning(prometheusText: text), 0)
    }

    func testIgnoresCommentLines() {
        let text = """
        # HELP vllm:num_requests_running Number of requests in flight.
        # TYPE vllm:num_requests_running gauge
        # Some other comment with the metric name vllm:num_requests_running in it
        vllm:num_requests_running 4
        """
        XCTAssertEqual(VLLMProvider.parseRequestsRunning(prometheusText: text), 4)
    }

    func testSumsLabeledSamples() {
        // Hypothetical future per-model labeling — parser should sum
        let text = """
        vllm:num_requests_running{model="qwen-7b"} 2
        vllm:num_requests_running{model="llama-13b"} 3
        """
        XCTAssertEqual(VLLMProvider.parseRequestsRunning(prometheusText: text), 5)
    }

    func testDoesNotMatchSubstringPrefixCollisions() {
        // A future hypothetical metric whose name happens to start with our
        // prefix — must NOT be matched.
        let text = """
        vllm:num_requests_running_total 999
        vllm:num_requests_running 2
        """
        XCTAssertEqual(VLLMProvider.parseRequestsRunning(prometheusText: text), 2)
    }

    func testRejectsNegativeAndNaN() {
        let text = """
        vllm:num_requests_running -1
        vllm:num_requests_running NaN
        vllm:num_requests_running 5
        """
        // Only the 5 should count; the -1 and NaN are silently skipped
        XCTAssertEqual(VLLMProvider.parseRequestsRunning(prometheusText: text), 5)
    }

    func testCapsImplausiblyLargeValues() {
        // A corrupted metric line shouldn't cause an Int overflow or
        // a billion-request reading. Cap is 1_000_000 per sample.
        let text = "vllm:num_requests_running 1e15"
        XCTAssertEqual(VLLMProvider.parseRequestsRunning(prometheusText: text), 1_000_000)
    }

    func testHandlesTabsAndMultipleSpaces() {
        // Prometheus exposition uses a single space but be defensive
        let text = "vllm:num_requests_running\t\t7"
        XCTAssertEqual(VLLMProvider.parseRequestsRunning(prometheusText: text), 7)
    }

    func testRealisticVllmExposition() {
        // Approximation of a real /metrics dump — multiple metrics interleaved,
        // comments, labels.
        let text = """
        # HELP vllm:num_requests_running Number of requests currently in inference.
        # TYPE vllm:num_requests_running gauge
        vllm:num_requests_running{model="qwen2.5"} 2.0
        # HELP vllm:num_requests_waiting Number of requests waiting in queue.
        # TYPE vllm:num_requests_waiting gauge
        vllm:num_requests_waiting{model="qwen2.5"} 0.0
        # HELP vllm:gpu_memory_usage_bytes GPU memory used in bytes.
        # TYPE vllm:gpu_memory_usage_bytes gauge
        vllm:gpu_memory_usage_bytes{model="qwen2.5",gpu="0"} 1.7e+10
        # HELP vllm:request_success_total Total successful requests.
        # TYPE vllm:request_success_total counter
        vllm:request_success_total{model="qwen2.5"} 9821
        """
        // Only the running metric value should be parsed — must NOT pick up
        // the waiting metric (0), GPU memory (huge), or request total (also huge).
        XCTAssertEqual(VLLMProvider.parseRequestsRunning(prometheusText: text), 2)
    }
}
