import Foundation
import VaraCore

struct VaraAppSettings: Codable, Hashable {
    var shortcut: VaraShortcutChoice
    var language: VaraLanguageChoice
    var speechBackend: VaraSpeechBackendChoice
    var whisperKitModel: String
    var pasteAutomatically: Bool
    var showHUD: Bool
    var keepRecentTranscript: Bool
    var historyLimit: Int
    var modes: [DictationMode]
    var selectedModeID: UUID
    var defaultLLM: LLMSelection?
    var customEndpoints: [CustomLLMEndpoint]
    var appModeRules: [AppModeRule]
    var playSounds: Bool
    /// User-supplied terms/phrases (names, jargon, preferred spellings) that bias
    /// the raw transcript. Mapped per backend (Whisper `prompt`, ElevenLabs
    /// `keyterms`); ignored by backends without such a facility.
    var vocabulary: [String]
    /// Microphone profile for input noise reduction (OpenAI realtime only).
    var microphoneProfile: MicrophoneProfile
    /// Latency/accuracy tradeoff (OpenAI realtime only).
    var realtimeLatency: TranscriptionLatency

    static let defaults = VaraAppSettings(
        shortcut: .rightCommand,
        language: .automatic,
        speechBackend: .groqWhisper,
        whisperKitModel: WhisperKitBackend.defaultModel,
        pasteAutomatically: true,
        showHUD: true,
        keepRecentTranscript: true,
        historyLimit: 100,
        modes: DictationMode.builtInModes(),
        selectedModeID: DictationMode.rawModeID,
        // Groq is the zero-cost default for BOTH layers: one free key from
        // console.groq.com unlocks Whisper (STT) and Llama 3.3 (cleanup).
        // Mode stays Raw until a key exists; onboarding upgrades to Clean text
        // once the LLM is configured.
        defaultLLM: LLMSelection(provider: .groq, model: "llama-3.3-70b-versatile"),
        customEndpoints: [],
        appModeRules: [],
        playSounds: true,
        vocabulary: [],
        microphoneProfile: .nearField,
        realtimeLatency: .auto
    )

    init(
        shortcut: VaraShortcutChoice,
        language: VaraLanguageChoice,
        speechBackend: VaraSpeechBackendChoice,
        whisperKitModel: String,
        pasteAutomatically: Bool,
        showHUD: Bool,
        keepRecentTranscript: Bool,
        historyLimit: Int,
        modes: [DictationMode],
        selectedModeID: UUID,
        defaultLLM: LLMSelection?,
        customEndpoints: [CustomLLMEndpoint],
        appModeRules: [AppModeRule],
        playSounds: Bool,
        vocabulary: [String],
        microphoneProfile: MicrophoneProfile,
        realtimeLatency: TranscriptionLatency
    ) {
        self.shortcut = shortcut
        self.language = language
        self.speechBackend = speechBackend
        // Migrate away from a removed/unknown WhisperKit model (e.g. the dropped
        // 626MB variant a user may have persisted) to the default, so settings
        // never point the engine at a model the picker no longer offers.
        self.whisperKitModel = WhisperKitBackend.availableModelIDs.contains(whisperKitModel)
            ? whisperKitModel
            : WhisperKitBackend.defaultModel
        self.pasteAutomatically = pasteAutomatically
        self.showHUD = showHUD
        self.keepRecentTranscript = keepRecentTranscript
        self.historyLimit = historyLimit
        self.modes = Self.withBuiltInModes(modes)
        self.selectedModeID = selectedModeID
        self.defaultLLM = defaultLLM
        self.customEndpoints = customEndpoints
        self.appModeRules = appModeRules
        self.playSounds = playSounds
        self.vocabulary = vocabulary
        self.microphoneProfile = microphoneProfile
        self.realtimeLatency = realtimeLatency
    }

    init(draft: VaraSettingsDraft) {
        self.init(
            shortcut: draft.shortcut,
            language: draft.language,
            speechBackend: draft.speechBackend,
            whisperKitModel: draft.whisperKitModel,
            pasteAutomatically: draft.pasteAutomatically,
            showHUD: draft.showHUD,
            keepRecentTranscript: draft.keepRecentTranscript,
            historyLimit: draft.historyLimit,
            modes: draft.modes,
            selectedModeID: draft.selectedModeID,
            defaultLLM: draft.defaultLLM,
            customEndpoints: draft.customEndpoints,
            appModeRules: draft.appModeRules,
            playSounds: draft.playSounds,
            vocabulary: draft.vocabulary,
            microphoneProfile: draft.microphoneProfile,
            realtimeLatency: draft.realtimeLatency
        )
    }

    var draft: VaraSettingsDraft {
        VaraSettingsDraft(
            shortcut: shortcut,
            language: language,
            speechBackend: speechBackend,
            whisperKitModel: whisperKitModel,
            pasteAutomatically: pasteAutomatically,
            showHUD: showHUD,
            keepRecentTranscript: keepRecentTranscript,
            historyLimit: min(max(historyLimit, 10), 200),
            modes: modes,
            selectedModeID: selectedModeID,
            defaultLLM: defaultLLM,
            customEndpoints: customEndpoints,
            appModeRules: appModeRules,
            playSounds: playSounds,
            vocabulary: vocabulary,
            microphoneProfile: microphoneProfile,
            realtimeLatency: realtimeLatency
        )
    }

    /// The active mode; falls back to Raw if the selected ID disappeared.
    var selectedMode: DictationMode {
        modes.first { $0.id == selectedModeID }
            ?? modes.first { $0.id == DictationMode.rawModeID }
            ?? DictationMode.builtInModes()[0]
    }

    /// Ensures every built-in mode exists (re-adds ones missing after upgrades)
    /// while preserving user edits to built-ins and custom modes.
    private static func withBuiltInModes(_ modes: [DictationMode]) -> [DictationMode] {
        let existingIDs = Set(modes.map(\.id))
        let missingBuiltIns = DictationMode.builtInModes().filter { !existingIDs.contains($0.id) }
        return missingBuiltIns + modes
    }

    enum CodingKeys: String, CodingKey {
        case shortcut
        case language
        case speechBackend
        case whisperKitModel
        case pasteAutomatically
        case showHUD
        case keepRecentTranscript
        case historyLimit
        case modes
        case selectedModeID
        case defaultLLM
        case customEndpoints
        case appModeRules
        case playSounds
        case vocabulary
        case microphoneProfile
        case realtimeLatency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant per-field decode: an absent key OR an unknown/garbage value
        // (e.g. an enum rawValue dropped in a future version, or a downgrade)
        // falls back to the default for THAT field, instead of throwing and
        // wiping ALL of the user's settings.
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) -> T {
            // `try?` flattens decodeIfPresent's T? to nil for BOTH an absent key
            // and a throw (unknown/garbage rawValue), so either way → fallback.
            (try? container.decodeIfPresent(type, forKey: key)) ?? fallback
        }
        self.init(
            shortcut: value(VaraShortcutChoice.self, .shortcut, Self.defaults.shortcut),
            language: value(VaraLanguageChoice.self, .language, Self.defaults.language),
            speechBackend: value(VaraSpeechBackendChoice.self, .speechBackend, Self.defaults.speechBackend),
            whisperKitModel: value(String.self, .whisperKitModel, Self.defaults.whisperKitModel),
            pasteAutomatically: value(Bool.self, .pasteAutomatically, Self.defaults.pasteAutomatically),
            showHUD: value(Bool.self, .showHUD, Self.defaults.showHUD),
            keepRecentTranscript: value(Bool.self, .keepRecentTranscript, Self.defaults.keepRecentTranscript),
            historyLimit: value(Int.self, .historyLimit, Self.defaults.historyLimit),
            modes: value([DictationMode].self, .modes, Self.defaults.modes),
            selectedModeID: value(UUID.self, .selectedModeID, Self.defaults.selectedModeID),
            defaultLLM: (try? container.decodeIfPresent(LLMSelection.self, forKey: .defaultLLM)) ?? Self.defaults.defaultLLM,
            customEndpoints: value([CustomLLMEndpoint].self, .customEndpoints, Self.defaults.customEndpoints),
            appModeRules: value([AppModeRule].self, .appModeRules, Self.defaults.appModeRules),
            playSounds: value(Bool.self, .playSounds, Self.defaults.playSounds),
            vocabulary: value([String].self, .vocabulary, Self.defaults.vocabulary),
            microphoneProfile: value(MicrophoneProfile.self, .microphoneProfile, Self.defaults.microphoneProfile),
            realtimeLatency: value(TranscriptionLatency.self, .realtimeLatency, Self.defaults.realtimeLatency)
        )
    }
}

struct VaraSettingsDraft: Hashable {
    var shortcut: VaraShortcutChoice
    var language: VaraLanguageChoice
    var speechBackend: VaraSpeechBackendChoice
    var whisperKitModel: String
    var pasteAutomatically: Bool
    var showHUD: Bool
    var keepRecentTranscript: Bool
    var historyLimit: Int
    var modes: [DictationMode]
    var selectedModeID: UUID
    var defaultLLM: LLMSelection?
    var customEndpoints: [CustomLLMEndpoint]
    var appModeRules: [AppModeRule]
    var playSounds: Bool
    var vocabulary: [String]
    var microphoneProfile: MicrophoneProfile
    var realtimeLatency: TranscriptionLatency

    static let preview = VaraAppSettings.defaults.draft
}
