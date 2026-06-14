import Foundation

public struct TranscriptionResult: Sendable {
    public let text: String
    public let detectedLanguage: String?
    public let languageConfidence: Double?
    public let audioDurationSeconds: Double?
    public let elapsedSeconds: Double
    public let backend: String
    public let rawJSON: Data?

    public init(
        text: String,
        detectedLanguage: String? = nil,
        languageConfidence: Double? = nil,
        audioDurationSeconds: Double? = nil,
        elapsedSeconds: Double,
        backend: String,
        rawJSON: Data? = nil
    ) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.languageConfidence = languageConfidence
        self.audioDurationSeconds = audioDurationSeconds
        self.elapsedSeconds = elapsedSeconds
        self.backend = backend
        self.rawJSON = rawJSON
    }
}
