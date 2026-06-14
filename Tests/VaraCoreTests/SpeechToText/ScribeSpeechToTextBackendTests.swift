import Foundation
import XCTest
@testable import VaraCore

final class ScribeSpeechToTextBackendTests: XCTestCase {
    func testBatchBackendCapabilitiesDescribeFileOnlyNetworkTranscription() {
        let backend = ScribeV2Backend(apiKey: "test-key")

        XCTAssertEqual(backend.id, "scribe-v2")
        XCTAssertEqual(backend.displayName, "ElevenLabs Scribe v2")
        XCTAssertTrue(backend.capabilities.supportsFileTranscription)
        XCTAssertFalse(backend.capabilities.supportsStreamingTranscription)
        XCTAssertTrue(backend.capabilities.supportsLanguageHints)
        XCTAssertTrue(backend.capabilities.supportsTimestamps)
        XCTAssertFalse(backend.capabilities.runsLocally)
        XCTAssertTrue(backend.capabilities.requiresNetwork)
        XCTAssertEqual(backend.capabilities.requiredCredentialKeys, ["ELEVENLABS_API_KEY"])
        XCTAssertEqual(backend.capabilities.supportedSampleRates, [])
    }

    func testRealtimeBackendCapabilitiesDescribeStreamingNetworkTranscription() {
        let backend = ScribeRealtimeBackend(apiKey: "test-key")

        XCTAssertEqual(backend.id, "scribe-realtime")
        XCTAssertEqual(backend.displayName, "ElevenLabs Scribe v2 Realtime")
        XCTAssertTrue(backend.capabilities.supportsFileTranscription)
        XCTAssertTrue(backend.capabilities.supportsStreamingTranscription)
        XCTAssertTrue(backend.capabilities.supportsLanguageHints)
        XCTAssertTrue(backend.capabilities.supportsTimestamps)
        XCTAssertFalse(backend.capabilities.runsLocally)
        XCTAssertTrue(backend.capabilities.requiresNetwork)
        XCTAssertEqual(backend.capabilities.requiredCredentialKeys, ["ELEVENLABS_API_KEY"])
        XCTAssertEqual(backend.capabilities.supportedSampleRates, [16_000])
    }

    func testBatchBackendRejectsStreamingAudioShape() async {
        let backend = ScribeV2Backend(apiKey: "test-key")
        let request = SpeechToTextRequest(audio: .pcm16Stream(AsyncStream { $0.finish() }, sampleRate: 16_000))

        await XCTAssertThrowsErrorAsync(try await backend.transcribe(request)) { error in
            XCTAssertEqual(
                error as? SpeechToTextBackendError,
                .unsupportedAudio(
                    backendID: "scribe-v2",
                    reason: "Scribe v2 batch transcription accepts file audio only."
                )
            )
        }
    }

    func testRealtimeBackendRejectsUnsupportedStreamingSampleRate() async {
        let backend = ScribeRealtimeBackend(apiKey: "test-key")
        let request = SpeechToTextRequest(audio: .pcm16Stream(AsyncStream { $0.finish() }, sampleRate: 44_100))

        await XCTAssertThrowsErrorAsync(try await backend.transcribe(request)) { error in
            XCTAssertEqual(
                error as? SpeechToTextBackendError,
                .unsupportedAudio(
                    backendID: "scribe-realtime",
                    reason: "Scribe realtime expects PCM s16le mono at 16000 Hz; received 44100 Hz."
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
