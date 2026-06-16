import Foundation

public enum SpeechToTextAudio: Sendable {
    case file(URL)
    case pcm16Stream(AsyncStream<Data>, sampleRate: Int)
}

public struct SpeechToTextRequest: Sendable {
    public let audio: SpeechToTextAudio
    public let languageCode: String?
    /// User-supplied terms/phrases (names, jargon, preferred spellings) that bias
    /// the RAW transcript before LLM cleanup. Each backend maps these to its own
    /// facility: Whisper-family `prompt` (Groq, OpenAI batch), ElevenLabs realtime
    /// `keyterms`. Backends without such a facility ignore them — notably OpenAI
    /// realtime (gpt-realtime-whisper does not support `prompt`) and WhisperKit
    /// (promptTokens deferred pending argmaxinc/WhisperKit#372).
    public let vocabulary: [String]

    public init(audio: SpeechToTextAudio, languageCode: String? = nil, vocabulary: [String] = []) {
        self.audio = audio
        self.languageCode = languageCode
        self.vocabulary = vocabulary
    }

    /// Vocabulary rendered as a Whisper-style `prompt` string (comma-separated),
    /// or nil if empty. Capped to `maxCharacters` so it stays well under
    /// provider token limits (Groq caps `prompt` at 224 tokens).
    public func whisperPrompt(maxCharacters: Int = 896) -> String? {
        let joined = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(maxCharacters))
    }

    /// Vocabulary entries valid as ElevenLabs realtime `keyterms`: trimmed,
    /// non-empty, ≤20 characters (the documented per-term cap), max 50 entries.
    public var elevenLabsKeyterms: [String] {
        Array(
            vocabulary
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 20 }
                .prefix(50)
        )
    }
}

public enum SpeechToTextBackendError: Error, Equatable, CustomStringConvertible, Sendable {
    case unsupportedAudio(backendID: String, reason: String)

    public var description: String {
        switch self {
        case .unsupportedAudio(let backendID, let reason):
            return "Speech-to-text backend '\(backendID)' does not support this audio request: \(reason)"
        }
    }
}

public struct SpeechToTextBackendCapabilities: Equatable, Sendable {
    public let supportsFileTranscription: Bool
    public let supportsStreamingTranscription: Bool
    public let supportsLanguageHints: Bool
    public let supportsTimestamps: Bool
    public let runsLocally: Bool
    public let requiresNetwork: Bool
    public let requiredCredentialKeys: [String]
    public let supportedSampleRates: [Int]

    public init(
        supportsFileTranscription: Bool,
        supportsStreamingTranscription: Bool,
        supportsLanguageHints: Bool,
        supportsTimestamps: Bool,
        runsLocally: Bool,
        requiresNetwork: Bool,
        requiredCredentialKeys: [String],
        supportedSampleRates: [Int]
    ) {
        self.supportsFileTranscription = supportsFileTranscription
        self.supportsStreamingTranscription = supportsStreamingTranscription
        self.supportsLanguageHints = supportsLanguageHints
        self.supportsTimestamps = supportsTimestamps
        self.runsLocally = runsLocally
        self.requiresNetwork = requiresNetwork
        self.requiredCredentialKeys = requiredCredentialKeys
        self.supportedSampleRates = supportedSampleRates
    }
}

public protocol SpeechToTextBackend: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: SpeechToTextBackendCapabilities { get }

    func transcribe(_ request: SpeechToTextRequest) async throws -> TranscriptionResult
}
