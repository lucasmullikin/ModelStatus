import XCTest
@testable import ModelStatus

final class MLXProviderTests: XCTestCase {

    // Tests for MLXProvider's public helpers + the sandbox HTTP-fallback
    // contract. The full check()/probe() async paths require a mock URLSession
    // which isn't wired into the test harness yet; these focus on the pure
    // helpers that DO determine the sandbox-fallback decision points.

    // Test C2 from tdd-guide v1.0 gate (partial): localPortNormalizedURL
    // is the gate that decides which port the local-process inspection
    // checks. The architect-D50 fix prevented `https://localhost` from
    // being rewritten to `https://localhost:8080`.

    func testLocalPortNormalized_HTTPLocalhost_GetsDefaultPort() {
        let result = MLXProvider.localPortNormalizedURL("http://localhost")
        XCTAssertEqual(result, "http://localhost:8080",
                       "HTTP local URL without port should get MLX default :8080")
    }

    func testLocalPortNormalized_HTTPSLocalhost_PreservesImpliedPort() {
        // The architect-D50-hard fix: HTTPS local URLs must NOT be rewritten
        // to :8080 (HTTPS implies :443). Without this, the probe would
        // target :443 while process verification looked at :8080.
        let result = MLXProvider.localPortNormalizedURL("https://localhost")
        XCTAssertEqual(result, "https://localhost",
                       "HTTPS local URL must NOT get :8080 — HTTPS implies :443")
    }

    func testLocalPortNormalized_ExplicitPort_LeftUnchanged() {
        XCTAssertEqual(MLXProvider.localPortNormalizedURL("http://localhost:1234"),
                       "http://localhost:1234")
    }

    func testLocalPortNormalized_RemoteURL_LeftUnchanged() {
        // Non-loopback URLs are never rewritten.
        XCTAssertEqual(MLXProvider.localPortNormalizedURL("http://example.com"),
                       "http://example.com")
    }

    // argvLooksLikeMLX is the sandbox-fallback's primary signal when
    // localProcessInfo IS populated (direct download builds).

    func testArgvLooksLikeMLX_StandardServer() {
        XCTAssertTrue(MLXProvider.argvLooksLikeMLX(
            "/usr/bin/python -m mlx_lm.server --model mlx-community/Qwen2.5-3B-Instruct-4bit"))
    }

    func testArgvLooksLikeMLX_OmniServer() {
        XCTAssertTrue(MLXProvider.argvLooksLikeMLX(
            "/Users/me/.venv/bin/mlx-omni-server --port 10240"))
    }

    func testArgvLooksLikeMLX_NotMLX_Rejected() {
        // A llama.cpp or vLLM process should NOT match.
        XCTAssertFalse(MLXProvider.argvLooksLikeMLX(
            "/usr/local/bin/llama-server --model gguf/foo.gguf"))
        XCTAssertFalse(MLXProvider.argvLooksLikeMLX(
            "python -m vllm.entrypoints.openai.api_server"))
    }

    // extractModelArg pulls the --model value from argv (used for the
    // loaded-model name display in check()).

    func testExtractModelArg_SpaceSeparated() {
        let argv = ["python", "-m", "mlx_lm.server", "--model", "mlx-community/Foo-4bit"]
        XCTAssertEqual(MLXProvider.extractModelArg(from: argv),
                       "mlx-community/Foo-4bit")
    }

    func testExtractModelArg_EqualsForm() {
        let argv = ["mlx_lm.server", "--model=mlx-community/Bar-4bit"]
        XCTAssertEqual(MLXProvider.extractModelArg(from: argv),
                       "mlx-community/Bar-4bit")
    }

    func testExtractModelArg_NoModel_ReturnsNil() {
        let argv = ["mlx_lm.server", "--port", "8080"]
        XCTAssertNil(MLXProvider.extractModelArg(from: argv))
    }

    // idLooksLikeMLX is the OPEN-AI-shaped response gate (used when local
    // process info isn't available, including under sandbox).

    func testIdLooksLikeMLX_MLXCommunityNamespace() {
        let entry = MLXModelsResponse.Entry(id: "mlx-community/Qwen2.5-3B-4bit",
                                             owned_by: nil)
        XCTAssertTrue(MLXProvider.idLooksLikeMLX(entry))
    }

    func testIdLooksLikeMLX_MLXOmniOwnership() {
        let entry = MLXModelsResponse.Entry(id: "some-model-id", owned_by: "mlx-omni")
        XCTAssertTrue(MLXProvider.idLooksLikeMLX(entry))
    }

    func testIdLooksLikeMLX_GenericOpenAIModel_Rejected() {
        // Non-MLX OpenAI-compat servers shouldn't be misclassified
        // as MLX under the sandbox HTTP-fallback path.
        let entry = MLXModelsResponse.Entry(id: "gpt-4o", owned_by: "openai")
        XCTAssertFalse(MLXProvider.idLooksLikeMLX(entry))
    }
}
