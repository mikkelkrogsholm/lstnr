import Foundation

/// The coding CLIs Vara can shell out to for transcript cleanup. Each runs on
/// the user's machine under their existing subscription — no API key. The
/// reasoning/thinking budget is fixed to "low" per invocation so a plain
/// cleanup stays fast and never edits the user's global CLI config.
public enum VaraCLITool: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case gemini

    /// The executable name resolved on the augmented PATH.
    public var binaryName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code (CLI)"
        case .codex: "Codex (CLI)"
        case .gemini: "Gemini CLI"
        }
    }

    /// A sensible fast default model per tool (haiku / a small codex model /
    /// a flash Gemini). The user can override it in the model field.
    public var defaultModel: String {
        switch self {
        case .claude: "haiku"
        case .codex: "gpt-5.5"
        case .gemini: "gemini-2.5-flash"
        }
    }
}

/// A `ChatClient` that shells out to one of the user's installed coding CLIs
/// (`claude`, `codex`, `gemini`) for transcript cleanup. The CLIs print the
/// final cleaned text to STDOUT and their agent scaffolding/logs to STDERR, so
/// only STDOUT is read. No API key — the CLI uses the user's own subscription.
///
/// Latency is ~6-16s vs ~1s for an API, so the caller must give a CLI provider a
/// generous timeout; on any failure the cleanup falls back to the raw transcript
/// (see `DictationModeProcessor`), so words are never lost.
public struct CLIChatClient: ChatClient {
    public let id: String
    public let tool: VaraCLITool
    public let model: String
    /// The resolved executable. Resolving in the initializer (off the picker's
    /// hot path) means a missing binary surfaces immediately as a clear error.
    private let executableURL: URL?

    public init(tool: VaraCLITool, model: String) {
        self.id = "cli.\(tool.rawValue)"
        self.tool = tool
        self.model = model.isEmpty ? tool.defaultModel : model
        self.executableURL = resolveExecutable(named: tool.binaryName)
    }

    /// Test seam: inject the executable URL (and skip PATH resolution) so argv
    /// construction and output mapping can be exercised against a stub binary.
    init(tool: VaraCLITool, model: String, executableURL: URL?) {
        self.id = "cli.\(tool.rawValue)"
        self.tool = tool
        self.model = model.isEmpty ? tool.defaultModel : model
        self.executableURL = executableURL
    }

    public func complete(system: String, user: String) async throws -> String {
        guard let executableURL else {
            // Binary not resolvable on the augmented PATH (not installed, or
            // installed somewhere unusual). Map to a clear ChatClientError so the
            // processor falls back to the raw transcript.
            throw ChatClientError.invalidResponse
        }

        // The CLIs take a single prompt argument, so concatenate system + user.
        // `user` is already the framed `<<<TRANSCRIPT … TRANSCRIPT` block from
        // DictationModeProcessor.frameTranscriptAsData, so the injection framing
        // is preserved; the built-in cleanup prompts end with "Output only the
        // cleaned text", which is exactly the tight stdout answer the CLIs return.
        let combinedPrompt = system + "\n\n" + user

        let invocation = Self.invocation(for: tool, model: model, prompt: combinedPrompt)

        // codex resets the shell cwd, so spawn it in a fresh, isolated temp dir
        // that we remove afterwards. If the unique dir can't be created, fall
        // back to the system temp dir (never the app's cwd, which codex would
        // reset anyway).
        var workingDirectory: URL?
        if invocation.needsTempCWD {
            let unique = FileManager.default.temporaryDirectory
                .appendingPathComponent("vara-cli-\(UUID().uuidString)", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: unique, withIntermediateDirectories: true)) != nil {
                workingDirectory = unique
            } else {
                workingDirectory = FileManager.default.temporaryDirectory
            }
        }
        defer {
            if invocation.needsTempCWD, let workingDirectory,
               workingDirectory != FileManager.default.temporaryDirectory {
                try? FileManager.default.removeItem(at: workingDirectory)
            }
        }

        let result = try await runSubprocess(
            executableURL: executableURL,
            arguments: invocation.arguments,
            environment: [:],
            currentDirectory: workingDirectory,
            stdin: nil
        )

        guard result.exitCode == 0 else {
            // A logged-out or erroring CLI exits non-zero. Map to httpError so the
            // existing log-redaction path (which matches "Chat completion HTTP")
            // scrubs stderr — it could echo the transcript — before debug.log.
            throw ChatClientError.httpError(status: Int(result.exitCode), body: result.stderr)
        }

        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ChatClientError.emptyCompletion
        }
        return text
    }

    /// The per-tool argv, built from the validated, stdout-only invocations.
    /// Reasoning/thinking is fixed to low (codex sets it explicitly; claude and
    /// gemini are already non-thinking in plain print mode).
    struct Invocation: Equatable {
        let arguments: [String]
        let needsTempCWD: Bool
    }

    static func invocation(for tool: VaraCLITool, model: String, prompt: String) -> Invocation {
        switch tool {
        case .claude:
            // claude -p "<prompt>" --model <model> — non-interactive print mode,
            // extended thinking off unless the prompt asks for it.
            return Invocation(
                arguments: ["-p", prompt, "--model", model],
                needsTempCWD: false
            )
        case .gemini:
            // gemini -p "<prompt>" -m <model> — the prompt is the -p ARG, not stdin.
            return Invocation(
                arguments: ["-p", prompt, "-m", model],
                needsTempCWD: false
            )
        case .codex:
            // codex exec --skip-git-repo-check -c model_reasoning_effort="low"
            //   -c model="<model>" "<prompt>" — reasoning low is overridden
            // PER-CALL here; the user's ~/.codex/config.toml is never touched.
            return Invocation(
                arguments: [
                    "exec",
                    "--skip-git-repo-check",
                    "-c", "model_reasoning_effort=\"low\"",
                    "-c", "model=\"\(model)\"",
                    prompt,
                ],
                needsTempCWD: true
            )
        }
    }

    /// Which CLI tools are installed (binary resolvable on the augmented PATH).
    /// Used by Settings to only offer a CLI provider when its binary exists.
    /// Auth is assumed if installed — a logged-out CLI exits non-zero and the
    /// cleanup falls back to raw. Cheap filesystem stats; cache the result rather
    /// than calling it on every SwiftUI re-render.
    public static func detectInstalledTools() -> Set<VaraCLITool> {
        var installed = Set<VaraCLITool>()
        for tool in VaraCLITool.allCases where resolveExecutable(named: tool.binaryName) != nil {
            installed.insert(tool)
        }
        return installed
    }
}
