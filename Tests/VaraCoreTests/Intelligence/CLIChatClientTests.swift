import Foundation
import XCTest
@testable import VaraCore

final class CLIChatClientTests: XCTestCase {
    // MARK: argv construction

    func testClaudeArgvUsesPrintModeAndModel() {
        let invocation = CLIChatClient.invocation(for: .claude, model: "haiku", prompt: "PROMPT")
        XCTAssertEqual(invocation.arguments, ["-p", "PROMPT", "--model", "haiku"])
        XCTAssertFalse(invocation.needsTempCWD)
    }

    func testGeminiArgvPassesPromptAsArgumentNotStdin() {
        let invocation = CLIChatClient.invocation(for: .gemini, model: "gemini-2.5-flash", prompt: "PROMPT")
        XCTAssertEqual(invocation.arguments, ["-p", "PROMPT", "-m", "gemini-2.5-flash"])
        XCTAssertFalse(invocation.needsTempCWD)
    }

    func testCodexArgvForcesLowReasoningAndModelAndTempCWD() {
        let invocation = CLIChatClient.invocation(for: .codex, model: "gpt-5.5", prompt: "PROMPT")
        XCTAssertEqual(invocation.arguments, [
            "exec",
            "--skip-git-repo-check",
            "-c", "model_reasoning_effort=\"low\"",
            "-c", "model=\"gpt-5.5\"",
            "PROMPT",
        ])
        // codex resets the shell cwd, so it must be spawned in a temp dir.
        XCTAssertTrue(invocation.needsTempCWD)
    }

    // MARK: model defaulting

    func testEmptyModelFallsBackToToolDefault() {
        let client = CLIChatClient(tool: .claude, model: "", executableURL: nil)
        XCTAssertEqual(client.model, VaraCLITool.claude.defaultModel)
        XCTAssertEqual(client.id, "cli.claude")
    }

    // MARK: output mapping (against shell-script stub binaries)

    func testTrimsStdoutAndIgnoresStderr() async throws {
        let stub = try makeStubBinary(stdout: "  Cleaned text.  \n", stderr: "Loaded cached credentials\n", exit: 0)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
        let client = CLIChatClient(tool: .claude, model: "haiku", executableURL: stub)

        let text = try await client.complete(system: "SYS", user: "USER")
        XCTAssertEqual(text, "Cleaned text.")
    }

    func testNonZeroExitMapsToHTTPError() async throws {
        let stub = try makeStubBinary(stdout: "", stderr: "not logged in", exit: 7)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
        let client = CLIChatClient(tool: .codex, model: "gpt-5.5", executableURL: stub)

        do {
            _ = try await client.complete(system: "SYS", user: "USER")
            XCTFail("expected a non-zero exit to throw")
        } catch let error as ChatClientError {
            guard case .httpError(let status, let body) = error else {
                return XCTFail("expected httpError, got \(error)")
            }
            XCTAssertEqual(status, 7)
            XCTAssertEqual(body, "not logged in")
        }
    }

    func testEmptyStdoutMapsToEmptyCompletion() async throws {
        let stub = try makeStubBinary(stdout: "   \n", stderr: "", exit: 0)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
        let client = CLIChatClient(tool: .gemini, model: "gemini-2.5-flash", executableURL: stub)

        do {
            _ = try await client.complete(system: "SYS", user: "USER")
            XCTFail("expected empty stdout to throw")
        } catch let error as ChatClientError {
            guard case .emptyCompletion = error else {
                return XCTFail("expected emptyCompletion, got \(error)")
            }
        }
    }

    func testUnresolvableBinaryMapsToInvalidResponse() async {
        // nil executableURL simulates a binary that is not resolvable on PATH.
        let client = CLIChatClient(tool: .claude, model: "haiku", executableURL: nil)
        do {
            _ = try await client.complete(system: "SYS", user: "USER")
            XCTFail("expected a missing binary to throw")
        } catch let error as ChatClientError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        } catch {
            XCTFail("expected ChatClientError, got \(error)")
        }
    }

    // MARK: helpers

    /// Writes a tiny executable shell script that prints fixed stdout/stderr and
    /// exits with a fixed code, so output mapping is exercised without a real CLI.
    private func makeStubBinary(stdout: String, stderr: String, exit code: Int32) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vara-cli-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("stub")
        // printf %s keeps trailing characters exact; stderr/stdout written verbatim.
        let body = """
        #!/bin/sh
        printf '%s' \(shellQuote(stdout))
        printf '%s' \(shellQuote(stderr)) 1>&2
        exit \(code)
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
