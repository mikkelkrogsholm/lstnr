import XCTest
@testable import VaraCore

/// Live end-to-end proof that a REJECTED realtime session transparently falls
/// back to the batch endpoint (gpt-4o-transcribe) and still returns a transcript
/// — the fix for OpenAI accounts that lack gpt-realtime-whisper access.
///
/// Skipped by default. It is opt-in because it makes a real, paid OpenAI API
/// call and shells out to macOS `say`/`afconvert` to synthesize the audio:
///
///     VARA_LIVE_TEST=1 OPENAI_API_KEY=sk-... \
///       swift test --filter OpenAIRealtimeFallbackLiveTests
final class OpenAIRealtimeFallbackLiveTests: XCTestCase {
    func testRejectedRealtimeFallsBackToBatchAndTranscribes() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VARA_LIVE_TEST"] == "1",
            "live test: set VARA_LIVE_TEST=1 (makes a paid OpenAI call)"
        )
        let key = try XCTUnwrap(
            ProcessInfo.processInfo.environment["OPENAI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 },
            "set OPENAI_API_KEY"
        )

        let wav = try Self.synthesizeWAV(text: "Dette er en test af reservemotoren i Vara.")
        defer { try? FileManager.default.removeItem(at: wav) }
        let pcm = try AudioReader.readPCM16(url: wav, targetSampleRate: 16_000)
        XCTAssertGreaterThan(pcm.count, 0, "synthesized audio should be non-empty")

        // A bogus model id makes the realtime session reject (invalid_model), which
        // is exactly the failure a gated account hits — so the catch → batch path runs.
        let backend = OpenAIRealtimeWhisperBackend(apiKey: key, modelID: "gpt-realtime-whisper-DOES-NOT-EXIST")
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        continuation.yield(pcm)
        continuation.finish()

        let result = try await backend.transcribe(
            SpeechToTextRequest(audio: .pcm16Stream(stream, sampleRate: 16_000), languageCode: "da")
        )

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        print("LIVE FALLBACK TRANSCRIPT: \"\(text)\" (backend: \(result.backend))")
        XCTAssertFalse(text.isEmpty, "the batch fallback must yield a transcript even though realtime was rejected")
    }

    // MARK: - Audio synthesis (macOS only)

    private static func synthesizeWAV(text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let aiff = dir.appendingPathComponent("vara-live-\(UUID().uuidString).aiff")
        let wav = dir.appendingPathComponent("vara-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: aiff) }
        try run("/usr/bin/say", ["-o", aiff.path, text])
        // s16le, mono, 16 kHz WAV — the rate the realtime backend expects.
        try run("/usr/bin/afconvert", [aiff.path, "-d", "LEI16", "-c", "1", "-f", "WAVE", "-r", "16000", wav.path])
        return wav
    }

    private static func run(_ launchPath: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "OpenAIRealtimeFallbackLiveTests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(launchPath) exited \(process.terminationStatus)"])
        }
    }
}
