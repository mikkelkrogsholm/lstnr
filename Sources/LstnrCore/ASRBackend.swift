import Foundation

public protocol ASRBackend: Sendable {
    var name: String { get }
    func transcribe(audio: URL, language: String?) async throws -> TranscriptionResult
}
