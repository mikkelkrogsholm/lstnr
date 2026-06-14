import Foundation

public enum DictationInsertionStatus: String, Codable, Sendable, Equatable {
    case inserted
    case notInserted
    case failed
}

public struct DictationHistoryItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let rawTranscript: String
    public let cleanedTranscript: String?
    public let backend: String
    /// Display name of the dictation mode used; nil for pre-mode history items.
    public let modeName: String?
    /// App the dictation was inserted into; nil when unknown ("General").
    public let targetAppName: String?
    public let detectedLanguage: String?
    public let requestedLanguage: String?
    public let audioDurationSeconds: Double?
    public let elapsedTranscriptionSeconds: Double
    public let insertionStatus: DictationInsertionStatus
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        rawTranscript: String,
        cleanedTranscript: String? = nil,
        backend: String,
        modeName: String? = nil,
        targetAppName: String? = nil,
        detectedLanguage: String? = nil,
        requestedLanguage: String? = nil,
        audioDurationSeconds: Double? = nil,
        elapsedTranscriptionSeconds: Double,
        insertionStatus: DictationInsertionStatus,
        createdAt: Date
    ) {
        self.id = id
        self.rawTranscript = rawTranscript
        self.cleanedTranscript = cleanedTranscript
        self.backend = backend
        self.modeName = modeName
        self.targetAppName = targetAppName
        self.detectedLanguage = detectedLanguage
        self.requestedLanguage = requestedLanguage
        self.audioDurationSeconds = audioDurationSeconds
        self.elapsedTranscriptionSeconds = elapsedTranscriptionSeconds
        self.insertionStatus = insertionStatus
        self.createdAt = createdAt
    }
}
