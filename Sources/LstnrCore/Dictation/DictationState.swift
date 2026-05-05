import Foundation

public enum DictationInteractionMode: String, CaseIterable, Sendable {
    case pushToTalk
    case toggle
}

public enum DictationSessionState: Equatable, Sendable {
    case idle
    case recording(startedAt: Date)
    case transcribing
    case inserting
    case failed(message: String)

    public var isBusy: Bool {
        switch self {
        case .idle, .failed:
            return false
        case .recording, .transcribing, .inserting:
            return true
        }
    }
}
