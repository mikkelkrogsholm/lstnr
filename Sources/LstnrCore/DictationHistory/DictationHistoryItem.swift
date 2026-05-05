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
        self.detectedLanguage = detectedLanguage
        self.requestedLanguage = requestedLanguage
        self.audioDurationSeconds = audioDurationSeconds
        self.elapsedTranscriptionSeconds = elapsedTranscriptionSeconds
        self.insertionStatus = insertionStatus
        self.createdAt = createdAt
    }
}
