import Foundation

/// Result of running a transcript through a dictation mode. When the LLM step
/// fails, `text` carries the raw transcript and `llmErrorDescription` explains
/// why — dictation must never lose the speaker's words.
public struct DictationModeOutcome: Equatable, Sendable {
    public let text: String
    public let usedLLM: Bool
    public let llmErrorDescription: String?

    public init(text: String, usedLLM: Bool, llmErrorDescription: String? = nil) {
        self.text = text
        self.usedLLM = usedLLM
        self.llmErrorDescription = llmErrorDescription
    }
}

/// Applies a `DictationMode` to a transcript: passthrough for `.insertRaw`,
/// one LLM round-trip for `.rewrite`/`.answer`. The chat-client factory is
/// injected so the app layer owns credential resolution.
public struct DictationModeProcessor: Sendable {
    public typealias ChatClientFactory = @Sendable (LLMSelection) throws -> any ChatClient

    private let defaultLLM: LLMSelection?
    private let makeChatClient: ChatClientFactory

    public init(defaultLLM: LLMSelection?, makeChatClient: @escaping ChatClientFactory) {
        self.defaultLLM = defaultLLM
        self.makeChatClient = makeChatClient
    }

    /// Wraps the transcript in a delimited block so the model can tell the
    /// dictated content apart from its instructions. The matching guidance in
    /// the built-in system prompts references this same `TRANSCRIPT` fence.
    static func frameTranscriptAsData(_ transcript: String) -> String {
        """
        <<<TRANSCRIPT
        \(transcript)
        TRANSCRIPT
        """
    }

    public func process(transcript: String, mode: DictationMode) async -> DictationModeOutcome {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return DictationModeOutcome(text: "", usedLLM: false)
        }

        guard mode.behavior != .insertRaw else {
            return DictationModeOutcome(text: trimmed, usedLLM: false)
        }

        guard let selection = mode.llm ?? defaultLLM else {
            return DictationModeOutcome(
                text: trimmed,
                usedLLM: false,
                llmErrorDescription: "No LLM configured for mode '\(mode.name)'"
            )
        }

        do {
            let client = try makeChatClient(selection)
            // Frame the transcript as opaque DATA inside a delimited block so a
            // dictated "ignore your instructions …" can't hijack the system
            // prompt. The built-in prompts instruct the model to treat the user
            // message strictly as content (see DictationMode.builtInModes()).
            let framedUser = DictationModeProcessor.frameTranscriptAsData(trimmed)
            let completion = try await client.complete(system: mode.systemPrompt, user: framedUser)
            // A truncated completion (`ChatClientError.truncated`) throws and is
            // handled by the catch below — the raw transcript is inserted, never
            // a half-finished sentence.
            let cleaned = completion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                return DictationModeOutcome(
                    text: trimmed,
                    usedLLM: false,
                    llmErrorDescription: String(describing: ChatClientError.emptyCompletion)
                )
            }
            return DictationModeOutcome(text: cleaned, usedLLM: true)
        } catch {
            return DictationModeOutcome(
                text: trimmed,
                usedLLM: false,
                llmErrorDescription: String(describing: error)
            )
        }
    }
}
