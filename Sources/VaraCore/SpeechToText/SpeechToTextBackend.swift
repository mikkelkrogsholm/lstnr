import Foundation

public enum SpeechToTextAudio: Sendable {
    case file(URL)
    case pcm16Stream(AsyncStream<Data>, sampleRate: Int)
}

/// Microphone profile for input-audio noise reduction. Maps to the OpenAI
/// realtime `audio.input.noise_reduction.type`; ignored by backends without an
/// equivalent. `nearField` suits close-talking mics (headset/built-in laptop mic
/// held close), `farField` suits room/conference mics.
public enum MicrophoneProfile: String, Codable, Sendable, CaseIterable {
    case nearField
    case farField

    /// The OpenAI realtime `noise_reduction.type` value.
    public var openAINoiseReductionType: String {
        switch self {
        case .nearField: "near_field"
        case .farField: "far_field"
        }
    }
}

/// Transcription latency/accuracy tradeoff for the OpenAI realtime
/// `gpt-realtime-whisper` model (audio.input.transcription.delay). Higher = more
/// accurate, slightly slower. `auto` sends nothing (server default). Ignored by
/// every other backend.
public enum TranscriptionLatency: String, Codable, Sendable, CaseIterable {
    case auto
    case minimal
    case low
    case medium
    case high
    case xhigh

    /// The OpenAI `delay` value, or nil for `auto` (omit the field).
    public var openAIDelay: String? {
        self == .auto ? nil : rawValue
    }
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
    /// Microphone profile for input noise reduction. Consumed only by backends
    /// with an equivalent (OpenAI realtime); others ignore it.
    public let microphoneProfile: MicrophoneProfile
    /// Latency/accuracy tradeoff (OpenAI realtime only); others ignore it.
    public let transcriptionLatency: TranscriptionLatency

    public init(
        audio: SpeechToTextAudio,
        languageCode: String? = nil,
        vocabulary: [String] = [],
        microphoneProfile: MicrophoneProfile = .nearField,
        transcriptionLatency: TranscriptionLatency = .auto
    ) {
        self.audio = audio
        self.languageCode = languageCode
        self.vocabulary = vocabulary
        self.microphoneProfile = microphoneProfile
        self.transcriptionLatency = transcriptionLatency
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
    /// A compact engine label for tight UI such as the dictation HUD chip (so the
    /// active engine is clear without truncation). Defaults to `displayName`;
    /// backends with a long `displayName` override it.
    var shortName: String { get }
    var capabilities: SpeechToTextBackendCapabilities { get }

    func transcribe(_ request: SpeechToTextRequest) async throws -> TranscriptionResult
}

public extension SpeechToTextBackend {
    var shortName: String { displayName }
}
