import Foundation
import VaraCore

enum VaraSpeechBackendChoice: String, CaseIterable, Codable, Identifiable {
    case elevenLabsScribe
    case groqWhisper
    case openAIRealtimeWhisper
    case openAIGPT4OTranscribe
    case openAIGPT4OMiniTranscribe20251215
    case localHviske
    case localWhisperKit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .elevenLabsScribe: "ElevenLabs Scribe"
        case .groqWhisper: "Groq Whisper Large v3"
        case .openAIRealtimeWhisper: "OpenAI GPT Realtime Whisper"
        case .openAIGPT4OTranscribe: "OpenAI GPT-4o Transcribe"
        case .openAIGPT4OMiniTranscribe20251215: "OpenAI GPT-4o Mini Transcribe 2025-12-15"
        case .localHviske: "Local Hviske v5.3"
        case .localWhisperKit: "Local WhisperKit (large-v3 turbo)"
        }
    }

    var processingTitle: String {
        switch self {
        case .elevenLabsScribe:
            String(localized: "Realtime network transcription", comment: "Privacy panel: where audio is processed")
        case .groqWhisper:
            String(localized: "Network file transcription via Groq", comment: "Privacy panel: where audio is processed")
        case .openAIRealtimeWhisper:
            String(localized: "Realtime network transcription via OpenAI", comment: "Privacy panel: where audio is processed")
        case .openAIGPT4OTranscribe, .openAIGPT4OMiniTranscribe20251215:
            String(localized: "Network file transcription via OpenAI", comment: "Privacy panel: where audio is processed")
        case .localHviske, .localWhisperKit:
            String(localized: "Local transcription on this Mac", comment: "Privacy panel: where audio is processed")
        }
    }
}

enum VaraSettingsSection: String, CaseIterable, Identifiable {
    case dictation
    case engine
    case intelligence
    case advanced
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: String(localized: "Dictation", comment: "Settings sidebar item")
        case .engine: String(localized: "Engine", comment: "Settings sidebar item")
        case .intelligence: String(localized: "Intelligence", comment: "Settings sidebar item")
        case .advanced: String(localized: "Advanced", comment: "Settings sidebar item")
        case .privacy: String(localized: "Privacy", comment: "Settings sidebar item")
        case .about: String(localized: "About", comment: "Settings sidebar item")
        }
    }

    var systemImage: String {
        switch self {
        case .dictation: "text.bubble"
        case .engine: "waveform"
        case .intelligence: "wand.and.stars"
        case .advanced: "slider.horizontal.3"
        case .privacy: "lock"
        case .about: "info.circle"
        }
    }
}

enum VaraShortcutChoice: String, CaseIterable, Codable, Identifiable {
    case rightCommand
    case leftCommand
    case rightOption
    case leftOption
    case functionKey
    case leftCommandLeftOption
    case leftCommandRightOption
    case rightCommandLeftOption
    case rightCommandRightOption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightCommand: String(localized: "Right Command", comment: "Shortcut key name")
        case .leftCommand: String(localized: "Left Command", comment: "Shortcut key name")
        case .rightOption: String(localized: "Right Option", comment: "Shortcut key name")
        case .leftOption: String(localized: "Left Option", comment: "Shortcut key name")
        case .functionKey: String(localized: "Function key (best effort)", comment: "Shortcut key name")
        case .leftCommandLeftOption: String(localized: "Left Command + Left Option", comment: "Shortcut key name")
        case .leftCommandRightOption: String(localized: "Left Command + Right Option", comment: "Shortcut key name")
        case .rightCommandLeftOption: String(localized: "Right Command + Left Option", comment: "Shortcut key name")
        case .rightCommandRightOption: String(localized: "Right Command + Right Option", comment: "Shortcut key name")
        }
    }

    var symbol: String {
        switch self {
        case .rightCommand, .leftCommand: "⌘"
        case .rightOption, .leftOption: "⌥"
        case .functionKey: "fn"
        case .leftCommandLeftOption,
             .leftCommandRightOption,
             .rightCommandLeftOption,
             .rightCommandRightOption:
            "⌘⌥"
        }
    }

    var globalHotkeyShortcut: GlobalHotkey.Shortcut {
        GlobalHotkey.Shortcut(keys: shortcutKeys)
    }

    static let recordableKeys: Set<GlobalHotkey.Key> = [
        .leftCommand,
        .rightCommand,
        .leftOption,
        .rightOption,
        .function
    ]

    init?(keys: Set<GlobalHotkey.Key>) {
        switch keys {
        case Set<GlobalHotkey.Key>([.rightCommand]):
            self = .rightCommand
        case Set<GlobalHotkey.Key>([.leftCommand]):
            self = .leftCommand
        case Set<GlobalHotkey.Key>([.rightOption]):
            self = .rightOption
        case Set<GlobalHotkey.Key>([.leftOption]):
            self = .leftOption
        case Set<GlobalHotkey.Key>([.function]):
            self = .functionKey
        case Set<GlobalHotkey.Key>([.leftCommand, .leftOption]):
            self = .leftCommandLeftOption
        case Set<GlobalHotkey.Key>([.leftCommand, .rightOption]):
            self = .leftCommandRightOption
        case Set<GlobalHotkey.Key>([.rightCommand, .leftOption]):
            self = .rightCommandLeftOption
        case Set<GlobalHotkey.Key>([.rightCommand, .rightOption]):
            self = .rightCommandRightOption
        default:
            return nil
        }
    }

    private var shortcutKeys: Set<GlobalHotkey.Key> {
        switch self {
        case .rightCommand:
            [.rightCommand]
        case .leftCommand:
            [.leftCommand]
        case .rightOption:
            [.rightOption]
        case .leftOption:
            [.leftOption]
        case .functionKey:
            [.function]
        case .leftCommandLeftOption:
            [.leftCommand, .leftOption]
        case .leftCommandRightOption:
            [.leftCommand, .rightOption]
        case .rightCommandLeftOption:
            [.rightCommand, .leftOption]
        case .rightCommandRightOption:
            [.rightCommand, .rightOption]
        }
    }
}

enum VaraLanguageChoice: String, CaseIterable, Codable, Identifiable {
    case automatic
    case danish
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic", comment: "Language choice")
        case .danish: String(localized: "Danish", comment: "Language choice")
        case .english: String(localized: "English", comment: "Language choice")
        }
    }
}
