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
        vocabulary: []
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
        vocabulary: [String]
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
            vocabulary: draft.vocabulary
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
            vocabulary: vocabulary
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            shortcut: try container.decodeIfPresent(VaraShortcutChoice.self, forKey: .shortcut) ?? Self.defaults.shortcut,
            language: try container.decodeIfPresent(VaraLanguageChoice.self, forKey: .language) ?? Self.defaults.language,
            speechBackend: try container.decodeIfPresent(VaraSpeechBackendChoice.self, forKey: .speechBackend) ?? Self.defaults.speechBackend,
            whisperKitModel: try container.decodeIfPresent(String.self, forKey: .whisperKitModel) ?? Self.defaults.whisperKitModel,
            pasteAutomatically: try container.decodeIfPresent(Bool.self, forKey: .pasteAutomatically) ?? Self.defaults.pasteAutomatically,
            showHUD: try container.decodeIfPresent(Bool.self, forKey: .showHUD) ?? Self.defaults.showHUD,
            keepRecentTranscript: try container.decodeIfPresent(Bool.self, forKey: .keepRecentTranscript) ?? Self.defaults.keepRecentTranscript,
            historyLimit: try container.decodeIfPresent(Int.self, forKey: .historyLimit) ?? Self.defaults.historyLimit,
            modes: try container.decodeIfPresent([DictationMode].self, forKey: .modes) ?? Self.defaults.modes,
            selectedModeID: try container.decodeIfPresent(UUID.self, forKey: .selectedModeID) ?? Self.defaults.selectedModeID,
            defaultLLM: try container.decodeIfPresent(LLMSelection.self, forKey: .defaultLLM) ?? Self.defaults.defaultLLM,
            customEndpoints: try container.decodeIfPresent([CustomLLMEndpoint].self, forKey: .customEndpoints) ?? Self.defaults.customEndpoints,
            appModeRules: try container.decodeIfPresent([AppModeRule].self, forKey: .appModeRules) ?? Self.defaults.appModeRules,
            playSounds: try container.decodeIfPresent(Bool.self, forKey: .playSounds) ?? Self.defaults.playSounds,
            vocabulary: try container.decodeIfPresent([String].self, forKey: .vocabulary) ?? Self.defaults.vocabulary
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

    static let preview = VaraAppSettings.defaults.draft
}
