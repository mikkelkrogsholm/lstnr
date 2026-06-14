import Foundation
import XCTest
@testable import VaraCore

final class SpeechToTextBackendRegistryTests: XCTestCase {
    func testRejectsDuplicateBackendIDs() {
        let first = StubSpeechToTextBackend(id: "duplicate", displayName: "First")
        let second = StubSpeechToTextBackend(id: "duplicate", displayName: "Second")

        XCTAssertThrowsError(try SpeechToTextBackendRegistry(backends: [first, second])) { error in
            guard case SpeechToTextBackendRegistryError.duplicateBackendID("duplicate") = error else {
                return XCTFail("Expected duplicate backend id error, got \(error)")
            }
        }
    }

    func testThrowsForUnknownBackendID() throws {
        let registry = try SpeechToTextBackendRegistry(backends: [
            StubSpeechToTextBackend(id: "known", displayName: "Known")
        ])

        XCTAssertThrowsError(try registry.backend(id: "missing")) { error in
            guard case SpeechToTextBackendRegistryError.unknownBackendID("missing") = error else {
                return XCTFail("Expected unknown backend id error, got \(error)")
            }
        }
    }

    func testReturnsBackendsSortedByDisplayName() throws {
        let registry = try SpeechToTextBackendRegistry(backends: [
            StubSpeechToTextBackend(id: "z", displayName: "Zulu"),
            StubSpeechToTextBackend(id: "a", displayName: "Alpha"),
        ])

        XCTAssertEqual(registry.backends.map(\.id), ["a", "z"])
    }
}

private struct StubSpeechToTextBackend: SpeechToTextBackend {
    let id: String
    let displayName: String

    let capabilities = SpeechToTextBackendCapabilities(
        supportsFileTranscription: true,
        supportsStreamingTranscription: false,
        supportsLanguageHints: false,
        supportsTimestamps: false,
        runsLocally: true,
        requiresNetwork: false,
        requiredCredentialKeys: [],
        supportedSampleRates: []
    )

    func transcribe(_ request: SpeechToTextRequest) async throws -> TranscriptionResult {
        TranscriptionResult(text: "", elapsedSeconds: 0, backend: id)
    }
}
