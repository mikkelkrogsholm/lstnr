import Foundation
import LstnrCore

extension DictationMode {
    /// User-facing name: localized for the built-in modes, literal for
    /// user-created ones.
    var displayTitle: String {
        switch id {
        case DictationMode.rawModeID:
            String(localized: "Raw", comment: "Built-in mode: insert transcript untouched")
        case DictationMode.cleanModeID:
            String(localized: "Clean text", comment: "Built-in mode: LLM cleanup of the transcript")
        case DictationMode.professionalModeID:
            String(localized: "Professional", comment: "Built-in mode: professional tone rewrite")
        case DictationMode.vibeCodeModeID:
            String(localized: "VibeCode", comment: "Built-in mode: speech to coding-agent prompt")
        case DictationMode.askAIModeID:
            String(localized: "Ask AI", comment: "Built-in mode: answer the spoken question")
        default:
            name
        }
    }

    /// One-line explanation shown in pickers and the mode editor.
    var displaySubtitle: String {
        switch id {
        case DictationMode.rawModeID:
            String(localized: "Inserts exactly what the engine heard — no LLM.", comment: "Mode subtitle")
        case DictationMode.cleanModeID:
            String(localized: "Fixes punctuation and removes filler words. Keeps your wording.", comment: "Mode subtitle")
        case DictationMode.professionalModeID:
            String(localized: "Rewrites your words as polished, professional text.", comment: "Mode subtitle")
        case DictationMode.vibeCodeModeID:
            String(localized: "Turns spoken intent into a precise prompt for a coding agent.", comment: "Mode subtitle")
        case DictationMode.askAIModeID:
            String(localized: "Answers your spoken question and inserts the answer.", comment: "Mode subtitle")
        default:
            switch behavior {
            case .insertRaw: String(localized: "Inserts the transcript untouched.", comment: "Mode subtitle for custom raw modes")
            case .rewrite: String(localized: "Rewrites the transcript with your prompt.", comment: "Mode subtitle for custom rewrite modes")
            case .answer: String(localized: "Answers using your prompt.", comment: "Mode subtitle for custom answer modes")
            }
        }
    }
}

extension LLMProvider {
    var displayTitle: String {
        switch self {
        case .openAI: String(localized: "OpenAI", comment: "LLM provider name")
        case .groq: String(localized: "Groq", comment: "LLM provider name")
        case .anthropic: String(localized: "Anthropic (Claude)", comment: "LLM provider name")
        case .ollama: String(localized: "Ollama (local)", comment: "LLM provider name")
        case .custom: String(localized: "Custom endpoint", comment: "LLM provider name")
        }
    }
}
