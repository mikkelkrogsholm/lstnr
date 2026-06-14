import Foundation

public enum SpeechToTextAudio: Sendable {
    case file(URL)
    case pcm16Stream(AsyncStream<Data>, sampleRate: Int)
}

public struct SpeechToTextRequest: Sendable {
    public let audio: SpeechToTextAudio
    public let languageCode: String?

    public init(audio: SpeechToTextAudio, languageCode: String? = nil) {
        self.audio = audio
        self.languageCode = languageCode
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
