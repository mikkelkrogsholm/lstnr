import Foundation
import XCTest
@testable import VaraCore

final class GroqWhisperBackendTests: XCTestCase {
    func testCapabilitiesDescribeNetworkFileTranscription() {
        let backend = GroqWhisperBackend(apiKey: "test-key")

        XCTAssertEqual(backend.id, "groq-whisper-large-v3")
        XCTAssertEqual(backend.displayName, "Groq Whisper Large v3")
        XCTAssertTrue(backend.capabilities.supportsFileTranscription)
        XCTAssertFalse(backend.capabilities.supportsStreamingTranscription)
        XCTAssertTrue(backend.capabilities.supportsLanguageHints)
        XCTAssertTrue(backend.capabilities.supportsTimestamps)
        XCTAssertFalse(backend.capabilities.runsLocally)
        XCTAssertTrue(backend.capabilities.requiresNetwork)
        XCTAssertEqual(backend.capabilities.requiredCredentialKeys, ["GROQ_API_KEY"])
        XCTAssertEqual(backend.capabilities.supportedSampleRates, [16_000])
    }

    func testRejectsUnsupportedStreamingSampleRate() async {
        let backend = GroqWhisperBackend(apiKey: "test-key")
        let request = SpeechToTextRequest(audio: .pcm16Stream(AsyncStream { $0.finish() }, sampleRate: 44_100))

        await XCTAssertThrowsErrorAsync(try await backend.transcribe(request)) { error in
            XCTAssertEqual(
                error as? SpeechToTextBackendError,
                .unsupportedAudio(
                    backendID: "groq-whisper-large-v3",
                    reason: "Groq Whisper expects PCM s16le mono at 16000 Hz; received 44100 Hz."
                )
            )
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
