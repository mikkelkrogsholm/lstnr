import Foundation
import LstnrCore

/// Presentation metadata for the STT engine cards in Settings and onboarding.
extension LstnrSpeechBackendChoice {
    var isLocal: Bool {
        self == .localHviske
    }

    var symbolName: String {
        switch self {
        case .elevenLabsScribe: "waveform.badge.mic"
        case .groqWhisper: "bolt.fill"
        case .openAIRealtimeWhisper: "dot.radiowaves.left.and.right"
        case .openAIGPT4OTranscribe, .openAIGPT4OMiniTranscribe20251215: "cloud"
        case .localHviske: "internaldrive"
        }
    }

    /// Which API key the engine needs; nil for local engines.
    var credentialProvider: LstnrCredentialProvider? {
        switch self {
        case .elevenLabsScribe: .elevenLabs
        case .groqWhisper: .groq
        case .openAIRealtimeWhisper, .openAIGPT4OTranscribe, .openAIGPT4OMiniTranscribe20251215: .openAI
        case .localHviske: nil
        }
    }

    var latencyHint: String {
        switch self {
        case .elevenLabsScribe, .openAIRealtimeWhisper:
            String(localized: "Streaming — fastest", comment: "Engine latency hint")
        case .groqWhisper:
            String(localized: "Batch — very fast", comment: "Engine latency hint")
        case .openAIGPT4OTranscribe, .openAIGPT4OMiniTranscribe20251215:
            String(localized: "Batch", comment: "Engine latency hint")
        case .localHviske:
            String(localized: "On this Mac — private, Danish", comment: "Engine latency hint")
        }
    }

    var shortTitle: String {
        switch self {
        case .elevenLabsScribe: "ElevenLabs Scribe"
        case .groqWhisper: "Groq Whisper"
        case .openAIRealtimeWhisper: "OpenAI Realtime"
        case .openAIGPT4OTranscribe: "GPT-4o Transcribe"
        case .openAIGPT4OMiniTranscribe20251215: "GPT-4o Mini Transcribe"
        case .localHviske: "Hviske (lokal)"
        }
    }
}

extension LstnrCredentialProvider {
    var displayTitle: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .groq: "Groq"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    var environmentVariableName: String {
        switch self {
        case .elevenLabs: "ELEVENLABS_API_KEY"
        case .groq: "GROQ_API_KEY"
        case .openAI: "OPENAI_API_KEY"
        case .anthropic: "ANTHROPIC_API_KEY"
        }
    }
}
