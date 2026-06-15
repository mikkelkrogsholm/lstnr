import Foundation
import VaraCore

/// How an engine or LLM provider is presented in Settings: the mainstream,
/// zero-setup picks (Groq/OpenAI — bring one key) vs. the advanced integrations
/// that need the user to do the last bit of setup themselves (ElevenLabs,
/// on-device Hviske, Ollama, custom endpoints). Tiering is about last-mile setup
/// and the zero-cost Groq default — not local-vs-cloud.
enum VaraEngineTier {
    case recommended
    case advanced

    /// Badge text for the Advanced tier; nil for Recommended (no badge).
    var badgeTitle: String? {
        switch self {
        case .recommended: nil
        case .advanced: String(localized: "Advanced", comment: "Engine tier badge")
        }
    }
}

/// Presentation metadata for the STT engine cards in Settings and onboarding.
extension VaraSpeechBackendChoice {
    /// Mainstream cloud engines (Groq, all OpenAI variants) are Recommended;
    /// ElevenLabs and on-device Hviske are Advanced integrations.
    var tier: VaraEngineTier {
        switch self {
        case .groqWhisper,
             .openAIRealtimeWhisper,
             .openAIGPT4OTranscribe,
             .openAIGPT4OMiniTranscribe20251215:
            .recommended
        case .elevenLabsScribe, .localHviske, .localWhisperKit:
            .advanced
        }
    }

    var isLocal: Bool {
        self == .localHviske || self == .localWhisperKit
    }

    var symbolName: String {
        switch self {
        case .elevenLabsScribe: "waveform.badge.mic"
        case .groqWhisper: "bolt.fill"
        case .openAIRealtimeWhisper: "dot.radiowaves.left.and.right"
        case .openAIGPT4OTranscribe, .openAIGPT4OMiniTranscribe20251215: "cloud"
        case .localHviske: "internaldrive"
        case .localWhisperKit: "cpu"
        }
    }

    /// Which API key the engine needs; nil for local engines.
    var credentialProvider: VaraCredentialProvider? {
        switch self {
        case .elevenLabsScribe: .elevenLabs
        case .groqWhisper: .groq
        case .openAIRealtimeWhisper, .openAIGPT4OTranscribe, .openAIGPT4OMiniTranscribe20251215: .openAI
        case .localHviske, .localWhisperKit: nil
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
            String(localized: "Runs on this Mac — Danish", comment: "Engine latency hint")
        case .localWhisperKit:
            String(localized: "Runs on this Mac — Neural Engine", comment: "Engine latency hint")
        }
    }

    var shortTitle: String {
        switch self {
        case .elevenLabsScribe: "ElevenLabs Scribe"
        case .groqWhisper: "Groq Whisper"
        case .openAIRealtimeWhisper: "OpenAI Realtime"
        case .openAIGPT4OTranscribe: "GPT-4o Transcribe"
        case .openAIGPT4OMiniTranscribe20251215: "GPT-4o Mini Transcribe"
        // Localized "Local" tag instead of the hardcoded Danish "(lokal)" leak.
        case .localHviske: "Hviske (\(String(localized: "Local", comment: "Engine name suffix marking an on-device engine")))"
        case .localWhisperKit: "WhisperKit (\(String(localized: "Local", comment: "Engine name suffix marking an on-device engine")))"
        }
    }

    /// Short, brand-free name for the onboarding engine chooser rows. No model
    /// VERSION names (they churn).
    var onboardingTitle: String {
        switch self {
        case .localWhisperKit: "WhisperKit"
        case .localHviske: "Hviske"
        case .groqWhisper: "Groq"
        case .openAIRealtimeWhisper, .openAIGPT4OTranscribe, .openAIGPT4OMiniTranscribe20251215: "OpenAI"
        case .elevenLabsScribe: "ElevenLabs Scribe"
        }
    }

    /// Plain-language subtitle for the onboarding engine chooser — describes the
    /// privacy/setup tradeoff (distinct from the Settings `latencyHint`), no
    /// model VERSION names.
    var onboardingSubtitle: String {
        switch self {
        case .localWhisperKit:
            String(localized: "Built in · downloads a model once, then runs entirely on your Mac", comment: "Onboarding engine subtitle: WhisperKit")
        case .localHviske:
            String(localized: "Offline · needs one setup command in Terminal", comment: "Onboarding engine subtitle: Hviske")
        case .groqWhisper:
            String(localized: "Fast transcription · free key in 30 seconds", comment: "Onboarding engine subtitle: Groq")
        case .openAIRealtimeWhisper, .openAIGPT4OTranscribe, .openAIGPT4OMiniTranscribe20251215:
            String(localized: "Transcription + cleanup in one", comment: "Onboarding engine subtitle: OpenAI")
        case .elevenLabsScribe:
            String(localized: "Strong Danish in the cloud · realtime", comment: "Onboarding engine subtitle: ElevenLabs")
        }
    }
}

/// Localized label for a WhisperKit CoreML model id (the App layer owns
/// presentation; `WhisperKitBackend.availableModelIDs` owns the raw names).
func whisperKitModelLabel(_ modelID: String) -> String {
    switch modelID {
    case "large-v3-v20240930_turbo":
        String(localized: "Large v3 Turbo — fastest", comment: "WhisperKit model option")
    case "large-v3-v20240930_626MB":
        String(localized: "Large v3 Turbo (compressed) — best for Danish", comment: "WhisperKit model option")
    case "small":
        String(localized: "Small — lightweight, lower accuracy", comment: "WhisperKit model option")
    default:
        modelID
    }
}

extension VaraCredentialProvider {
    var displayTitle: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .groq: "Groq"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        }
    }

    var environmentVariableName: String {
        switch self {
        case .elevenLabs: "ELEVENLABS_API_KEY"
        case .groq: "GROQ_API_KEY"
        case .openAI: "OPENAI_API_KEY"
        case .anthropic: "ANTHROPIC_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        }
    }
}

extension LLMProvider {
    /// Groq and OpenAI are the Recommended cleanup providers (one key powers
    /// both transcription and cleanup; Groq is the zero-cost default). Anthropic
    /// is cloud but a bring-your-own-paid-key, and Ollama/custom need local
    /// setup, so all three are Advanced.
    var tier: VaraEngineTier {
        switch self {
        case .groq, .openAI:
            .recommended
        case .anthropic, .ollama, .custom, .gemini, .claudeCLI, .codexCLI, .geminiCLI:
            .advanced
        }
    }
}
