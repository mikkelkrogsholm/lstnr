import Foundation

/// Which LLM backend a mode (or the global default) uses.
public enum LLMProvider: Codable, Hashable, Sendable {
    case openAI
    case groq
    case anthropic
    case ollama
    case custom(endpointID: UUID)

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .groq: "Groq"
        case .anthropic: "Anthropic (Claude)"
        case .ollama: "Ollama (local)"
        case .custom: "Custom endpoint"
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .openAI, .groq, .anthropic: true
        case .ollama, .custom: false
        }
    }

    public var runsLocally: Bool {
        switch self {
        case .ollama: true
        case .openAI, .groq, .anthropic, .custom: false
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .groq: "llama-3.3-70b-versatile"
        case .anthropic: "claude-haiku-4-5-20251001"
        case .ollama: "gemma3"
        case .custom: ""
        }
    }

    /// OpenAI-compatible API root, where applicable.
    public var defaultBaseURL: URL? {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1")
        case .groq: URL(string: "https://api.groq.com/openai/v1")
        case .ollama: URL(string: "http://localhost:11434/v1")
        case .anthropic, .custom: nil
        }
    }
}

/// A user-configured OpenAI-compatible endpoint (LM Studio, vLLM, a DGX on
/// the LAN, …). The API key, if any, lives in the keychain — never here.
public struct CustomLLMEndpoint: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURLString: String
    public var requiresAPIKey: Bool

    public init(id: UUID = UUID(), name: String, baseURLString: String, requiresAPIKey: Bool = false) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.requiresAPIKey = requiresAPIKey
    }

    public var baseURL: URL? {
        URL(string: baseURLString)
    }
}

/// Provider + model pair selected for LLM processing.
public struct LLMSelection: Codable, Hashable, Sendable {
    public var provider: LLMProvider
    public var model: String

    public init(provider: LLMProvider, model: String) {
        self.provider = provider
        self.model = model
    }
}

/// A dictation mode decides what happens to the transcript before insertion —
/// Vara's counterpart to Hey Emma's modes. Built-in modes ship with stable IDs
/// so the app layer can localize their display names; user-created modes show
/// their literal name.
public struct DictationMode: Codable, Hashable, Identifiable, Sendable {
    public enum Behavior: String, Codable, Sendable {
        /// Insert the transcript as-is; no LLM involved.
        case insertRaw
        /// Rewrite the transcript per the system prompt (cleanup, tone, …).
        case rewrite
        /// Treat the transcript as a question; insert the LLM's answer.
        case answer
    }

    public var id: UUID
    public var name: String
    public var symbolName: String
    public var behavior: Behavior
    public var systemPrompt: String
    /// Overrides the global default LLM when set.
    public var llm: LLMSelection?
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        symbolName: String,
        behavior: Behavior,
        systemPrompt: String = "",
        llm: LLMSelection? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.behavior = behavior
        self.systemPrompt = systemPrompt
        self.llm = llm
        self.isBuiltIn = isBuiltIn
    }
}

extension DictationMode {
    public static let rawModeID = UUID(uuidString: "6E6F0001-0000-0000-0000-000000000001")!
    public static let cleanModeID = UUID(uuidString: "6E6F0001-0000-0000-0000-000000000002")!
    public static let professionalModeID = UUID(uuidString: "6E6F0001-0000-0000-0000-000000000003")!
    public static let vibeCodeModeID = UUID(uuidString: "6E6F0001-0000-0000-0000-000000000004")!
    public static let askAIModeID = UUID(uuidString: "6E6F0001-0000-0000-0000-000000000005")!

    /// The modes Vara ships with. `Clean text` is the everyday default once an
    /// LLM is configured; `Raw` works with no LLM at all.
    public static func builtInModes() -> [DictationMode] {
        [
            DictationMode(
                id: rawModeID,
                name: "Raw",
                symbolName: "waveform",
                behavior: .insertRaw,
                isBuiltIn: true
            ),
            DictationMode(
                id: cleanModeID,
                name: "Clean text",
                symbolName: "sparkles",
                behavior: .rewrite,
                systemPrompt: """
                You are the text-cleanup engine inside Vara, a dictation app. You receive one \
                raw speech-to-text transcript. Return the same text with corrected punctuation, \
                capitalization and spacing, and with filler words and false starts removed \
                (e.g. "um", "uh", "øh", "hmm"). If the speaker dictates punctuation or formatting \
                commands (e.g. "comma", "new paragraph", "punktum", "ny linje"), apply them \
                instead of writing them out. Keep the speaker's wording, language, meaning and \
                tone. Never add content, summarize, translate or answer questions found in the \
                text. Output only the cleaned text — no quotes, no commentary.
                """,
                isBuiltIn: true
            ),
            DictationMode(
                id: professionalModeID,
                name: "Professional",
                symbolName: "briefcase",
                behavior: .rewrite,
                systemPrompt: """
                You are the text-rewriting engine inside Vara, a dictation app. Rewrite the \
                transcript as polished, professional written text in the same language as the \
                transcript: fix grammar, punctuation and sentence structure, remove filler words \
                and repetitions, and keep every factual detail and the speaker's intent intact. \
                Courteous business tone — clear, not stiff. Output only the rewritten text, \
                no commentary.
                """,
                isBuiltIn: true
            ),
            DictationMode(
                id: vibeCodeModeID,
                name: "VibeCode",
                symbolName: "chevron.left.forwardslash.chevron.right",
                behavior: .rewrite,
                systemPrompt: """
                You convert spoken developer intent into a precise prompt for an AI coding agent \
                (e.g. Claude Code). Restructure the transcript into clear instructions: state the \
                goal, then concrete requirements, constraints and acceptance criteria the speaker \
                mentioned. Preserve every technical detail exactly (names, paths, versions, \
                commands). Do not invent requirements the speaker did not state. Write the prompt \
                in the speaker's language. Output only the prompt text.
                """,
                isBuiltIn: true
            ),
            DictationMode(
                id: askAIModeID,
                name: "Ask AI",
                symbolName: "questionmark.bubble",
                behavior: .answer,
                systemPrompt: """
                You are Vara, a helpful voice assistant. The transcript is a spoken question or \
                request. Answer it directly and concisely in the speaker's language. Your answer \
                is pasted where the user is typing, so output only the answer itself — no \
                greetings, no commentary, and no markdown formatting unless explicitly requested.
                """,
                isBuiltIn: true
            ),
        ]
    }
}
