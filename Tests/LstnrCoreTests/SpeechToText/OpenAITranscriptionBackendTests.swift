import Foundation
import XCTest
@testable import LstnrCore

final class OpenAITranscriptionBackendTests: XCTestCase {
    func testGPT4OTranscribeCapabilitiesDescribeNetworkFileTranscription() {
        let backend = OpenAIAudioTranscriptionBackend(
            apiKey: "test-key",
            modelID: "gpt-4o-transcribe",
            displayName: "OpenAI GPT-4o Transcribe"
        )

        XCTAssertEqual(backend.id, "openai-gpt-4o-transcribe")
        XCTAssertEqual(backend.displayName, "OpenAI GPT-4o Transcribe")
        XCTAssertTrue(backend.capabilities.supportsFileTranscription)
        XCTAssertFalse(backend.capabilities.supportsStreamingTranscription)
        XCTAssertTrue(backend.capabilities.supportsLanguageHints)
        XCTAssertFalse(backend.capabilities.supportsTimestamps)
        XCTAssertFalse(backend.capabilities.runsLocally)
        XCTAssertTrue(backend.capabilities.requiresNetwork)
        XCTAssertEqual(backend.capabilities.requiredCredentialKeys, ["OPENAI_API_KEY"])
        XCTAssertEqual(backend.capabilities.supportedSampleRates, [16_000])
    }

    func testGPT4OMiniSnapshotCapabilitiesUseRequestedModelID() {
        let backend = OpenAIAudioTranscriptionBackend(
            apiKey: "test-key",
            modelID: "gpt-4o-mini-transcribe-2025-12-15",
            displayName: "OpenAI GPT-4o Mini Transcribe 2025-12-15"
        )

        XCTAssertEqual(backend.id, "openai-gpt-4o-mini-transcribe-2025-12-15")
        XCTAssertEqual(backend.displayName, "OpenAI GPT-4o Mini Transcribe 2025-12-15")
        XCTAssertEqual(backend.capabilities.requiredCredentialKeys, ["OPENAI_API_KEY"])
        XCTAssertEqual(backend.capabilities.supportedSampleRates, [16_000])
    }

    func testRealtimeWhisperCapabilitiesDescribeStreamingNetworkTranscription() {
        let backend = OpenAIRealtimeWhisperBackend(apiKey: "test-key")

        XCTAssertEqual(backend.id, "openai-gpt-realtime-whisper")
        XCTAssertEqual(backend.displayName, "OpenAI GPT Realtime Whisper")
        XCTAssertTrue(backend.capabilities.supportsFileTranscription)
        XCTAssertTrue(backend.capabilities.supportsStreamingTranscription)
        XCTAssertTrue(backend.capabilities.supportsLanguageHints)
        XCTAssertFalse(backend.capabilities.supportsTimestamps)
        XCTAssertFalse(backend.capabilities.runsLocally)
        XCTAssertTrue(backend.capabilities.requiresNetwork)
        XCTAssertEqual(backend.capabilities.requiredCredentialKeys, ["OPENAI_API_KEY"])
        XCTAssertEqual(backend.capabilities.supportedSampleRates, [16_000])
    }

    func testGPT4OTranscribeRejectsUnsupportedStreamingSampleRate() async {
        let backend = OpenAIAudioTranscriptionBackend(
            apiKey: "test-key",
            modelID: "gpt-4o-transcribe",
            displayName: "OpenAI GPT-4o Transcribe"
        )
        let request = SpeechToTextRequest(audio: .pcm16Stream(AsyncStream { $0.finish() }, sampleRate: 44_100))

        await XCTAssertThrowsErrorAsync(try await backend.transcribe(request)) { error in
            XCTAssertEqual(
                error as? SpeechToTextBackendError,
                .unsupportedAudio(
                    backendID: "openai-gpt-4o-transcribe",
                    reason: "OpenAI transcription expects PCM s16le mono at 16000 Hz; received 44100 Hz."
                )
            )
        }
    }

    func testRealtimeWhisperRejectsUnsupportedStreamingSampleRate() async {
        let backend = OpenAIRealtimeWhisperBackend(apiKey: "test-key")
        let request = SpeechToTextRequest(audio: .pcm16Stream(AsyncStream { $0.finish() }, sampleRate: 44_100))

        await XCTAssertThrowsErrorAsync(try await backend.transcribe(request)) { error in
            XCTAssertEqual(
                error as? SpeechToTextBackendError,
                .unsupportedAudio(
                    backendID: "openai-gpt-realtime-whisper",
                    reason: "OpenAI realtime transcription expects PCM s16le mono at 16000 Hz; received 44100 Hz."
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
